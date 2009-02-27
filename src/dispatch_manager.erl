%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is Spice Telephony.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <athompson at spicecsm dot com>
%%	Micah Warren <mwarren at spicecsm dot com>
%%

%% @doc Handles the creation and desctruction of dispatchers.
%% There is to be 1 dipatcher for every avaiable agent on a node.
-module(dispatch_manager).
-author("Micah").

-include("call.hrl").
-include("agent.hrl").

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour(gen_server).

%% API
-export([start_link/0, start/0, stop/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {
	dispatchers = [] :: [pid()],
	agents = [] :: [pid()]
	}).

%%====================================================================
%% API
%%====================================================================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
	
start() ->
	gen_server:start({local, ?MODULE}, ?MODULE, [], []).
	
-spec(stop/0 :: () -> any()).
stop() -> 
	gen_server:call(?MODULE, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================
%% @private
init([]) ->
	process_flag(trap_exit, true),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------
%% @private
handle_call(stop, _From, State) -> 
	{stop, normal, ok, State};
handle_call(dump, _From, State) ->
	{reply, State, State};
handle_call(Request, _From, State) ->
    {reply, {unknown_call, Request}, State}.

%%--------------------------------------------------------------------
%% Description: Handling cast messages
%%--------------------------------------------------------------------
%% @private
handle_cast({now_avail, AgentPid}, State) -> 
	?CONSOLE("Someone's available now.", []),
	case lists:member(AgentPid, State#state.agents) of
		true -> 
			{noreply, balance(State)};
		false -> 
			erlang:monitor(process, AgentPid),
			State2 = State#state{agents = [AgentPid | State#state.agents]},
			{noreply, balance(State2)}
	end;
handle_cast({end_avail, AgentPid}, State) -> 
	?CONSOLE("An agent is no longer available.", []),
	State2 = State#state{agents = lists:delete(AgentPid, State#state.agents)},
	{noreply, balance(State2)};

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
%% @private
handle_info({'DOWN', _MonitorRef, process, Object, _Info}, State) -> 
	?CONSOLE("Announcement that an agent is down, balancing in response.", []),
	State2 = State#state{agents = lists:delete(Object, State#state.agents)},
	{noreply, balance(State2)};
handle_info({'EXIT', Pid, Reason}, #state{dispatchers = Dispatchers} = State) ->
	?CONSOLE("Dispatcher unexpected exit:  ~p ~p", [Pid, Reason]),
	CleanD = lists:delete(Pid, Dispatchers),
	State2 = State#state{dispatchers = CleanD},
	{noreply, balance(State2)};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
%% @private
terminate(Reason, State) ->
	?CONSOLE("Termination cause:  ~p.  State:  ~p", [Reason, State]),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%%--------------------------------------------------------------------
%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
	
%% @private
-spec(balance/1 :: (State :: #state{}) -> #state{}).
balance(State) when length(State#state.agents) > length(State#state.dispatchers) -> 
	?CONSOLE("Starting new dispatcher",[]),
	Dispatchers = State#state.dispatchers,
	{ok, Pid} = dispatcher:start_link(),
	State2 = State#state{dispatchers = [ Pid | Dispatchers]},
	balance(State2);
balance(State) when length(State#state.agents) < length(State#state.dispatchers) -> 
	?CONSOLE("Killing a dispatcher",[]),
	[Pid | Dispatchers] = lists:reverse(State#state.dispatchers),
	?CONSOLE("Pid I'm about to kill: ~p.  me:  ~p.  Dispatchers:  ~p~n", [Pid, self(), Dispatchers]),
	case is_process_alive(Pid) of
		true ->
			ok = dispatcher:stop(Pid);
		_Else -> 
			% don't try to kill it.
			ok
	end,
	balance(State#state{dispatchers=Dispatchers});
balance(State) -> 
	?CONSOLE("It is fully balanced!",[]),
	State.

dump() ->
	gen_server:call(?MODULE, dump).

-ifdef(EUNIT).

test_primer() ->
	["testpx", _Host] = string:tokens(atom_to_list(node()), "@"),
	mnesia:stop(),
	mnesia:delete_schema([node()]),
	mnesia:create_schema([node()]),
	mnesia:start().

balance_test_() ->
	{
		foreach,
		fun() ->
			test_primer(),
			agent_manager:start([node()]),
			queue_manager:start([node()]),
			start(),
			ok
		end,
		fun(ok) ->
			agent_manager:stop(),
			queue_manager:stop(),
			stop()
		end,
		[
			{
				"Agent started, but is still released",
				fun() ->
					{ok, Apid} = agent_manager:start_agent(#agent{login = "testagent"}),
					receive
					after 100 ->
						ok
					end,
					State1 = dump(),
					?assertEqual(State1#state.agents, []),
					?assertEqual(State1#state.dispatchers, [])
				end
			},
			{
				"Agent started then set available, so a dispatcher starts",
				fun() ->
					State1 = dump(),
					?assertEqual(State1#state.agents, []),
					?assertEqual(State1#state.dispatchers, []),
					{ok, Apid} = agent_manager:start_agent(#agent{login = "testagent"}),
					agent:set_state(Apid, idle),
					receive
					after 100 ->
						ok
					end,
					State2 = dump(),
					?assertEqual([Apid], State2#state.agents),
					?assertEqual(1, length(State2#state.dispatchers))
				end
			},
			{
				"Agent died, so a dipatcher ends",
				fun() ->
					{ok, Apid} = agent_manager:start_agent(#agent{login = "testagent"}),
					agent:set_state(Apid, idle),
					receive
					after 100 ->
						ok
					end,
					State1 = dump(),
					?assertEqual(State1#state.agents, [Apid]),
					?assertEqual(1, length(State1#state.dispatchers)),
					exit(Apid, test_kill),
					receive
					after 100 ->
						ok
					end,
					State2 = dump(),
					?assertEqual([], State2#state.agents),
					?assertEqual([], State2#state.dispatchers)
				end
			},
			{
				"Unexpected dispatcher death",
				fun() ->
					{ok, Apid} = agent_manager:start_agent(#agent{login = "testagent"}),
					agent:set_state(Apid, idle),
					#state{dispatchers = [PidToKill]} = dump(),
					exit(PidToKill, test_kill),
					receive
					after 100 ->
						ok
					end,
					State1 = dump(),
					?assertEqual(1, length(State1#state.dispatchers)),
					?assertNot([PidToKill] =:= State1#state.dispatchers)
				end
			},
			{
				"Agent unavailable, do a dispatcher ends",
				fun() ->
					{ok, Apid} = agent_manager:start_agent(#agent{login = "testagent"}),
					agent:set_state(Apid, idle),
					receive
					after 100 ->
						ok
					end,
					State1 = dump(),
					?assertEqual([Apid], State1#state.agents),
					?assertEqual(1, length(State1#state.dispatchers)),
					agent:set_state(Apid, released, default),
					receive
					after 100 ->
						ok
					end,
					State2 = dump(),
					?assertEqual([], State2#state.agents),
					?assertEqual([], State2#state.agents)
				end
			},
			{
				"Agent avail and already tracked",
				fun() ->
					{ok, Apid} = agent_manager:start_agent(#agent{login = "testagent"}),
					agent:set_state(Apid, idle),
					receive
					after 100 ->
						ok
					end,
					State1 = dump(),
					?assertEqual([Apid], State1#state.agents),
					?assertEqual(1, length(State1#state.dispatchers)),
					gen_server:cast(?MODULE, {now_avail, Apid}),
					State2 = dump(),
					?assertEqual([Apid], State2#state.agents),
					?assertEqual(1, length(State1#state.dispatchers))
				end
			}
		]
	}.

-define(MYSERVERFUNC, fun() -> {ok, _Pid} = start_link(), {?MODULE, fun() -> stop() end} end).

-include("gen_server_test.hrl").

-endif.
