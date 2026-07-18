# Go Binding Style

The published client uses only the standard library.

Requirements:

- Use `context.Context` on every command method.
- Use exported Go method names and JSON tags matching wire names.
- Provide typed errors that support `errors.Is` and `errors.As`.
- Expose event and attach streams with context-aware receive methods.
- Preserve raw JSON escape hatches for forward compatibility.
- Resolve default sockets from `XDG_RUNTIME_DIR`, then `TMPDIR`, then `/tmp`; ignore empty values and apply the Darwin 103-byte fallback from the transport spec.
- Decode stable identities into strict lowercase `UUID` values while preserving numeric command handles.
- Keep legacy and canonical revision pointers separate; `TopologyCursor()` uses only the canonical revision.
- Expose `TopologySnapshot(ctx)` and `SubscribeTopology(ctx, cursor)` without requiring raw requests.
- Close a subscription and return `TopologyResnapshotRequiredEvent` on any authority or adjacency fence failure.
