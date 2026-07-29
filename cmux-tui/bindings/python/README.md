# cmux Python SDK

The package root is the handwritten cmux resource API. It uses opaque
prefixed string IDs, tagged selectors, typed snapshots, explicit mutation
receipts, structured errors, and cancellable streams. It supports Python 3.9+
with no runtime dependencies.

```python
from cmux import Client, SessionId, WorkspaceId, exact
from cmux.options import RunOptions

with Client() as client:
    session = client.session(
        SessionId("session_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    )
    workspace = session.workspace(
        WorkspaceId("ws_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    )
    created = workspace.run(
        RunOptions(exact(["printf", "%s\n", "$HOME"]))
    )
    print(created.value.terminal.id)
```

`exact()` sends its argv without shell parsing. `shell()` asks the server to
choose the target platform shell. `shell_executable()` sends
`[executable, "-lc", script]` when the caller needs a specific shell.

Mutations never retry implicitly. Omit `idempotency_key` to receive a fresh
cryptographically random key, or supply one to control replay behavior.
Snapshots update only through explicit `refresh()`. Handles close resources
only through their explicit `close()` methods.

Streams retain at most 256 unread messages and 16 MiB. Overflow ends only that
stream with a recoverable gap and sends best-effort cancellation. Close the
stream or its client explicitly.

The asyncio facade mirrors the resource graph:

```python
import cmux.aio

async with cmux.aio.Client() as client:
    machines = await client.list_machines()
```

Canceling pending asyncio I/O closes that connection before returning
cancellation, which releases its reader and executor threads.

The generated protocol-v10 client and numeric mux identities are available
only from `cmux.raw`:

```python
from cmux.raw import CmuxClient, COMMANDS
```

An explicit socket path wins. Otherwise the client checks `CMUX_TUI_SOCKET`,
then `CMUX_MUX_SOCKET`, then resolves the named session under
`XDG_RUNTIME_DIR`, `TMPDIR`, or `/tmp`.
