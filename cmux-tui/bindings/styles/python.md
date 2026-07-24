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
- Resolve the default socket with `XDG_RUNTIME_DIR`, then `TMPDIR`, then `/tmp`, matching `spec/transports.md`, with explicit socket and `CMUX_TUI_SOCKET` overrides.
- Use separate sockets for command requests, subscribe streams, and attach streams.
- Provide `CmuxClient.request(cmd, **params) -> dict` as the raw JSON response entry point.
- Implement `subscribe()` as an iterator over event objects.
- Implement `attach_surface(surface)` as an iterator over attach event objects.
- Support protocol-v9 byte, render, and browser attach streams, including `resized` replay handling, while preserving the protocol-v5 byte fallback.
- Include typed methods for every command in `spec/inventory.json` that belongs to the selected profile, including `read_scrollback`, `wait_for`, `run`, `send_key`, `copy`, `ids`, `notify`, `list_agents`, and `report_agent`.
- Keep proposed vNext primitives out of the active protocol client until their protocol version lands.

Public API shape:

- `CmuxClient.identify() -> IdentifyResult`
- `CmuxClient.list_workspaces() -> Tree`
- Mutating commands returning `{}` should return `EmptyResult`.
- Create commands returning `{surface}` should return `SurfaceResult`.
- `read_screen()` and `vt_state()` return typed dataclasses.
- `send()` accepts `text`, `bytes_data`, or both, matching v5 write order.

The package must be importable with:

```python
from cmux import CmuxClient
```
