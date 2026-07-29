# TypeScript browser controller

This package consumes only the public `cmux/browser` resource API. It lists
typed browser snapshots, sends browser controls through `Browser` handles,
follows MIME-tagged frames and state, resyncs after stream gaps, reconnects
failed clients, and supports an injected WebSocket constructor.

From this directory:

```bash
npm ci --no-audit --no-fund
npm test
```

The test command builds the linked SDK from clean source, compiles the
controller, runs deterministic resource-protocol fake-server tests, packs the
SDK, installs it into a clean temporary project, and compiles through the
published package exports.

Node runtimes with a global WebSocket can run the demo:

```bash
CMUX_WS_URL=ws://127.0.0.1:7681 CMUX_WS_TOKEN=replace-me npm run demo -- list
CMUX_WS_URL=ws://127.0.0.1:7681 CMUX_WS_TOKEN=replace-me npm run demo -- watch browser_0123456789abcdef0123456789abcdef
```

The controller imports `Client`, `WebSocketTransport`, typed IDs, resource
handles, models, errors, and transport interfaces from `cmux/browser`. It uses
no raw client, generic request method, private import, or generated protocol
model.
