# cmux pane protocol: Go provider SDK

Status: draft v0. The wire and the IR can still change; pin a commit.

A provider is a separate process that owns a namespace and serves its ops to
pages and other peers. This module gives you the runtime (package `pane`) and
a generator that turns the pane-protocol IR into a typed Go package: types,
validators, a client, and one handler interface per namespace you own. It uses
only the Go standard library.

The working example is [`examples/hello`](examples/hello): the third-party
provider `com.example.hello`, serving `com.example.hello.greet.say`.

## 1. Reserve a namespace

Your namespace is your app id, `<publisher>.<name>` (`octo.diff_tools`).
Labels use `[a-z0-9_]`; write `-` as `_`. App ids are unique in the cmux
registry, so registering the app reserves the namespace. `cmux` and `cmux.*`
are first party. The router refuses a provider whose hello declares an op or
event outside its namespaces, and the SDK refuses to register one.

Your ops enter the catalog through your app manifest's catalog fragment
(decision 14). The router's registry is the committed IR plus installed
fragments. A fragment has the same format as the IR, restricted to your own
namespace:

```json
{
  "namespaces": [{ "name": "octo.diff_tools", "owner": "app:octo.diff_tools" }],
  "ops": [{
    "name": "octo.diff_tools.diff.list", "owner": "app:octo.diff_tools",
    "kind": "read", "scope": "diff:read", "risk": "read", "gesture": false, "paths": [],
    "mcp": { "expose": "opt_in", "group": "diff" },
    "params": { "$ref": "#/types/OctoListParams" },
    "result": { "type": "array", "items": { "type": "string" } },
    "errors": []
  }],
  "types": { "OctoListParams": { "type": "object", "properties": {}, "additionalProperties": false } }
}
```

The generator enforces these rules:

- Op names are `<namespace>.<family>.<verb>`.
- Each op's `owner` equals its namespace's owner.
- Error codes start with the op's namespace.
- Third-party ops declare no aliases. A first-party alias never names an op,
  an event or another alias (decision 18).
- `paths` lists top-level string params that are filesystem paths
  (decision 22).
- `mcp` is `{expose: default|opt_in|never, group?}`; when it is missing,
  `expose` is `never`. MCP tool names (the op name with `.` and `-` as `_`) are
  unique and at most 48 characters, for every op (decision 23).
- `cli` is `{path, visible, positional?}`, with a path unique per owner.
- `secret_output` is derived from `x-cmux-secret` in the result schema, and a
  declared value is ignored (decision 21).
- Every schema keyword is in the shared subset (decision 9), so no validator
  silently accepts everything.

The registry's install and registration flow does not exist yet. Today the
router's admission check is the only gate.

## 2. Generate the SDK from the IR

```bash
python3 cmux-tui/bindings/codegen/pane/generate.py --write \
  --ir cmux-tui/crates/cmux-pane-protocol/spec/pane-protocol.json \
  --fragment octo-fragment.json \
  --out ./octopane --package octopane \
  --provider-ns octo.diff_tools
```

Use `--check` in CI; it exits 1 when the package is stale. Omit
`--provider-ns` for a client-only package. Omit `--fragment` for first-party
namespaces. With a fragment, the package's `IRSHA256` is the fragment file's
SHA-256, and the hello sends it. You need `python3` and `gofmt`.

The IR is the Rust crate's committed `emit-ir` output,
`cmux-tui/crates/cmux-pane-protocol/spec/pane-protocol.json`. Scope classes
come from `cmux-tui/crates/cmux-app-host/schema/v2/scope-classes.json`, the
same table that emit-ir compiles in (first matching rule wins). A third party
outside this repo passes a copy of that table with `--scope-classes`.

The package contains:

- `types.go`: one Go type per IR type. Required arrays and maps marshal as
  `[]`/`{}`, never `null`. A tagged `oneOf` becomes one struct with the tag
  and the union of the variant fields. A `oneOf` of string consts becomes a
  string enum.
- `validate.go`: `Validate<Type>(any) error` for every type, plus the
  `Validators` map.
- `ops.go`: op and event name constants, error codes, and `Catalog`. The
  catalog is the IR as the runtime enforces it. Per op it holds the scope,
  `paths`, `risk`, `gesture`, `scope_class`, `server_only`, MCP exposure and
  tool name, CLI verb, `secret_output`, and the params and result
  validators.
- `client.go`: `NewClient(conn).<Namespace>().<FamilyVerb>(ctx, params)` and
  `Subscribe<FamilyEvent>(ctx, filter)`. It validates params before sending,
  and results and events after receiving.
