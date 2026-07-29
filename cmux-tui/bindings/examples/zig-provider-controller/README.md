# Zig provider controller

This Zig 0.15.2 consumer uses the public `cmux_tui` resource API to manage one
known workspace through a typed provider-scope handle. It marks the workspace
managed or unmanaged, renames or clears its name, and closes it. Every mutation
uses an idempotency key and the controller's current revision.

Build and test from the repository root:

```sh
cd cmux-tui/bindings/examples/zig-provider-controller
zig version
zig build test
zig build
```

`zig version` should print `0.15.2`. Tests use a deterministic Unix resource
server and cover the full mark, rename, and close lifecycle, exact typed
routing, revision preconditions, structured conflicts, wrong-session
snapshots, opaque identifier validation, and allocator cleanup.

Run one operation against an explicit socket and known resource IDs:

```sh
zig build run -- \
  /path/to/cmux.sock \
  provider_scope_0123456789abcdef0123456789abcdef \
  session_0123456789abcdef0123456789abcdef \
  ws_0123456789abcdef0123456789abcdef \
  10 \
  mark managed provider-mark-1
```

Rename and close use the same prefix:

```sh
zig build run -- <socket> <scope-id> <session-id> <workspace-id> 11 \
  rename production provider-rename-1
zig build run -- <socket> <scope-id> <session-id> <workspace-id> 12 \
  close provider-close-1
```

The provider scope ID comes from provider registration. The session, workspace,
and revision come from the provider's durable state or an earlier resource
snapshot. The controller copies the mutation generation and workspace name
before deinitializing SDK results.
