%%% @author sergey <me@seriyps.ru>
%%% @copyright (C) 2019, sergey
%%% @doc
%%% Fake TLS 'CBC' stream codec
%%% https://github.com/telegramdesktop/tdesktop/commit/69b6b487382c12efc43d52f472cab5954ab850e2
%%% It's not real TLS, but it looks like TLS1.3 from outside
%%% @end
%%% Created : 24 Jul 2019 by sergey <me@seriyps.ru>

-module(mtp_fake_tls).

-behaviour(mtp_codec).

-export([format_secret/2]).
-export([from_client_hello/2,
         new/0,
         try_decode_packet/2,
         decode_all/2,
         encode_packet/2]).
-export_type([codec/0, meta/0]).

-include_lib("hut/include/hut.hrl").

-dialyzer(no_improper_lists).

-record(st, {}).

-record(client_hello,
        {pseudorandom :: binary(),
         session_id :: binary(),
         cipher_suites :: list(),
         compression_methods :: list(),
         extensions :: [{non_neg_integer(), any()}]
        }).

-define(MAX_IN_PACKET_SIZE, 65535).      % sizeof(uint16) - 1
-define(MAX_OUT_PACKET_SIZE, 16384).     % 2^14 https://tools.ietf.org/html/rfc8446#section-5.1

-define(TLS_10_VERSION, 3, 1).
-define(TLS_12_VERSION, 3, 3).
-define(TLS_13_VERSION, 3, 4).
-define(TLS_REC_CHANGE_CIPHER, 20).
-define(TLS_REC_HANDSHAKE, 22).
-define(TLS_REC_DATA, 23).

-define(TLS_12_DATA, ?TLS_REC_DATA, ?TLS_12_VERSION).

-define(DIGEST_POS, 11).
-define(DIGEST_LEN, 32).

-define(TLS_TAG_CLI_HELLO, 1).
-define(TLS_TAG_SRV_HELLO, 2).
-define(TLS_CIPHERSUITE, 192, 47).
-define(TLS_EXTENSIONS,
        0, 18,                                  % Extensions length
        255, 1, 0, 1, 0,                        % renegotiation_info
        0, 5, 0, 0,                             % status_request
        0, 16, 0, 5, 0, 3, 2, 104, 50           % ALPN
       ).
-define(TLS_CHANGE_CIPHER, ?TLS_REC_CHANGE_CIPHER, ?TLS_12_VERSION, 0, 1, 1).

-define(EXT_SNI, 0).
-define(EXT_SNI_HOST_NAME, 0).

-define(EXT_KEY_SHARE, 51).

-define(EXT_SUPPORTED_VERSIONS, 43).

-define(APP, mtproto_proxy).

-opaque codec() :: #st{}.

-type meta() :: #{session_id := binary(),
                  timestamp := non_neg_integer(),
                  sni_domain => binary()}.


