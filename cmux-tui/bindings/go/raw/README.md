# cmux Go SDK

The Go SDK covers all 101 protocol-12 commands and 46 event shapes using only
the Go standard library.

```go
import cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"

ctx := context.Background()
client, err := cmux.NewClient(cmux.Options{})
if err != nil {
    panic(err)
}
defer client.Close()

surface, err := client.NewWorkspace(ctx, cmux.NewWorkspaceOptions{
    Name: cmux.Value("sdk-demo"),
})
if err != nil {
    panic(err)
}
text := "printf 'hello from Go\\n'\r"
if err := client.Send(ctx, surface.Surface, cmux.SendOptions{
    Text: cmux.Value(text),
}); err != nil {
    panic(err)
}
screen, err := client.ReadScreen(ctx, surface.Surface)
```

`NewClient(cmux.Options{})` uses `CMUX_TUI_SOCKET`, then legacy
`CMUX_MUX_SOCKET`, then `$XDG_RUNTIME_DIR`, `$TMPDIR`, or `/tmp`. It applies
the server's short-path fallback when the preferred Unix socket path exceeds
the platform limit. An explicit `Options.SocketPath` has highest precedence.

Every command method accepts `context.Context`. The client serializes commands
on one connection. Subscribe and attach streams own dedicated connections, so
`Stream.Close` cancels one local stream without disrupting commands.

Generated methods validate command and present-field protocol requirements
before writing the command. This covers fields added after their command, such
as `send.paste`, `run.key`, attachment sizing, and workspace registry keys.
`CommandMetadata.FieldSince` and `FieldCapabilities` expose the same gates.

Unix clients allow control, frontend, and local-admin commands by default.
Provider-owned workspace mutations return `ErrAuthority` before any socket
write unless `Options.EnableProviderAuthority` is true:

```go
provider, err := cmux.NewClient(cmux.Options{
    EnableProviderAuthority: true,
})
```

The opt-in changes the local SDK policy; the server still validates provider
authority. `SendRaw` deliberately bypasses generated protocol and field gates
for forward compatibility. Known provider-authority commands still require
the explicit opt-in.

```go
events, err := client.SubscribeDeltas(ctx)
if err != nil {
    panic(err)
}
defer events.Close()

event, err := events.RecvDelta(ctx)
switch value := event.(type) {
case cmux.WorkspaceAddedEvent:
    fmt.Println(value.Entity.Name)
case cmux.UnknownEvent:
    fmt.Println("new server event:", value.EventName())
}
```

Byte, render, and browser attachments have separate typed receive methods:

```go
render, err := client.AttachSurfaceWithOptions(
    ctx,
    surface.Surface,
    cmux.AttachSurfaceOptions{Mode: cmux.Value(cmux.AttachRender)},
)
if err != nil {
    panic(err)
}
defer render.Close()
frame, err := render.RecvRender(ctx)
```

Use `RecvByte`, `RecvRender`, `RecvBrowser`, `RecvSubscribe`, or `RecvDelta`
when a mode-specific event interface helps. `Recv` returns the common `Event`
interface. Unknown events remain available as `UnknownEvent`; they are never
dropped. `OverflowEvent` is delivered once and then ends that stream.

Generated nullable fields preserve JSON presence exactly. Optional nullable
fields use `Presence[T]`: the zero value omits the field, `Value(value)` emits
a value, and `Null[T]()` emits an explicit `null`. `IsAbsent`, `IsNull`, and
`Get` inspect the state:

```go
options := cmux.SetClientInfoOptions{
    Name: cmux.Null[string](),
    Kind: cmux.Value("agent"),
}
```

Required nullable fields use `RequiredNullable[T]`. Construct them with
`RequiredValue(value)` or `RequiredNull[T]()`. Decoding rejects a missing
required nullable field, and encoding rejects an unset zero value. Optional
non-nullable fields remain pointers; decoding rejects an explicit `null`.
Nullable inline enums and literals have generated field-specific types.
Referenced enums use their shared generated type, so
`TerminalPlacement.Lifecycle` is a `TerminalLifecycle` and accepts every
terminal lifecycle value, including `TerminalLifecycleExited`.

