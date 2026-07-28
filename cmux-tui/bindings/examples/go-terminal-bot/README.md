# Go terminal bot

This standalone Go 1.22 module runs one command in a bot-owned cmux workspace.
It uses the public Go SDK and the Go standard library. Production code does not
send raw requests, encode protocol JSON, or import SDK internals.

The bot opens a delta subscription before reading topology, discovers the
configured workspace key or creates it with revision guards, and creates a
durable terminal running `/bin/sh`. It attaches to the terminal byte stream,
reports the agent as working, then sends the requested argv through a quoted
shell wrapper.

The wrapper prints a unique exit marker and waits for one acknowledgement
line. That pause lets the bot capture the live screen and scrollback, report
the final agent state, and post a typed notification before the local surface
disappears. The bot then acknowledges the wrapper and waits for `detached` or
`surface-exited`. Normal completion, nonzero exit, timeout, cancellation, and
setup failure all close the isolated workspace unless `--keep-workspace` is
set.

From this directory:

```bash
go run ./cmd/go-terminal-bot \
  --session main \
  --timeout 2m \
  -- cargo test ./...
```

Use an explicit socket and working directory when session discovery is not
appropriate:

```bash
go run ./cmd/go-terminal-bot \
  --socket "$CMUX_TUI_SOCKET" \
  --cwd "$PWD" \
  -- /usr/bin/make test
```

The default workspace key and terminal ID are random UUIDs. Passing
`--workspace-key` tells the bot that the matching workspace is bot-owned; it
will discover and close that workspace. Use `--keep-workspace` when the
workspace must remain available for inspection.

Exit status is the task status for values 1 through 125. Setup, transport,
timeout, and cancellation failures exit 2. Captured output is bounded to 1
MiB in memory, while live bytes still stream to stdout.

## Verification

The tests run the public SDK against a real temporary Unix socket. The fake
server drops the event and byte streams during one task, verifies reconnect,
and returns IDs and revisions above JavaScript's exact-integer range. Other
cases cover existing-workspace discovery, nonzero status, timeout,
cancellation, reporting, notification, screen and scrollback capture, and
cleanup.

```bash
go test -count=1 ./...
go test -race -count=1 ./...
go vet ./...
```

This directory is an independent Go module. Its only required module is
`github.com/manaflow-ai/cmux/cmux-tui/bindings/go`; the checked-in `replace`
selects the adjacent development SDK. A published consumer can remove that
line and require a released SDK version without changing imports or source.