- `provider.go`: `NewProvider()`, `<Namespace>Handler`,
  `Register<Namespace>(p, h)`, and `Publish<Namespace><Event>(p, data)`.

**Path params.** Before your handler runs, the runtime confines each `paths`
param to the caller token's `roots`. It makes the path absolute, resolves `..`
and symlinks (the path must exist), and compares path components, so
`/a/rootx` is not inside `/a/root`. The handler gets the canonical path. A
path outside every root, or a token without roots, gets
`cmux.protocol.forbidden`. A connection without a token (the router
connection) has no roots, so path ops fail closed there.
`pane.ConfinePath` is exported for your own extra checks.

**All checks run in the runtime.** `pane.NewProvider` takes the catalog, and
`Provider.Register(op, handler)` accepts only an op that is in the catalog,
inside your namespaces, and has generated validators. A handler therefore
cannot skip a check. For every call, the runtime does these steps in order:

1. Checks the token's namespace and scope.
2. Confines the path params.
3. Validates the params with the catalog validator.
4. Calls your handler.
5. Validates the result. An invalid result is logged and sent as
   `cmux.protocol.internal`.

Decisions 29 and 30 will add a `server_only` check and a gesture-token check
before the path step, and the gesture `jti` spend after validation. Events
are validated in `Publish` and `Sink.Emit`. Peers are untrusted. Ops of kind
`stream` get no method yet, because byte streams are not implemented.

Third-party scope families are bare for now (`hello:read`), because the scope
table has no namespaced rules. Decision 28 will change them to
`<namespace>:<verb>`.

## 3. Implement and run the provider

```go
type greeter struct{}

func (greeter) GreetSay(ctx context.Context, call *pane.Call, p hellopane.HelloParams) (hellopane.HelloResult, error) {
	return hellopane.HelloResult{Message: "hello, " + p.Name}, nil
}

// One method per event stream: runs before the subscribe ok. Emit goes to
// this subscriber only. Do not block here.
func (greeter) SubscribeGreetTicks(ctx context.Context, call *pane.Call, sink *pane.TypedSink[hellopane.HelloResult]) error {
	return sink.Emit(hellopane.HelloResult{Message: "tick 1"})
}

p, _ := hellopane.NewProvider()
_ = hellopane.RegisterComExampleHello(p, greeter{})
err := p.Run(ctx, pane.RunOptions{Listen: sockPath, WebSocket: "127.0.0.1:0"})
```

Return `*pane.Error` with a code that the IR declares for the op. A
`cmux.protocol.*` code is also allowed. Any other error is logged and sent as
`cmux.protocol.internal`, so internal details do not leak to the peer.
`call.Claims` holds the caller's verified token on direct connections.
`call.Conn.Call` calls back into the caller.

The provider runs in one of two ways:

| How it starts | What it receives | What it does |
| --- | --- | --- |
| The router spawns it | `CMUX_PANE_ROUTER_FD=<n>`: a connected socketpair fd inherited as fd n (3 or higher) | Uses the fd, then unsets the variable. The inherited fd is the credential. |
| It starts by itself | `-router PATH` or `CMUX_PANE_ROUTER_SOCKET=PATH`, plus `CMUX_PANE_APP_CREDENTIAL` | Dials the router's unix socket and sends the credential in the hello. |

If both are set, the fd wins. A router that spawns providers must create the
socketpair close-on-exec and pass only the provider's end, or the child also
holds the router's end and never sees EOF.

```bash
cd cmux-tui/bindings/go-pane
go build -o hello ./examples/hello
CMUX_PANE_ROUTER_SOCKET=$XDG_RUNTIME_DIR/cmux/router.sock \
CMUX_PANE_APP_CREDENTIAL=... ./hello -listen /tmp/hello-$USER/hello.sock -ws 127.0.0.1:0
```

The provider exits when its router connection closes.

## Wire summary (what this SDK implements)

The shared vectors (`vectors.json` from the Rust lane) pin these rules.

- **Framing.** On unix sockets, a frame is a 4-byte big-endian header and then
  the message. Bit 31 of the header marks a binary data frame; the low 31 bits
  are the length, at most 16 MiB. A text frame must be UTF-8. On WebSocket, a
  frame is a text or binary message. A data frame is
  `[u32 stream][u32 credit][payload]`.
- **Envelope.** The SDK handles `call`, `ok`, `err`, `sub`, `ev`, `unsub`,
  `cancel`, `release`, `open`, `credit`, `end`, `auth` and `bye`. Encoding uses
  one canonical field order. A call without `params` gets `{}`; `ok` or `ev`
  without a value gets `null`.
- **Ids.** Request, subscription, seq and stream ids are integers in
  1..2^53-1. Only `ok`/`err` may carry id 0, and only for the auth reply.
