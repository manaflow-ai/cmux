# TypeScript browser controller

This package consumes only the public `cmux-sdk/browser` resource API. It lists
typed browser snapshots, sends browser controls through `Browser` handles,
creates tabs with caller-owned correlation and idempotency keys, recovers an
exact created path after a lost response, follows MIME-tagged frames and state,
resyncs after stream gaps or bounded-queue overflow, cancels through
`AbortSignal`, reconnects failed clients, and supports an injected WebSocket
constructor. Direct browser creation returns `CreatedBrowserPath`, whose
browser and ancestry handles are required without optional-field checks.

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

Tests cover every browser control, direct and recovered creation, the
256-message SDK stream bound, explicit cancellation, reconnect, gap resync,
WebSocket injection, and a clean packaged consumer.

Each frame exposes its stream `sequence` and independent
`pointerFrameSeq`. Pointer controls require a non-null `pointerFrameSeq` from
the exact frame being presented; a null token keeps the image visible while
blocking clicks and scrolling.

The controller imports `Client`, `WebSocketTransport`, typed IDs, resource
handles, models, errors, and transport interfaces from `cmux-sdk/browser`. It uses
no low-level client or private import.