%% @doc format TLS secret
-spec format_secret(binary(), binary()) -> binary().
format_secret(Secret, Domain) when byte_size(Secret) == 16 ->
    base64url(<<16#ee, Secret/binary, Domain/binary>>);
format_secret(HexSecret, Domain) when byte_size(HexSecret) == 32 ->
    format_secret(mtp_handler:unhex(HexSecret), Domain).

base64url(Bin) ->
    %% see https://hex.pm/packages/base64url
    << << (urlencode_digit(D)) >> || <<D>> <= base64:encode(Bin), D =/= $= >>.

urlencode_digit($/) -> $_;
urlencode_digit($+) -> $-;
urlencode_digit(D)  -> D.


-spec from_client_hello(binary(), binary()) ->
                               {ok, iodata(), meta(), codec()}.
from_client_hello(Data, Secret) ->
    #client_hello{pseudorandom = ClientDigest,
                  session_id = SessionId,
                  extensions = Extensions} = CliHlo = parse_client_hello(Data),
    ?log(debug, "TLS ClientHello=~p", [CliHlo]),
    ServerDigest = make_server_digest(Data, Secret),
    <<Zeroes:(?DIGEST_LEN - 4)/binary, _/binary>> = XoredDigest =
        crypto:exor(ClientDigest, ServerDigest),
    lists:all(fun(B) -> B == 0 end, binary_to_list(Zeroes)) orelse
        error({protocol_error, tls_invalid_digest, XoredDigest}),
    <<_:(?DIGEST_LEN - 4)/binary, Timestamp:32/unsigned-little>> = XoredDigest,
    KeyShare = make_key_share(Extensions),
    SrvHello0 = make_srv_hello(binary:copy(<<0>>, ?DIGEST_LEN), SessionId, KeyShare),
    FakeHttpData = crypto:strong_rand_bytes(rand:uniform(256)),
    Response0 = [_, CC, DD] =
        [as_tls_frame(?TLS_REC_HANDSHAKE, SrvHello0),
         as_tls_frame(?TLS_REC_CHANGE_CIPHER, [1]),
         as_tls_frame(?TLS_REC_DATA, FakeHttpData)],
    SrvHelloDigest = crypto:hmac(sha256, Secret, [ClientDigest | Response0]),
    SrvHello = make_srv_hello(SrvHelloDigest, SessionId, KeyShare),
    Response = [as_tls_frame(?TLS_REC_HANDSHAKE, SrvHello),
                CC,
                DD],
    Meta0 = #{session_id => SessionId,
              timestamp => Timestamp},
    Meta = case lists:keyfind(?EXT_SNI, 1, Extensions) of
               {_, [{?EXT_SNI_HOST_NAME, Domain}]} ->
                       Meta0#{sni_domain => Domain};
               _ ->
                   Meta0
           end,
    {ok, Response, Meta, new()}.


parse_client_hello(<<?TLS_REC_HANDSHAKE, ?TLS_10_VERSION, 512:16/unsigned-big, %Frame
                     ?TLS_TAG_CLI_HELLO, 508:24/unsigned-big, ?TLS_12_VERSION,
                     Random:?DIGEST_LEN/binary,
                     SessIdLen, SessId:SessIdLen/binary,
                     CipherSuitesLen:16/unsigned-big, CipherSuites:CipherSuitesLen/binary,
                     CompMethodsLen, CompMethods:CompMethodsLen/binary,
                     ExtensionsLen:16/unsigned-big, Extensions:ExtensionsLen/binary>>
                     %% _/binary>>
                  ) ->
    #client_hello{
       pseudorandom = Random,
       session_id = SessId,
       cipher_suites = parse_suites(CipherSuites),
       compression_methods = parse_compression(CompMethods),
       extensions = parse_extensions(Extensions)
      }.

parse_suites(Bin) ->
    [Suite || <<Suite:16/unsigned-big>> <= Bin].

parse_compression(Bin) ->
    [Bin].                                      %TODO: just binary_to_list(Bin)

parse_extensions(Exts) ->
    [{Type, parse_extension(Type, Data)}
     || <<Type:16/unsigned-big, Length:16/unsigned-big, Data:Length/binary>> <= Exts].

parse_extension(?EXT_SNI, <<ListLen:16/unsigned-big, List:ListLen/binary>>) ->
    [{Type, Value}
     || <<Type, Len:16/unsigned-big, Value:Len/binary>> <= List];
parse_extension(?EXT_KEY_SHARE, <<Len:16/unsigned-big, Exts:Len/binary>>) ->
    [{Group, Key}
     || <<Group:16/unsigned-big, KeyLen:16/unsigned-big, Key:KeyLen/binary>> <= Exts];
parse_extension(_Type, Data) ->
    Data.


make_server_digest(<<Left:?DIGEST_POS/binary, _:?DIGEST_LEN/binary, Right/binary>>, Secret) ->
    Msg = [Left, binary:copy(<<0>>, ?DIGEST_LEN), Right],
    crypto:hmac(sha256, Secret, Msg).

