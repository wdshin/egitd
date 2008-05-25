-module(server).
-export([start_link/0, init/1]).

start_link() ->
  proc_lib:start_link(?MODULE, init, [self()]).

init(Parent) ->
  LSock = try_listen(10),
  proc_lib:init_ack(Parent, {ok, self()}),
  loop(LSock).
  
try_listen(0) ->
  io:format("Could not listen on port 9418~n");
try_listen(Times) ->
  Res = gen_tcp:listen(9418, [list, {packet, 0}, {active, false}]),
  case Res of
    {ok, LSock} ->
      io:format("Listening on port 9418~n"),
      LSock;
    {error, Reason} ->
      io:format("Could not listen on port 9418: ~p~n", [Reason]),
      timer:sleep(5000),
      try_listen(Times - 1)
  end.
    
loop(LSock) ->
  {ok, Sock} = gen_tcp:accept(LSock),
  spawn(fun() -> handle_method(Sock) end),
  loop(LSock).
  
handle_method(Sock) ->
  % get the requested method
  {ok, MethodSpec} = gen_tcp:recv(Sock, 0),
  Method = extract_method_name(MethodSpec),
  
  % dispatch
  case Method of
    {ok, "git-upload-pack"} ->
      handle_upload_pack(Sock);
    invalid ->
      gen_tcp:send(Sock, "Invalid method declaration. Upgrade to the latest git.\n"),
      ok = gen_tcp:close(Sock)
  end.
  
handle_upload_pack(Sock) ->
  % make the port
  Command = "git upload-pack /Users/tom/dev/sandbox/git/m/o/j/mojombo/god.git",
  Port = open_port({spawn, Command}, []),
  
  % the initial output from git-upload-pack lists the SHA1s of each head.
  % data completion is denoted by "0000" on it's own line.
  % this is sent back immediately to the client.
  Index = gather_out(Port),
  gen_tcp:send(Sock, Index),
  
  % once the client receives the index data, it will demand that specific
  % revisions be packaged and sent back. this demand will be forwarded to
  % git-upload-pack.
  {ok, Demand} = gen_tcp:recv(Sock, 0),
  port_command(Port, Demand),
  
  % in response to the demand, git-upload-pack will stream out the requested
  % pack information. data completion is denoted by "0000".
  stream_out(Port, Sock),
  
  % close connection
  ok = gen_tcp:close(Sock).

gather_out(Port) ->
  gather_out(Port, "").
  
gather_out(Port, DataSoFar) ->
  {data, Data} = readline(Port),
  TotalData = DataSoFar ++ Data,
  case regexp:first_match(TotalData, "\n0000$") of
    {match, _Start, _Length} ->
      TotalData;
    _Else ->
      gather_out(Port, TotalData)
  end.
  
stream_out(Port, Sock) ->
  {data, Data} = readline(Port),
  gen_tcp:send(Sock, Data),
  case regexp:first_match(Data, "0000$") of
    {match, _Start, _Length} ->
      done;
    _Else ->
      stream_out(Port, Sock)
  end.

readline(Port) ->
  receive
    {Port, {data, Data}} ->
      {data, Data};
    Msg ->
      io:format("unknown message ~p~n", [Msg]),
      {error, Msg}
    after 5000 ->
      io:format("timed out waiting for port~n"),
      {error, timeout}
  end.
  
extract_method_name(MethodSpec) ->
  case regexp:match(MethodSpec, "....[a-z\-]+ ") of
    {match, Start, Length} ->
      {ok, string:substr(MethodSpec, Start + 4, Length - 5)};
    _Else ->
      invalid
  end.