# cmux Go Client

Stdlib-only Go client for the cmux-tui Unix-socket JSON-lines protocol.

Import path remains unchanged:

```go
import "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
```

## Build

```bash
cd cmux-tui/bindings/go
go build ./...
```

## Usage

```go
ctx := context.Background()
client, err := cmux.NewClient(cmux.Options{})
if err != nil {
    panic(err)
}
defer client.Close()
surface, err := client.NewWorkspace(ctx, cmux.NewWorkspaceOptions{})
if err != nil {
    panic(err)
}
text := "echo hello\r"
_ = client.Send(ctx, surface.Surface, cmux.SendOptions{Text: &text})
screen, _ := client.ReadScreen(ctx, surface.Surface)
fmt.Println(screen.Text)
```

`client.ProcessInfo(ctx, surface.Surface)` returns the daemon-owned PID, exact
argv array, current cwd, and canonical PTY name.

On the trusted local socket, `client.EnsureTerminal(...)` creates or reconnects
one stable terminal UUID. `EnsureTerminalOptions.WaitAfterCommand` retains its
final VT state after child exit until explicit close and is creation-only.
`client.ReparentTerminal(...)` moves the same identity without replacing its PTY
or child process.

## Protocol v8 topology

```go
snapshot, err := client.TopologySnapshot(ctx)
if err != nil {
    return err
}
outcome, err := client.SubscribeTopology(ctx, snapshot.Cursor())
if err != nil {
    return err
}
if outcome.ResnapshotRequired != nil {
    snapshot, err = client.TopologySnapshot(ctx)
} else {
    event, err := outcome.Subscribed.Recv(ctx)
    if err != nil {
        return err
    }
    _ = event
    defer outcome.Subscribed.Close()
}
```

`IdentifyResult.TopologyCursor()` uses `CanonicalTopologyRevision`; the legacy
`TopologyRevision` remains separately available. UUID fields use the strict
stdlib-only `UUID` value type. Subscribe response and delta fence failures
return `TopologyResnapshotRequired`. `Ping(ctx)` returns the complete optional
authority shape for compatibility with protocol-v6 and protocol-v7 servers.

`NewClient` uses `CMUX_TUI_SOCKET` when set, then legacy `CMUX_MUX_SOCKET`, then
the default session socket path.

Default derivation uses `XDG_RUNTIME_DIR`, then `TMPDIR`, then `/tmp`; empty values are ignored. On Darwin, paths over 103 filesystem bytes fall back to `/tmp/cmux-tui-<uid>` and are never truncated.

## E2E

```bash
cd cmux-tui/bindings/go
CMUX_TUI_SOCKET=/path/to/session.sock go run ./cmd/e2e
```
