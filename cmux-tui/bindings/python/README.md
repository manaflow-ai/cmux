# cmux Python Client

Synchronous Python client for the cmux-tui Unix-socket JSON-lines protocol.

## Install

```bash
pip install cmux
```

## Usage

```python
from cmux import CmuxClient

with CmuxClient() as client:
    info = client.identify()
    surface = client.new_workspace(name="sdk-demo", cols=80, rows=24)
    client.send(surface.surface, text="echo hello\r")
    print(client.read_screen(surface.surface).text)
```

`client.process_info(surface.surface)` returns the daemon-owned PID, exact
argv list, current cwd, and canonical PTY name.

On the trusted local socket, `client.ensure_terminal(...)` creates or
reconnects one stable terminal UUID. `wait_after_command=True` retains its
final VT state after child exit until explicit close and is creation-only.
`client.reparent_terminal(...)` moves the same identity without replacing its
PTY or child process.

## Protocol v8 topology

```python
from cmux import TopologyDelta, TopologyResnapshotRequired, TopologyStream

snapshot = client.topology_snapshot()
outcome = client.subscribe_topology(snapshot.cursor)
if isinstance(outcome, TopologyStream):
    event = next(outcome)
    if isinstance(event, TopologyDelta):
        print(event.revision)
    elif isinstance(event, TopologyResnapshotRequired):
        snapshot = client.topology_snapshot()
    outcome.close()
else:
    snapshot = client.topology_snapshot()
```

`IdentifyResult.topology_cursor` uses `canonical_topology_revision`, not the
legacy `topology_revision`. Snapshot and stream models use `uuid.UUID`.
Capability, authority, and adjacent-revision failures become typed
`TopologyResnapshotRequired` values. `ping()` returns the full optional
authority shape while remaining compatible with older servers.

`CmuxClient()` uses `CMUX_TUI_SOCKET` when set, then legacy `CMUX_MUX_SOCKET`,
then the default session socket path.

Default derivation uses `XDG_RUNTIME_DIR`, then `TMPDIR`, then `/tmp`; empty values are ignored. On Darwin, paths over 103 filesystem bytes fall back to `/tmp/cmux-tui-<uid>` and are never truncated.

## Verification

```bash
python3 -m unittest discover -s tests -v
CMUX_TUI_SOCKET=/path/to/session.sock python3 e2e.py
```
