# Python Binding Style

Generate a zero-dependency synchronous Python package under `cmux-tui/bindings/python/cmux/`.

Requirements:

- Use only the Python standard library.
- Provide `CmuxClient` as the main entry point.
- Export `EventStream` and `AttachStream`.
- Use dataclasses for typed results, tree objects, and stream events.
- Method names are snake_case and map 1:1 to implemented command names.
- Preserve server error strings in `CommandError`.
- Distinguish command errors, connection errors, protocol errors, and timeouts.
- Resolve the default socket from `XDG_RUNTIME_DIR`, then `TMPDIR`, then `/tmp`; ignore empty values. On Darwin, fall back to `/tmp/cmux-tui-<uid>/<session>.sock` when the first candidate exceeds 103 filesystem bytes. Never truncate a path.
- Use separate sockets for command requests, subscribe streams, and attach streams.
- Provide `CmuxClient.request(cmd, **params) -> dict` as the raw JSON response entry point.
- Implement `subscribe()` as an iterator over event objects.
- Implement `attach_surface(surface)` as an iterator over attach event objects.
- Implement `topology_snapshot()` with UUID-backed dataclasses and `subscribe_topology()` as a dedicated iterator.
- Construct `IdentifyResult.topology_cursor` only from `canonical_topology_revision` plus both authority UUIDs.
- Return `TopologyResnapshotRequired` for immediate recovery, authority mismatch, revision gaps, and terminal slow-consumer recovery.
- Support protocol v5 attach streams and reject protocol v6 attach streams unless `resized` replay handling is implemented.
- Include consumer-side methods for `move_tab(surface, pane, index)` and `move_workspace(workspace, index)`.
- Do not implement proposed commands such as `wait-for`, `run`, `send-key`, `copy`, `ids`, `notify`, `list-agents`, or `report-agent` as active protocol methods.

Public API shape:

- `CmuxClient.identify() -> IdentifyResult`
- `CmuxClient.ping() -> PingResult` with optional additive protocol-v8 authority fields
- `CmuxClient.topology_snapshot() -> TopologySnapshot`
- `CmuxClient.subscribe_topology(cursor) -> TopologyStream | TopologyResnapshotRequired`
- `CmuxClient.list_workspaces() -> Tree`
- Mutating commands returning `{}` should return `EmptyResult`.
- Create commands returning `{surface}` should return `SurfaceResult`.
- `read_screen()` and `vt_state()` return typed dataclasses.
- `send()` accepts `text`, `bytes_data`, or both, matching v5 write order.

The package must be importable with:

```python
from cmux import CmuxClient
```
