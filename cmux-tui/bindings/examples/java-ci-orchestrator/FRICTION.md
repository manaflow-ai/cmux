# Java SDK friction

No raw, generated-model, internal, private, or generic escape API is used.

1. `terminal.wait`, `terminal.screen.read`, and `terminal.history.read` return
   `Document`. The consumer must validate `matched` and `text` at runtime.
   Operation-specific result records would move this validation into the SDK.
2. `terminal.wait` shares the client's request deadline. The client timeout must
   exceed the server-side wait timeout, which couples connection policy to one
   operation.
3. The resource API exposes no terminal exit-status primitive. This consumer
   wraps the task, prints a unique marker into PTY output, and parses status
   `0..255`.
4. `Session.createNotification` has no terminal selector even though
   `NotificationSnapshot` can contain a terminal ID. Failure notifications are
   therefore session-scoped.
5. Workspace ownership requires a custom shutdown hook and idempotent cleanup
   guard. An `AutoCloseable` workspace lease would make this lifecycle explicit.
6. `terminal.history.read` returns plain text inside an untyped document and a
   bounded integer limit. A typed pager would support large histories without
   consumer-managed limits.

The resource-handle composition and opaque identifiers are principled. The
completion marker is a protocol workaround required because exit status is not
modeled.