This presence model is a deliberate 0.4 source change. Replace `&value` in
optional nullable generated fields with `cmux.Value(value)`, and replace a
nil pointer intended as explicit null with `cmux.Null[T]()`. Pointer fields
remain unchanged when the schema marks them optional and non-nullable.

Styled rows have plain-text projections, and `ReadScrollbackTail` validates
the 65,535-row page bound:

```go
tail, err := client.ReadScrollbackTail(ctx, surfaceID, 200)
text := cmux.RenderRowsPlainText(tail.Rows)
```

The tail helper uses a zero-count probe followed by a second snapshot. Output,
eviction, or resize reflow between requests can shift the returned range; the
second result is authoritative.

`DiscoverOrCreateWorkspace` packages stable-key discovery and exactly-once
create and close mutation identities:

```go
lease, err := client.DiscoverOrCreateWorkspace(
    ctx,
    cmux.WorkspaceLeaseOptions{
        Key:              workspaceKey,
        Origin:           "my-agent",
        CreateMutationID: createMutationID,
        CloseMutationID:  closeMutationID,
    },
)
if err != nil {
    panic(err)
}
defer lease.Close(context.Background())
```

Persist the key and mutation IDs before the first call and reuse them after an
ambiguous failure. `CloseWith` accepts a replacement client after transport
loss. A matching live key is treated as caller-owned because workspace
snapshots do not expose creator origin. Closed keys are tombstoned, so a new
workspace lifecycle needs a new key and mutation IDs.

Wire IDs, revisions, frame sequences, pairing IDs, and reservation IDs use
`uint64`. Map-based raw responses use `json.Number` to prevent IEEE-754
rounding. `SendRaw` is the forward-compatible raw request entrypoint.

Errors support `errors.Is` with `ErrCommand`, `ErrConnection`, `ErrTimeout`,
`ErrProtocolMismatch`, `ErrAuthority`, `ErrDecode`, `ErrMessageTooLarge`, and
`ErrBufferFull`.
`CommandError` preserves the server message and request ID. Closing a client
or stream unblocks pending reads. Context cancellations continue to match
`ErrTimeout` and also unwrap to `context.Canceled` or
`context.DeadlineExceeded`.

The SDK enforces 4 MiB outbound messages, 16 MiB inbound messages, and 4,096
events buffered before a stream response. These values are exported as
`MaxRequestBytes`, `MaxResponseBytes`, and `MaxBufferedStreamEvents`. Set the
same fields on `Options` to apply smaller or larger per-client limits without
global state; zero selects the exported default.

Protocol metadata is available through `CommandInfo`, `EventInfo`,
`ProfileInfo`, `AllCommandMetadata`, and `AllEventMetadata`. Build-time
constants include `MuxProtocolVersion`, `SDKSchemaVersion`, and
`SDKIRSHA256`.

Generated files are deterministic:

```bash
python3 cmux-tui/bindings/codegen/generate.py --write --language go
python3 cmux-tui/bindings/codegen/generate.py --check --language go
```

Run the package checks from `cmux-tui/bindings/go`:

```bash
go test ./...
go test -race ./...
go vet ./...
```

The complete live-server consumer is `cmd/e2e`. Set `CMUX_TUI_SOCKET` and run
`go run ./cmd/e2e`.

The generated protocol-12 surface replaces incomplete legacy models.
`SetClientSizing` now takes `SetClientSizingOptions`, workspace registry
mutations return their authoritative result, and `Pane` exposes
`AsLivePane`/`AsDeadPane` for its wire union. `NewClient`, `Identify`,
`IdentifyDetailed`, `Subscribe`, `AttachSurface`, `Send`, `VtState`, and
`Close` retain concise compatibility entrypoints.
