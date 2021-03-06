%%------------------------------------------------------------------------------
%% Copyright 2012 FlowForwarding.org
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%-----------------------------------------------------------------------------

%% @author Erlang Solutions Ltd. <openflow@erlang-solutions.com>
%% @copyright 2012 FlowForwarding.org
%% @doc Module to represent OpenFlow port.
%% It abstracts out underlying logic of either hardware network stack or virtual
%% TAP stack. It provides Open Flow ports represented as gen_server processes
%% with port configuration and statistics according to OpenFlow specification.
%% It allows to create and attach queues to given ports and supports queue
%% statistics as well. OpenFlow ports can be programatically started and
%% stopped by utilizing API provided by this module.
-module(linc_us4_port).

-behaviour(gen_server).

%% Port API
-export([start_link/2,
         initialize/2,
         terminate/1,
         modify/2,
         send/2,
         get_desc/1,
         get_stats/2,
         get_state/2,
         set_state/3,
         get_config/2,
         set_config/3,
         get_features/2,
         get_advertised_features/2,
         set_advertised_features/3,
         get_all_ports_state/1,
         get_all_queues_state/1,
         is_valid/2]).

-ifdef(TEST).
-compile([export_all]).
-endif.

-include_lib("of_config/include/of_config.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include("linc_us4.hrl").
-include("linc_us4_port.hrl").

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Start Open Flow port with provided configuration.
-spec start_link(integer(), list(linc_port_config())) -> {ok, pid()} |
                                                         ignore |
                                                         {error, term()}.
start_link(SwitchId, PortConfig) ->
    gen_server:start_link(?MODULE, [SwitchId, PortConfig], []).

-spec initialize(integer(), tuple(config, list(linc_port_config()))) -> ok.
initialize(SwitchId, Config) ->
    LincPorts = ets:new(linc_ports, [public,
                                     {keypos, #linc_port.port_no},
                                     {read_concurrency, true}]),
    LincPortStats = ets:new(linc_port_stats,
                            [public,
                             {keypos, #ofp_port_stats.port_no},
                             {read_concurrency, true}]),
    linc:register(SwitchId, linc_ports, LincPorts),
    linc:register(SwitchId, linc_port_stats, LincPortStats),
    case queues_enabled(SwitchId) of
        true ->
            linc_us4_queue:initialize(SwitchId);
        false ->
            ok
    end,
    UserspacePorts = ports_for_switch(SwitchId, Config),
    [add(physical, SwitchId, Port) || Port <- UserspacePorts],
    ok.

-spec terminate(integer()) -> ok.
terminate(SwitchId) ->
    [ok = remove(SwitchId, PortNo) || PortNo <- get_all_port_no(SwitchId)],
    true = ets:delete(linc:lookup(SwitchId, linc_ports)),
    true = ets:delete(linc:lookup(SwitchId, linc_port_stats)),
    case queues_enabled(SwitchId) of
        true ->
            linc_us4_queue:terminate(SwitchId);
        false ->
            ok
    end.

%% @doc Change config of the given OF port according to the provided port mod.
-spec modify(integer(), ofp_port_mod()) -> ok |
                                           {error, {Type :: atom(),
                                                    Code :: atom()}}.
modify(SwitchId, #ofp_port_mod{port_no = PortNo} = PortMod) ->
    case get_port_pid(SwitchId, PortNo) of
        {error, invalid} ->
            {error, {bad_request, bad_port}};
        {error, nonexistent} ->
            {error, {port_mod_failed, bad_port}};
        Pid ->
            gen_server:call(Pid, {port_mod, PortMod})
    end.

%% @doc Send OF packet to the OF port.
-spec send(linc_pkt(), ofp_port_no()) -> ok | bad_port | bad_queue | no_fwd.
send(#linc_pkt{in_port = InPort} = Pkt, in_port) ->
    send(Pkt, InPort);
send(#linc_pkt{} = Pkt, table) ->
    linc_us4_routing:maybe_spawn_route(Pkt),
    ok;
send(#linc_pkt{}, normal) ->
    %% Normal port represents traditional non-OpenFlow pipeline of the switch
    %% not supprted by LINC
    bad_port;
send(#linc_pkt{} = Pkt, flood) ->
    %% Flood port represents traditional non-OpenFlow pipeline of the switch
    %% and should not be supported by LINC. But we want LINC to cooperate with
    %% NOX 1.3 controller [1] that uses this port, incorrectly assuming that
    %% an OpenFlow switch supports it. It's important as NOX is shipped
    %% with Mininet [3]. As soon as this bug is fixed [2]
    %% this function call will return 'bad_port'.
    %% [1]: https://github.com/CPqD/nox13oflib
    %% [2]: https://github.com/CPqD/nox13oflib/issues/3
    %% [3]: http://mininet.org/
    send(Pkt, all);
send(#linc_pkt{in_port = InPort, switch_id = SwitchId} = Pkt, all) ->
    [send(Pkt, PortNo) || PortNo <- get_all_port_no(SwitchId), PortNo /= InPort],
    ok;
send(#linc_pkt{no_packet_in = true}, controller) ->
    %% Drop packets which originate from port with no_packet_in config flag set
    ok;
send(#linc_pkt{no_packet_in = false, fields = Fields, packet = Packet,
               table_id = TableId, packet_in_reason = Reason,
               packet_in_bytes = Bytes, cookie = Cookie,
               switch_id = SwitchId},
     controller) ->
    {BufferId, TotalLen, Data} = maybe_buffer(SwitchId, Reason, Packet, Bytes),
    PacketIn = #ofp_packet_in{buffer_id = BufferId, total_len = TotalLen,
                              reason = Reason, table_id = TableId,
                              cookie = Cookie, match = Fields, data = Data},
    linc_logic:send_to_controllers(SwitchId, #ofp_message{body = PacketIn}),
    ok;
send(#linc_pkt{}, local) ->
    ?WARNING("Unsupported port type: local", []),
    bad_port;
send(#linc_pkt{}, any) ->
    %% Special value used in some OpenFlow commands when no port is specified
    %% (port wildcarded).
    %% Can not be used as an ingress port nor as an output port.
    bad_port;
send(#linc_pkt{switch_id = SwitchId} = Pkt, PortNo) when is_integer(PortNo) ->
    case get_port_pid_if_ready_to_send(SwitchId, PortNo) of
        {error, _} ->
            bad_port;
        port_overloaded ->
            drop;
        Pid ->
            gen_server:cast(Pid, {send, Pkt})
    end.

%% @doc Return list of all OFP ports present in the switch.
-spec get_desc(integer()) -> ofp_port_desc_reply().
get_desc(SwitchId) ->
    L = ets:foldl(fun(#linc_port{pid = Pid}, Ports) ->
                          Port = gen_server:call(Pid, get_port),
                          [Port | Ports]
                  end, [], linc:lookup(SwitchId, linc_ports)),
    #ofp_port_desc_reply{body = L}.

%% @doc Return port stats record for the given OF port.
-spec get_stats(integer(), ofp_port_stats_request()) -> ofp_port_stats_reply() |
                                                        ofp_error_msg().
get_stats(SwitchId, #ofp_port_stats_request{port_no = any}) ->
    PortStats = ets:tab2list(linc:lookup(SwitchId, linc_port_stats)),
    #ofp_port_stats_reply{body = convert_duration(PortStats)};
get_stats(SwitchId, #ofp_port_stats_request{port_no = PortNo}) ->
    case ets:lookup(linc:lookup(SwitchId, linc_port_stats), PortNo) of
        [] ->
            #ofp_error_msg{type = bad_request, code = bad_port};
        [#ofp_port_stats{}] = PortStats ->
            #ofp_port_stats_reply{body = convert_duration(PortStats)}
    end.

-spec get_state(integer(), ofp_port_no()) -> [ofp_port_state()].
get_state(SwitchId, PortNo) ->
    case get_port_pid(SwitchId, PortNo) of
        {error, _} ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, get_port_state)
    end.

-spec set_state(integer(), ofp_port_no(), [ofp_port_state()]) -> ok.
set_state(SwitchId, PortNo, PortState) ->
    case get_port_pid(SwitchId, PortNo) of
        {error, _} ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, {set_port_state, PortState})
    end.

-spec get_config(integer(), ofp_port_no()) -> [ofp_port_config()].
get_config(SwitchId, PortNo) ->
    case get_port_pid(SwitchId, PortNo) of
        {error, _} ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, get_port_config)
    end.

-spec set_config(integer(), ofp_port_no(), [ofp_port_config()]) -> ok.
set_config(SwitchId, PortNo, PortConfig) ->
    case get_port_pid(SwitchId, PortNo) of
        {error, _} ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, {set_port_config, PortConfig})
    end.

-spec get_features(integer(), ofp_port_no()) -> tuple([ofp_port_feature()],
                                                      [ofp_port_feature()],
                                                      [ofp_port_feature()],
                                                      [ofp_port_feature()]).
get_features(SwitchId, PortNo) ->
    case get_port_pid(SwitchId, PortNo) of
        {error, _} ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, get_features)
    end.

-spec get_advertised_features(integer(), ofp_port_no()) -> [ofp_port_feature()].
get_advertised_features(SwitchId, PortNo) ->
    case get_port_pid(SwitchId, PortNo) of
        {error, _} ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, get_advertised_features)
    end.

-spec set_advertised_features(integer(), ofp_port_no(), [ofp_port_feature()]) -> ok.
set_advertised_features(SwitchId, PortNo, AdvertisedFeatures) ->
    case get_port_pid(SwitchId, PortNo) of
        {error, _} ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, {set_advertised_features, AdvertisedFeatures})
    end.

-spec get_all_ports_state(integer()) -> list({ResourceId :: string(),
                                              ofp_port()}).
get_all_ports_state(SwitchId) ->
    lists:map(fun(PortNo) ->
                      Pid = get_port_pid(SwitchId, PortNo),
                      gen_server:call(Pid, get_info)
              end, get_all_port_no(SwitchId)).

-spec get_all_queues_state(integer()) -> list(tuple(string(), integer(), integer(),
                                                    integer(), integer())).
get_all_queues_state(SwitchId) ->
    lists:flatmap(fun(PortNo) ->
                          linc_us4_queue:get_all_queues_state(SwitchId, PortNo)
                  end, get_all_port_no(SwitchId)).

%% @doc Test if a port exists.
-spec is_valid(integer(), ofp_port_no()) -> boolean().
is_valid(_SwitchId, PortNo) when is_atom(PortNo)->
    true;
is_valid(SwitchId, PortNo) when is_integer(PortNo)->
    ets:member(linc:lookup(SwitchId, linc_ports), PortNo).

%%%-----------------------------------------------------------------------------
%%% gen_server callbacks
%%%-----------------------------------------------------------------------------

%% @private
init([SwitchId, {port, CapablePortNo, PortOpts}]) ->
    process_flag(trap_exit, true),
    %% epcap crashes if this dir does not exist.
    filelib:ensure_dir(filename:join([code:priv_dir(epcap), "tmp", "ensure"])),
    Port = set_ofp_port(CapablePortNo, PortOpts),
    State0 = #state{switch_id = SwitchId, port = Port,
                    resource_id = construct_port_resource_id(SwitchId,
                                                             Port#ofp_port.name),
                    interface =  proplists:get_value(interface, PortOpts),
                    queues = get_queues_state(SwitchId),
                    sync_routing = get_sync_routing_state()},
    State1 = case get_interface_type(PortOpts) of
                 tap ->
                     setup_tap_interface(PortOpts, State0);
                 eth ->
                     setup_eth_interface(PortOpts, State0)
             end,
    {ok, State1, 0}.

%% @private
handle_call({port_mod, #ofp_port_mod{hw_addr = PMHwAddr,
                                     config = Config,
                                     mask = _Mask,
                                     advertise = Advertise}}, _From,
            #state{port = #ofp_port{hw_addr = HWAddr} = Port} = State) ->
    {Reply, NewPort} = case PMHwAddr == HWAddr of
                           true ->
                               {ok, Port#ofp_port{config = Config,
                                                  advertised = Advertise}};
                           false ->
                               {{error, {port_mod_failed, bad_hw_addr}}, Port}
                       end,
    {reply, Reply, State#state{port = NewPort}};
handle_call(get_port, _From, #state{port = Port} = State) ->
    {reply, Port, State};
handle_call(get_port_state, _From,
            #state{port = #ofp_port{state = PortState}} = State) ->
    {reply, PortState, State};
handle_call({set_port_state, NewPortState}, _From,
            #state{port = Port, switch_id = SwitchId} = State) ->
    NewPort = Port#ofp_port{state = NewPortState},
    PortStatus = #ofp_port_status{reason = modify,
                                  desc = NewPort},
    linc_logic:send_to_controllers(SwitchId, #ofp_message{body = PortStatus}),
    {reply, ok, State#state{port = NewPort}};
handle_call(get_port_config, _From,
            #state{port = #ofp_port{config = PortConfig}} = State) ->
    {reply, PortConfig, State};
handle_call({set_port_config, NewPortConfig}, _From,
            #state{port = Port, switch_id = SwitchId} = State) ->
    NewPort = Port#ofp_port{config = NewPortConfig},
    PortStatus = #ofp_port_status{reason = modify,
                                  desc = NewPort},
    linc_logic:send_to_controllers(SwitchId, #ofp_message{body = PortStatus}),
    {reply, ok, State#state{port = NewPort}};
handle_call(get_features, _From,
            #state{port = #ofp_port{
                             curr = CurrentFeatures,
                             advertised = AdvertisedFeatures,
                             supported = SupportedFeatures,
                             peer  = PeerFeatures
                            }} = State) ->
    {reply, {CurrentFeatures, AdvertisedFeatures,
             SupportedFeatures, PeerFeatures}, State};
handle_call(get_advertised_features, _From,
            #state{port = #ofp_port{advertised = AdvertisedFeatures}} = State) ->
    {reply, AdvertisedFeatures, State};
handle_call({set_advertised_features, AdvertisedFeatures}, _From,
            #state{port = Port, switch_id = SwitchId} = State) ->
    NewPort = Port#ofp_port{advertised = AdvertisedFeatures},
    PortStatus = #ofp_port_status{reason = modify,
                                  desc = NewPort},
    linc_logic:send_to_controllers(SwitchId, #ofp_message{body = PortStatus}),
    {reply, ok, State#state{port = NewPort}};
handle_call(get_info, _From, #state{resource_id = ResourceId,
                                    port = Port} = State) ->
    {reply, {ResourceId, Port}, State}.

%% @private
handle_cast({send, #linc_pkt{packet = Packet, queue_id = QueueId}},
            #state{socket = Socket,
                   port = #ofp_port{port_no = PortNo} = Port,
                   erlang_port = ErlPort,
                   queues = QueuesState,
                   ifindex = Ifindex,
                   switch_id = SwitchId} = State) ->
    case is_accepting_packets(out, Port) of
        false ->
            drop;
        true ->
            Frame = pkt:encapsulate(Packet),
            update_port_tx_counters(SwitchId, PortNo, byte_size(Frame)),
            case QueuesState of
                disabled ->
                    case {ErlPort, Ifindex} of
                        {undefined, _} ->
                            linc_us4_port_native:send(Socket, Ifindex, Frame);
                        {_, undefined} ->
                            port_command(ErlPort, Frame)
                    end;
                enabled ->
                    linc_us4_queue:send(SwitchId, PortNo, QueueId, Frame)
            end
    end,
    {noreply, State}.

%% @private
handle_info({packet, _DataLinkType, _Time, _Length, Frame},
            #state{port = Port,
                   switch_id = SwitchId,
                   overload_protection = Protection,
                   sync_routing = SyncRouting} = State) ->
    [handle_frame(Frame, SwitchId, Port, SyncRouting)
     || Protection /= drop_all andalso Protection /= drop_rx],
    {noreply, State};
handle_info({ErlPort, {data, Frame}}, #state{port = Port,
                                             erlang_port = ErlPort,
                                             switch_id = SwitchId,
                                             overload_protection = Protection,
                                             sync_routing = SyncRouting}
            = State) ->
    [handle_frame(Frame, SwitchId, Port, SyncRouting)
     || Protection /= drop_all andalso Protection /= drop_rx],
    {noreply, State};
handle_info(NetlinkMsg, #state{port = Port0, operstate_changes_ref = Ref,
                               interface = Interface} = State)
  when element(1, NetlinkMsg) =:= netlink->
    NewOperstate = linc_us4_port_native:operstate_change(NetlinkMsg,
                                                         Ref, Interface),
    PortState = mark_link_state_as(NewOperstate, Port0#ofp_port.state),
    Port1 = Port0#ofp_port{state = PortState},
    PortStatus = #ofp_port_status{reason = modify, desc = Port1},
    linc_logic:send_to_controllers(State#state.switch_id,
                                   #ofp_message{body = PortStatus}),
    ?INFO("Set new port state ~p~n", [PortState]),
    {noreply, State#state{port = Port1}};
handle_info({'EXIT', _Pid, {port_terminated, 1}},
            #state{interface = Interface} = State) ->
    ?ERROR("Port for interface ~p exited abnormally",
           [Interface]),
    {stop, normal, State};

handle_info(#load_control_message{} = Msg, State) ->
    {noreply, linc_us4_port_load_regulator:limit_load_if_necessary(Msg, State)};

handle_info(timeout, #state{switch_id = SwitchId,
                            port = #ofp_port{port_no = PortNo}} = State) ->
    {noreply, setup_load_control(SwitchId, PortNo, State)};

handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, #state{port = #ofp_port{port_no = PortNo},
                          switch_id = SwitchId,
                          periodic_load_checker_ref = LoadCheckerRef} = State) ->
    case queues_enabled(SwitchId) of
        true ->
            linc_us4_queue:detach_all(SwitchId, PortNo);
        false ->
            ok
    end,
    true = ets:delete(linc:lookup(SwitchId, linc_ports), PortNo),
    true = ets:delete(linc:lookup(SwitchId, linc_port_stats), PortNo),
    ok = linc_us4_port_load_regulator:cancel_periodic_check(LoadCheckerRef),
    linc_us4_port_native:close(State).

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

%% @doc Return list of all OFP port numbers present in the switch.
-spec get_all_port_no(integer()) -> [integer()].
get_all_port_no(SwitchId) ->
    ets:foldl(fun(#linc_port{port_no = PortNo}, Acc) ->
                      [PortNo | Acc]
              end, [], linc:lookup(SwitchId, linc_ports)).

-spec add(linc_port_type(), integer(), [linc_port_config()]) -> pid() | error.
add(physical, SwitchId, PortConfig) ->
    Sup = linc:lookup(SwitchId, linc_us4_port_sup),
    case supervisor:start_child(Sup, [PortConfig]) of
        {ok, Pid} ->
            ?INFO("Created port: ~p", [PortConfig]),
            Pid;
        {error, shutdown} ->
            ?ERROR("Cannot create port ~p", [PortConfig]),
            error
    end.

%% @doc Removes given OF port from the switch, as well as its port stats entry,
%% all queues connected to it and their queue stats entries.
-spec remove(integer(), ofp_port_no()) -> ok | bad_port.
remove(SwitchId, PortNo) ->
    case get_port_pid(SwitchId, PortNo) of
        {error, _} ->
            bad_port;
        Pid ->
            Sup = linc:lookup(SwitchId, linc_us4_port_sup),
            ok = supervisor:terminate_child(Sup, Pid)
    end.

handle_frame(Frame, SwitchId, Port, SyncRouting) ->
    case is_accepting_packets(in, Port) of
        false -> drop;
        true  -> do_handle_frame(Frame, SwitchId, Port, SyncRouting)
    end.


do_handle_frame(Frame, SwitchId, #ofp_port{port_no = PortNo, config = PortConfig},
                SyncRouting) ->
    LincPkt = linc_us4_packet:binary_to_record(Frame, SwitchId, PortNo),
    update_port_rx_counters(SwitchId, PortNo, byte_size(Frame)),
    NewLincPkt =
        case lists:member(no_packet_in, PortConfig) of
            false ->
                LincPkt;
            true ->
                LincPkt#linc_pkt{no_packet_in = true}
        end,
    case SyncRouting of
        true ->
            linc_us4_routing:route(NewLincPkt);
        false ->
            linc_us4_routing:spawn_route(NewLincPkt)
    end.

-spec update_port_rx_counters(integer(), integer(), integer()) -> any().
update_port_rx_counters(SwitchId, PortNum, Bytes) ->
    ets:update_counter(linc:lookup(SwitchId, linc_port_stats), PortNum,
                       [{#ofp_port_stats.rx_packets, 1},
                        {#ofp_port_stats.rx_bytes, Bytes}]).

-spec update_port_tx_counters(integer(), integer(), integer()) -> any().
update_port_tx_counters(SwitchId, PortNum, Bytes) ->
    ets:update_counter(linc:lookup(SwitchId, linc_port_stats), PortNum,
                       [{#ofp_port_stats.tx_packets, 1},
                        {#ofp_port_stats.tx_bytes, Bytes}]).

-spec get_port_pid(integer(), ofp_port_no()) -> pid() |
                                                {error, invalid | nonexistent}.
get_port_pid(SwitchId, PortNo) ->
    case get_linc_port(SwitchId, PortNo) of
        #linc_port{pid = Pid} ->
            Pid;
        Error ->
            Error
    end.

-spec get_port_pid_if_ready_to_send(integer(), ofp_port_no()) ->
                                           pid() |
                                           {error, invalid | nonexistent} |
                                           port_overloaded.
get_port_pid_if_ready_to_send(SwitchId, PortNo) ->
    case get_linc_port(SwitchId, PortNo) of
        #linc_port{pid = Pid, drop_tx = false} ->
            Pid;
        #linc_port{drop_tx = true} ->
            port_overloaded;
        Error ->
            Error
    end.

get_linc_port(_SwitchId, PortNo) when is_atom(PortNo); PortNo > ?OFPP_MAX ->
    {error, invalid};
get_linc_port(SwitchId, PortNo) ->
    case ets:lookup(linc:lookup(SwitchId, linc_ports), PortNo) of
        [] ->
            {error, nonexistent};
        [#linc_port{} = Port] ->
            Port
    end.

-spec convert_duration(list(#ofp_port_stats{})) -> list(#ofp_port_stats{}).
convert_duration(PortStatsList) ->
    lists:map(fun(#ofp_port_stats{duration_sec = DSec} = PortStats) ->
                      MicroDuration = timer:now_diff(erlang:now(), DSec),
                      Sec = microsec_to_sec(MicroDuration),
                      NSec = microsec_to_nsec(MicroDuration),
                      PortStats#ofp_port_stats{duration_sec = Sec,
                                               duration_nsec = NSec}
              end, PortStatsList).

microsec_to_sec(Micro) ->
    Micro div 1000000.

microsec_to_nsec(Micro) ->
    (Micro rem 1000000) * 1000.

maybe_buffer(SwitchId, action, Packet, Bytes) ->
    maybe_buffer(SwitchId, Packet, Bytes);
maybe_buffer(SwitchId, no_match, Packet, _Bytes) ->
    maybe_buffer(SwitchId, Packet, get_switch_config(miss_send_len));
maybe_buffer(SwitchId, invalid_ttl, Packet, _Bytes) ->
    %% The spec does not specify how many bytes to include for invalid_ttl,
    %% so we use miss_send_len here as well.
    maybe_buffer(SwitchId, Packet, get_switch_config(miss_send_len)).

maybe_buffer(_SwitchId, Packet, no_buffer) ->
    PacketBin = pkt:encapsulate(Packet),
    {no_buffer, byte_size(PacketBin), PacketBin};
maybe_buffer(SwitchId, Packet, Bytes) ->
    BufferId = linc_buffer:save_buffer(SwitchId, Packet),
    PacketBin = truncate_packet(Packet,Bytes),
    {BufferId, byte_size(PacketBin), PacketBin}.

truncate_packet(Packet,Bytes) ->
    Bin = pkt:encapsulate(Packet),
    case byte_size(Bin) > Bytes of
        true ->
            <<Head:Bytes/bytes, _/binary>> = Bin,
            Head;
        false ->
            Bin
    end.

get_switch_config(miss_send_len) ->
    %%TODO: get this from the switch configuration
    no_buffer.

-spec queues_enabled(integer()) -> boolean().
queues_enabled(SwitchId) ->
    {ok, Switches} = application:get_env(linc, logical_switches),
    {switch, SwitchId, Opts} = lists:keyfind(SwitchId, 2, Switches),
    case lists:keyfind(queues_status, 1, Opts) of
        false ->
            false;
        {queues_status, enabled} ->
            true;
        _ ->
            false
    end.

-spec queues_config(integer(), list(linc_port_config())) -> [term()] |
                                                            disabled.
queues_config(SwitchId, PortOpts) ->
    case queues_enabled(SwitchId) of
        true ->
            case lists:keyfind(queues, 1, PortOpts) of
                false ->
                    disabled;
                {queues, Queues} ->
                    Queues
            end;
        false ->
            disabled
    end.

ports_for_switch(SwitchId, Config) ->
    {switch, SwitchId, Opts} = lists:keyfind(SwitchId, 2, Config),
    {ports, Ports} = lists:keyfind(ports, 1, Opts),
    QueuesStatus = lists:keyfind(queues_status, 1, Opts),
    Queues = lists:keyfind(queues, 1, Opts),
    [begin
         {port, PortNo, [QueuesStatus | [Queues | PortConfig]]}
     end || {port, PortNo, PortConfig} <- Ports].

is_accepting_packets(InOrOut, #ofp_port{config = Config, state = State}) ->
    (not lists:member(link_down, State))
        andalso (not lists:member(port_down, Config))
        andalso case InOrOut of
                    in ->
                        not lists:member(no_recv, Config);
                    out ->
                        not lists:member(no_fwd, Config)
                end.

setup_load_control(SwitchId, PortNo, State) ->
    CheckerReference =
        linc_us4_port_load_regulator:schedule_periodic_check(SwitchId, PortNo),
    State#state{periodic_load_checker_ref = CheckerReference}.

init_port_state(down) ->
    [live, link_down];
init_port_state(up) ->
    [live].

mark_link_state_as(up, PortState) ->
    not lists:member(link_down, PortState) andalso
        ?WARNING("Setting up port that already is up"),
    lists:filter(fun(link_down) -> false;
                    (_) -> true
                 end, PortState);
mark_link_state_as(down, PortState) ->
    case lists:member(link_down, PortState) of
        true ->
            ?WARNING("Setting down port that already is down"),
            PortState;
        false ->
            [link_down | PortState]
    end.

set_ofp_port(CapablePortNo, PortOpts) ->
    PortNo = proplists:get_value(port_no, PortOpts, CapablePortNo),
    PortName = proplists:get_value(port_name, PortOpts,
                                   "Port" ++ integer_to_list(PortNo)),
    Advertised = case lists:keyfind(features, 1, PortOpts) of
                     false ->
                         ?FEATURES;
                     {features, undefined} ->
                         ?FEATURES;
                     {features, Features} ->
                         linc_ofconfig:convert_port_features(Features)
                 end,
    PortConfig = case lists:keyfind(config, 1, PortOpts) of
                     false ->
                         [];
                     {config, undefined} ->
                         [];
                     {config, Config} ->
                         linc_ofconfig:convert_port_config(Config)
                 end,
    #ofp_port{port_no = PortNo,
              name = PortName,
              config = PortConfig,
              state = [live],
              curr = ?FEATURES,
              advertised = Advertised,
              supported = ?FEATURES, peer = ?FEATURES,
              curr_speed = ?PORT_SPEED, max_speed = ?PORT_SPEED}.

get_queues_state(SwitchId) ->
    case queues_enabled(SwitchId) of
        false ->
            disabled;
        true ->
            enabled
    end.

get_interface_type(PortOpts) ->
    case lists:keyfind(type, 1, PortOpts) of
        {type, Type1} ->
            Type1;
        _ ->
            %% The type is not specified explicitly.
            %% Guess from the interface name.
            Interface = proplists:get_value(interface, PortOpts),
            case re:run(Interface, "^tap.*$", [{capture, none}]) of
                match ->
                    tap;
                nomatch ->
                    eth
            end
    end.

get_sync_routing_state() ->
    %% Use sync routing unless explicitly disabled in the configuration
    case application:get_env(linc, sync_routing) of
        {ok, false} ->
            false;
        _ ->
            true
    end.

%% @doc Setup tap interface.
%%
%% When switch connects to a tap interface, erlang receives file
%% descriptor to read/write ethernet frames directly from the
%% desired /dev/tapX character device. No socket communication
%% is involved.
setup_tap_interface(PortOpts, #state{interface = Interface,
                                     port = Port} = State0) ->
    case linc_us4_port_native:tap(Interface, PortOpts) of
        {stop, shutdown} ->
            {stop, shutdown};
        {ErlangPort, Pid, HwAddr, OperstateChangesRef, Operstate} ->
            State1 = State0#state{erlang_port = ErlangPort,
                                  port_ref = Pid,
                                  operstate_changes_ref = OperstateChangesRef,
                                  port= Port#ofp_port{
                                          hw_addr = HwAddr,
                                          state = init_port_state(Operstate)}},
            SendFun = fun(Frame) ->
                              port_command(ErlangPort, Frame)
                      end,
            setup_linc_port_and_ofp_port_stats_ets(State1),
            setup_port_queues(PortOpts, SendFun, State1),
            State1
    end.

%% @doc
%%
%% When switch connects to a hardware interface such as eth0
%% then communication is handled by two channels:
%% * receiving ethernet frames is done by libpcap wrapped-up by
%%   a epcap application
%% * sending ethernet frames is done by writing to
%%   a RAW socket binded with given network interface.
%%   Handling of RAW sockets differs between OSes.
setup_eth_interface(PortOpts, #state{interface = Interface,
                                     port = Port} = State0) ->
    {Socket, IfIndex, EpcapPid, HwAddr, OperstateChangesRef,
     Operstate} = linc_us4_port_native:eth(Interface),
    State1 = State0#state{socket = Socket, ifindex = IfIndex,
                          epcap_pid = EpcapPid,
                          operstate_changes_ref = OperstateChangesRef,
                          port = Port#ofp_port{
                                   hw_addr = HwAddr,
                                   state = init_port_state(Operstate)}},
    SendFun = fun(Frame) ->
                      linc_us4_port_native:send(Socket, IfIndex, Frame)
              end,
    setup_linc_port_and_ofp_port_stats_ets(State1),
    setup_port_queues(PortOpts, SendFun, State1),
    State1.


construct_port_resource_id(SwitchId, PortName) ->
    "LogicalSwitch" ++ integer_to_list(SwitchId) ++ "-" ++ PortName.

setup_linc_port_and_ofp_port_stats_ets(#state{switch_id = SwitchId,
                                             port = Port}) ->
    ets:insert(linc:lookup(SwitchId, linc_ports),
               #linc_port{port_no = Port#ofp_port.port_no, pid = self()}),
    ets:insert(linc:lookup(SwitchId, linc_port_stats),
               #ofp_port_stats{port_no = Port#ofp_port.port_no,
                               duration_sec = erlang:now()}).

setup_port_queues(PortOpts, SendFun, #state{switch_id = SwitchId,
                                            port = Port}) ->
    case queues_config(SwitchId, PortOpts) of
        disabled ->
            disabled;
        QueuesConfig ->
            linc_us4_queue:attach_all(SwitchId, Port#ofp_port.port_no,
                                      SendFun, QueuesConfig)
    end.
