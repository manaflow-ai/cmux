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

Your namespace is your app id in reverse DNS (`com.acme.diff`). App ids are
unique in the cmux registry, so registering the app reserves the namespace.
`cmux.*` is first party. The router refuses a provider whose hello declares an
op or event outside its namespaces, and the SDK refuses to register one.

In the IR, declare the namespace with its owner, then your ops, events and
types:

```json
{
  "namespaces": [{ "name": "com.acme.diff", "owner": "app:com.acme.diff" }],
  "ops": [{
    "name": "com.acme.diff.file.read", "kind": "read", "scope": "com.acme.diff:read",
    "params": { "$ref": "#/types/ReadParams" }, "result": { "$ref": "#/types/ReadResult" },
    "errors": ["com.acme.diff.not_found"]
  }],
  "events": [],
  "types": { "ReadParams": { "type": "object", "...": "JSON Schema 2020-12" } }
}
```

Rules the generator enforces: op names are `<namespace>.<family>.<verb>`, error
codes start with the op's namespace, a third party's namespace equals its owner
app id, and every schema keyword is one the validators implement (no silent
accept-all).

The registry's install and registration flow does not exist yet. Today the
router's admission check is the only gate.

## 2. Generate the SDK from the IR

```bash
python3 cmux-tui/bindings/codegen/pane/generate.py --write \
  --ir cmux-tui/spec/pane-protocol.json \
  --out ./acmepane --package acmepane \
  --provider-ns com.acme.diff
```

Use `--check` in CI; it exits 1 when the package is stale. Omit
`--provider-ns` for a client-only package. You need `python3` and `gofmt`.

The package contains:

- `types.go`: one Go type per IR type. Required arrays and maps marshal as
  `[]`/`{}`, never `null`.
- `validate.go`: `Validate<Type>(any) error` for every type, plus the
  `Validators` map.
- `client.go`: `NewClient(conn).<Namespace>().<FamilyVerb>(ctx, params)`. It
  validates params before sending and results and events after receiving.
- `provider.go`: `NewProvider()`, `<Namespace>Handler`,
  `Register<Namespace>(p, h)`, and `Publish<Namespace><Event>(p, data)`.

The runtime validates incoming params before your handler runs, and validates
your result before it is sent. Peers are untrusted.

## 3. Implement and run the provider

```go
type greeter struct{}

func (greeter) GreetSay(ctx context.Context, call *pane.Call, p hellopane.HelloParams) (hellopane.HelloResult, error) {
	return hellopane.HelloResult{Message: "Hello, " + p.Name + "!"}, nil
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

- **Framing.** On unix sockets, each message is a 4-byte big-endian length and
  then the message. The maximum is 16 MiB. A zero length or an oversized
  prefix is fatal. On WebSocket, each message is a text message.
- **Envelope.** `call`, `ok`, `err`, `sub`, `ev`, `unsub`, `cancel`,
  `release` and `auth` are supported. A call without `params` gets `{}`, and
  `ok` or `ev` without a value gets `null`. A malformed envelope is dropped,
  and the connection stays open. Ids start at 1; id 0 is reserved for auth.
  Incoming calls run concurrently, and their results go back in completion
  order. `cancel` cancels the handler's context and gets the reply
  `cmux.protocol.cancelled`. Event `seq` starts at 1 per subscription. A gap
  in `seq` means events were dropped for a slow consumer.
- **Admission.** The provider's first call on the router connection is
  `cmux.router.hello`:
  `{proto: "cmux.pane/0", app, namespaces, ops: [{name, kind, scope}], events: [{name, scope}], interfaces, ir: {version, sha256}, endpoints: [{kind: "unix", path} | {kind: "ws", url}], credential?}`.
  The router answers `{router_key: <unpadded base64url Ed25519 public key>, provider: <id>}`.
- **Capability tokens.** A token is a compact JWS with `alg: "EdDSA"` and
  `typ: "cmux-cap+jwt"`. Its claims are `{sub, app, ns[], scopes?[], ops?[], origin?, exp, aud}`,
  with `exp` in Unix seconds. `aud` must equal the provider's app id. A
  token grants an op when the op's namespace is in `ns`, and the op's name is
  in `ops` or its IR scope is in `scopes`. Unknown claims are ignored. A
  `crit` header is refused.
- **Direct peers.** On the unix listener (`-listen`, mode 0600, in a directory
  that is not group- or world-writable) and on the WebSocket listener (`-ws`,
  loopback only), the first message must be `{"t":"auth","token":...}`
  within 2 s. Success gets the reply `{"t":"ok","id":0}`. Refusal gets the
  reply `{"t":"err","id":0,"code":"cmux.protocol.auth_refused",...}`, and then
  the connection closes. A later `auth` refreshes the token. Every call
  rechecks `exp` and the grant. On WebSocket, the Host header must be a
  loopback name, the Origin header must be present (and listed in
  `-allow-origin` if that flag is set), and the token's `origin` must equal
  the Origin header.
- **Error codes.** `cmux.protocol.{closed, cancelled, unknown_op, unknown_stream, invalid_params, invalid_result, invalid_event, internal, credit_exceeded, stream_aborted, auth_refused}`
  match the TS lane. `forbidden`, `busy` and `bad_message` are Go additions.
  Validation failures carry `details: {issues: [{path, message}]}` with
  JSON Pointer paths.

Not implemented yet: byte streams. `open` is refused with
`cmux.protocol.unknown_op`, a binary WebSocket frame closes the session, and
only the binary frame codec exists. Handles (`release` goes to
`Provider.OnRelease`). Interface implementation contracts (only their names are
generated).

## Tests

```bash
cd cmux-tui/bindings/go-pane && go test -race ./...
PYTHONPATH=cmux-tui/bindings python3 -m unittest discover -s cmux-tui/bindings/codegen/tests -p 'test_pane*'
```

The Go tests cover framing, envelopes, tokens, dispatch, cancel, events,
direct unix and WebSocket auth, generated validators, and a fake router that
admits the example provider in a real child process, once over an inherited
socketpair fd and once over a router socket path. Shared conformance vectors
run when `PANE_PROTOCOL_VECTORS` or `/tmp/pane-protocol/vectors.json` exists.
