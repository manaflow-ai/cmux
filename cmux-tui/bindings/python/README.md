# cmux Python SDK

The package root is the handwritten cmux resource API. It uses opaque
prefixed string IDs, tagged selectors, typed snapshots, explicit mutation
receipts, structured errors, and cancellable streams. It supports Python 3.9+
with no runtime dependencies. The distribution includes the PEP 561
`py.typed` marker so type checkers consume its inline annotations.

Install the `cmux-sdk` distribution. The Python import remains `cmux`, so it
does not overlap the `uvx cmux` CLI distribution:

```bash
python -m pip install cmux-sdk
```

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

Known catalog snapshots and results are exact dataclasses. Unknown sibling
fields are rejected unless the catalog declares an `extra` map. Terminal reads
return types such as `TerminalScreenResult`, `TerminalHistoryResult`, and
`ProcessInfoResult`; empty mutations return `MutationReceipt`.

If a mutation loses its response to a timeout or disconnect,
`MutationTransportError` exposes its operation and exact supplied or
generated key.

Synchronous calls can apply one local deadline or cancellation signal:

```python
from cmux import CancellationToken, RequestOptions

cancellation = CancellationToken()
result = client.with_request_options(
    RequestOptions(timeout=1.0, cancellation=cancellation),
    session.ping,
)
```

After a dispatched `terminal.wait` or `terminal.wait_exit` reaches its local
deadline or cancellation signal, the SDK confirms `request.cancel` on the same
connection before reusing it. A completion that wins the server race is drained
instead. Cleanup failure closes the connection while preserving the original
`TimeoutError` or `CancelledError`.

Streams retain at most 256 unread messages and 16 MiB. Overflow ends only that
stream with a recoverable gap and sends best-effort cancellation. Close the
stream or its client explicitly. `stream.next(timeout=...)` raises
`cmux.TimeoutError` without closing the stream.

Browser frames always carry `pointer_frame_seq` on the wire. The SDK exposes
it as `int | None`: `None` means the frame cannot authorize pointer input.
Mouse and wheel calls require the exact non-null token from the rendered frame
and encode it as an unsigned decimal string:

```python
from cmux import BrowserAttachFrame, BrowserId
from cmux.options import BrowserMouseOptions

browser = session.browser(
    BrowserId("browser_cccccccccccccccccccccccccccccccc")
)
with browser.attach() as frames:
    for event in frames:
        frame = event.item
        if isinstance(frame, BrowserAttachFrame):
            if frame.pointer_frame_seq is not None:
                browser.mouse(BrowserMouseOptions(
                    kind="move",
                    x_px=12.5,
                    y_px=20.0,
                    pointer_frame_seq=frame.pointer_frame_seq,
                ))
            break
```

The asyncio facade mirrors the resource graph:

```python
import cmux.aio
from cmux import RequestOptions

async with cmux.aio.Client() as client:
    machines = await client.list_machines(
        request_options=RequestOptions(timeout=1.0)
    )
```

Creation recovery uses `session.creation.resolve(correlation_key)`. Terminal
exit waits use `terminal.wait_exit(timeout_ms)` and return strict pending or
exited dataclasses with typed exit, signal, and unknown outcomes.

Destructive layout undo raises `ConfirmationRequiredError` with a typed preview
token, revision, and panes. Retry with that token, its revision, and a new
idempotency key.

All eight creation option dataclasses expose `correlation_key`. Values contain
1 to 128 UTF-8 bytes and remain stable across creation attempts.

Agent state reporting starts from the session, so a new terminal does not need
an existing agent-list result:

```python
from cmux import AgentReportOptions

reported = session.report_agent(AgentReportOptions(
    terminal_id=terminal_id,
    state="working",
    source="socket",
))
```

Each async stream owns its blocking reader worker. A waiting stream does not
occupy a request worker. Canceling a stream closes only that stream. Closing
the client releases all remaining stream, request, and reader workers.

The generated protocol-v12 client and numeric mux identities are available
only from `cmux.raw`:

```python
from cmux.raw import CmuxClient, COMMANDS
```

An explicit socket path wins. Otherwise the client checks `CMUX_TUI_SOCKET`,
then `CMUX_MUX_SOCKET`, then resolves the named session under
`XDG_RUNTIME_DIR`, `TMPDIR`, or `/tmp`.