- **Bad messages.** A malformed message, or one with an id out of range, gets
  `cmux.protocol.bad_message`. The reply echoes the id when it is readable and
  in range, otherwise it uses 0, and the connection stays open. A framing error
  closes the connection.
- **Calls.** Incoming calls run concurrently, and results go back in
  completion order. `cancel` cancels the handler's context and gets the reply
  `cmux.protocol.cancelled`.
- **Events.** `seq` starts at 1 per subscription and counts events actually
  sent. After the provider drops events for a slow subscriber, the next event
  carries `"gap":true`. Clients see that as `Event.Gap` or `TypedEvent.Gap`
  and should resync.
- **Streams.** The connecting side opens odd stream ids, the accepting side
  even ones. A wrong parity gets `cmux.protocol.stream_aborted`. Byte streams
  are not implemented, so a correct `open` gets `cmux.protocol.unknown_op`,
  and data frames are dropped.
- **Admission.** The provider's first call on its router connection is
  `cmux.router.hello` with `ProviderHello`
  `{proto: "cmux.pane/0", app, namespaces, ops: [{name, kind, scope}], events: [{name, scope}], interfaces, ir: {version, sha256}, endpoints: [{kind: "unix", path} | {kind: "ws", url}], credential?}`.
  The router answers with `ProviderWelcome`
  `{router_key: <unpadded base64url Ed25519 public key>, provider: <app id = token aud>}`.
- **Capability tokens.** A token is a compact JWS. Its header is exactly
  `{"alg":"EdDSA","typ":"cmux-cap+jwt"}`. Its claims are
  `{sub, page?, app, ns[], scopes[], roots?[], origin?, aud, exp, iat}`, with times in
  Unix seconds. `aud` must equal the provider's app id. A connection that has
  an Origin requires `origin` to equal it exactly (bundled pages are
  `cmux-page://<id>`). A native connection skips the origin check. A token
  grants an op when the op's namespace is in `ns`, and the op's IR scope is in
  `scopes` or its name is in `ops`.
- **Direct peers.** The unix listener (`-listen`, mode 0600, in a private
  directory) and the WebSocket listener (`-ws`, loopback only) work the same
  way. The first message must be `{"t":"auth","token":...}` within 2 s.
  - Success: `{"t":"ok","id":0,"value":{sub, app|page, exp, provider}}`.
  - Refusal: `{"t":"err","id":0,"code":"cmux.protocol.auth_refused","details":{"reason":"timeout|missing_token|invalid_token"}}`,
    then close (WebSocket close code 4001).
  - After an expiry, calls get `cmux.protocol.token_expired` (retryable). A
    new `auth` refreshes the token.
  - On WebSocket, the Host header must be loopback and an Origin header is
    required. `-allow-origin` restricts it further.
- **Admission digest.** A first-party provider (`cmux` or `cmux.*`) must send
  the router's IR digest, or the router refuses it with `bad_message` and
  `details.reason: "ir_mismatch"`. A third party sends its fragment's digest.
  `pane.CheckHello` implements the rule for fake routers.
- **Error codes.** `cmux.protocol.{closed, cancelled, unknown_op, unknown_stream, invalid_params, invalid_result, invalid_event, internal, credit_exceeded, stream_aborted, auth_refused, token_expired, forbidden, busy, bad_message, not_routed, too_large}`.
  Validation failures carry `details: {issues: [{path, message}]}` with JSON
  Pointer paths.

Not implemented yet:

- Byte streams.
- Handles: `release` goes to `Provider.OnRelease`.
- `allOf` with more than one schema.
- Interface contracts: only their names are generated.

## Tests

```bash
cd cmux-tui/bindings/go-pane && go test -race ./...
PYTHONPATH=cmux-tui/bindings python3 -m unittest discover -s cmux-tui/bindings/codegen/pane/tests
```

The Go tests cover framing, envelopes, tokens, dispatch, cancel, events,
direct unix and WebSocket auth, generated validators, and a fake router that
admits the example provider in a real child process, once over an inherited
socketpair fd and once over a router socket path. The shared conformance
vectors run when `PANE_PROTOCOL_VECTORS` or `/tmp/pane-protocol/vectors.json`
exists:

- envelopes (with canonical re-encoding), data frames and validators;
- unix framing;
- tokens: the vector key re-mints the vector token byte for byte;
- roots: the vector layout is built in a temp dir, and each case runs through
  `ConfinePath` and through a real call;
- admission digests;
- sessions, played against the example provider's listener;
- fragments and the keyword subset, checked by the Python tests.

Every test is headless: sockets only, no windows.