make_key_share(Exts) ->
    case lists:keyfind(?EXT_KEY_SHARE, 1, Exts) of
        {_, KeyShares} ->
            SupportedKeyShares =
                lists:dropwhile(
                  fun({Group, Key}) ->
                          not (
                            byte_size(Key) < 128
                            andalso
                            lists:member(       % https://tools.ietf.org/html/rfc8446#appendix-B.3.1.4
                              Group, [% secp256r1
                                      16#0017,
                                      % secp384r1
                                      16#0018,
                                      % secp521r1
                                      16#0019,
                                      % x25519
                                      16#001D,
                                      % x448
                                      16#001E,
                                      % ffdhe2048
                                      16#0100,
                                      % ffdhe3072
                                      16#0101,
                                      % ffdhe4096
                                      16#0102,
                                      % ffdhe6144
                                      16#0103,
                                      % ffdhe8192
                                      16#0104])
                           )
                  end, KeyShares),
            case SupportedKeyShares of
                [] ->
                    error({protocol_error, tls_unsupported_key_shares, KeyShares});
                [{KSGroup, KSKey} | _] ->
                    {KSGroup, crypto:strong_rand_bytes(byte_size(KSKey))}
            end;
        _ ->
            error({protocol_error, tls_missing_key_share_ext, Exts})
    end.

make_srv_hello(Digest, SessionId, {KeyShareGroup, KeyShareKey}) ->
    %% https://tools.ietf.org/html/rfc8446#section-4.1.3
    KeyShareEntity = <<KeyShareGroup:16/unsigned-big, (byte_size(KeyShareKey)):16/unsigned-big,
                       KeyShareKey/binary>>,
    Extensions =
        [<<?EXT_KEY_SHARE:16/unsigned-big, (byte_size(KeyShareEntity)):16/unsigned-big>>,
         KeyShareEntity,
         <<?EXT_SUPPORTED_VERSIONS:16/unsigned-big, 2:16/unsigned-big, ?TLS_13_VERSION>>],
    SessionSize = byte_size(SessionId),
    Payload = [<<?TLS_12_VERSION,
                 Digest:?DIGEST_LEN/binary,
                 SessionSize,
                 SessionId:SessionSize/binary,
                 ?TLS_CIPHERSUITE,
                 0,                              % Compression method
                 (iolist_size(Extensions)):16/unsigned-big>>
                   | Extensions],
    [<<?TLS_TAG_SRV_HELLO, (iolist_size(Payload)):24/unsigned-big>> | Payload].


-spec new() -> codec().
new() ->
    #st{}.

-spec try_decode_packet(binary(), codec()) -> {ok, binary(), binary(), codec()}
                                                  | {incomplete, codec()}.
try_decode_packet(<<?TLS_12_DATA, Size:16/unsigned-big,
                    Data:Size/binary, Tail/binary>>, St) ->
    {ok, Data, Tail, St};
try_decode_packet(<<?TLS_REC_CHANGE_CIPHER, ?TLS_12_VERSION, Size:16/unsigned-big,
                    _Data:Size/binary, Tail/binary>>, St) ->
    %% "Change cipher" are ignored
    try_decode_packet(Tail, St);
try_decode_packet(Bin, St) when byte_size(Bin) =< (?MAX_IN_PACKET_SIZE + 5) ->  % 5 is ?TLS_12_DATA + Size:16 size
    {incomplete, St};
try_decode_packet(Bin, _St) ->
    error({protocol_error, tls_max_size, byte_size(Bin)}).

%% @doc decodes as much TLS packets as possible to single binary
-spec decode_all(binary(), codec()) -> {Decoded :: binary(), Tail :: binary(), codec()}.
decode_all(Bin, St) ->
    decode_all(Bin, <<>>, St).

decode_all(Bin, Acc, St0) ->
    case try_decode_packet(Bin, St0) of
        {incomplete, St} ->
            {Acc, Bin, St};
        {ok, Data, Tail, St} ->
            decode_all(Tail, <<Acc/binary, Data/binary>>, St)
    end.


-spec encode_packet(binary(), codec()) -> {iodata(), codec()}.
encode_packet(Bin, St) ->
    {encode_as_frames(Bin), St}.

encode_as_frames(Bin) when byte_size(Bin) =< ?MAX_OUT_PACKET_SIZE ->
    as_tls_data_frame(Bin);
encode_as_frames(<<Chunk:?MAX_OUT_PACKET_SIZE/binary, Tail/binary>>) ->
    [as_tls_data_frame(Chunk) | encode_as_frames(Tail)].

as_tls_data_frame(Bin) ->
    as_tls_frame(?TLS_REC_DATA, Bin).

-spec as_tls_frame(byte(), iodata()) -> iodata().
as_tls_frame(Type, Data) ->
    Size = iolist_size(Data),
    [<<Type, ?TLS_12_VERSION, Size:16/unsigned-big>> | Data].
