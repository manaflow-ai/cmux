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

`CmuxClient()` uses `CMUX_TUI_SOCKET` when set, then legacy `CMUX_MUX_SOCKET`,
then the default session socket path.
