# Go terminal bot

This Go 1.22+ consumer creates an empty workspace through a `Session` handle,
runs exact argv through `Workspace.Run`, follows the returned typed created
path to a `Terminal`, waits for its durable typed exit outcome, captures typed
screen and styled history results, creates a terminal-scoped notification, and
closes its workspace. Both creates carry stable correlation keys and bounded
recovery uses `Session.ResolveCreation`.

From this directory:

```bash
go run ./cmd/go-terminal-bot -- /usr/bin/env
go test -race ./...
```

The tests use a deterministic Unix-socket resource-protocol server and assert
the full operation sequence, exact argv, distinct idempotency and correlation
keys, typed opaque IDs, terminal exit status, and styled history flattening.

The client request timeout is set one second beyond the task timeout because
`Terminal.WaitExit` is bounded by both deadlines.
