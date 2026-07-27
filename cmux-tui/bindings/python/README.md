# cmux Python SDK

Synchronous Python 3.9+ client for the cmux TUI protocol. Runtime dependencies:
Python's standard library only.

## Install

```bash
pip install cmux
```

## Control a terminal

```python
from cmux import CmuxClient

with CmuxClient() as client:
    info = client.identify()
    created = client.new_workspace(name="sdk-demo", cols=80, rows=24)
    client.send(created.surface, text="echo hello\r")
    print(client.read_screen(created.surface).text)
```

Every protocol-v10 command has one typed `snake_case` method. Request objects,
results, tree objects, and events are generated dataclasses. Protocol versions,
capabilities, and authority groups are available through `COMMANDS`, `EVENTS`,
and `MUX_PROTOCOL`.

## Stream output, renders, browser frames, and tree deltas

```python
with CmuxClient() as client:
    surface = client.new_workspace(name="streams").surface

    with client.attach_bytes(surface) as attachment:
        for chunk in attachment.iter_bytes():
            consume(chunk)

    with client.attach_render(surface) as renders:
        for event in renders:
            update_grid(event)

    with client.attach_browser(browser_surface) as browser:
        for event in browser:
            update_browser(event)

    with client.subscribe_deltas() as events:
        for event in events:
            apply_tree_event(event)
```

Unknown future event names decode as `UnknownEvent` with their original `raw`
mapping.

## Missing versus null

Generated request fields use `MISSING` when a field is absent. Passing `None`
encodes JSON `null` only where the protocol marks that field nullable.

```python
client.set_client_info()           # {}
client.set_client_info(name=None)  # {"name": null}
```

`CmuxClient.request(command, **params)` is the raw response-envelope API and
also preserves explicit `None`.

## Topology and scrollback helpers

`find_surface` joins a surface ID to its generated workspace, screen, live
pane, and tab models. `active_live_pty` returns that same context only when the
entire active path points to a non-dead PTY.

```python
from cmux import active_live_pty, find_surface

tree = client.list_workspaces()
context = find_surface(tree, agent.surface)
active = active_live_pty(tree)
if context is not None:
    print(context.workspace.name, context.screen.name, context.tab.title)
```

`render_row_text` removes render styling while preserving the text and spacing
of each run. `read_scrollback_tail` validates the protocol's 0 through 65,535
row count and returns the newest rows available.

```python
from cmux import render_row_text

tail = client.read_scrollback_tail(surface, 40)
text = "\n".join(render_row_text(row) for row in tail.rows)
```

Tail lookup is best effort. The helper probes one snapshot to learn the total
row count and may read a second snapshot at the calculated start, so concurrent
terminal output can cause rows to be skipped or repeated.

## Authority boundary

Clients allow control, frontend, and local-admin commands by default.
Provider-authority commands raise `AuthorityError` before any socket write,
including known commands passed to `request`.

External providers must opt in explicitly:

```python
from cmux import CmuxClient

provider_client = CmuxClient(allow_provider_authority=True)
```

## Socket resolution

An explicit `socket_path` wins. Otherwise the client checks
`CMUX_TUI_SOCKET`, then the legacy `CMUX_MUX_SOCKET`, then resolves the session
under `XDG_RUNTIME_DIR`, `TMPDIR`, or `/tmp`.
