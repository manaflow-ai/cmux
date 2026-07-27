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

`NewClient` uses `CMUX_TUI_SOCKET` when set, then legacy `CMUX_MUX_SOCKET`, then
the default session socket path.

## E2E

```bash
cd cmux-tui/bindings/go
CMUX_TUI_SOCKET=/path/to/session.sock go run ./cmd/e2e
```
