# Go terminal bot

This Go 1.22+ consumer creates an empty workspace through a `Session` handle,
runs exact argv through `Workspace.Run`, follows the returned typed created
path to a `Terminal`, waits for a completion marker, captures screen and
history documents, creates a terminal-scoped notification, and closes its
workspace.

From this directory:

```bash
go run ./cmd/go-terminal-bot -- /usr/bin/env
go test -race ./...
```

The tests use a deterministic Unix-socket resource-protocol server and assert
the full operation sequence and typed opaque IDs.

The client request timeout is set one second beyond the task timeout because
`Terminal.Wait` is bounded by both deadlines.
