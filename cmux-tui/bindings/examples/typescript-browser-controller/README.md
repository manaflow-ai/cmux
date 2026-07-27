# TypeScript browser controller

This package consumes only the public `cmux/browser` export. It lists browser
tabs, sends every browser control command, follows browser state and frames,
resyncs after overflow or detach, reconnects failed command clients, and
injects the WebSocket constructor.

## Build and test

From this directory:

```bash
npm install
npm test
```

`npm test` compiles the controller, runs five deterministic fake-server tests,
packs the local `cmux` SDK as an npm tarball, installs that tarball into a clean
temporary consumer, and compiles the consumer through the published package
exports.

## Run against cmux-tui

Node runtimes that expose a global WebSocket can run the standalone demo:

```bash
CMUX_WS_URL=ws://127.0.0.1:7681 CMUX_WS_TOKEN=replace-me npm run demo -- list
CMUX_WS_URL=ws://127.0.0.1:7681 CMUX_WS_TOKEN=replace-me npm run demo -- watch 42
CMUX_WS_URL=ws://127.0.0.1:7681 CMUX_WS_TOKEN=replace-me npm run demo -- navigate 42 https://example.com
CMUX_WS_URL=ws://127.0.0.1:7681 CMUX_WS_TOKEN=replace-me npm run demo -- type 42 "hello"
```

Omit `CMUX_WS_TOKEN` to request interactive pairing. The trusted TUI shows the
pairing request. The controller keeps the issued credential in memory and
reuses it for command reconnections and dedicated attachment WebSockets.

## Browser use

The controller source has no Node imports. A browser app can inject its native
constructor:

```ts
import {
  createWebSocketBrowserController,
} from "@cmux/examples-typescript-browser-controller";

const controller = createWebSocketBrowserController({
  url: "wss://cmux.example/ws",
  WebSocket: window.WebSocket,
  onPairingChallenge: ({ code }) => showPairingCode(code),
});

const [tab] = await controller.listBrowserTabs();
if (!tab) throw new Error("No browser tab");

await controller.navigate(tab.surface, "https://example.com");
await controller.insertText(tab.surface, "search text");
await controller.mouse(tab.surface, {
  kind: "down",
  x_px: 40,
  y_px: 20,
  button: "left",
  click_count: 1,
});

const abort = new AbortController();
void controller.followBrowser(tab.surface, {
  onState: ({ url, title, status, error }) => updateStatus({ url, title, status, error }),
  onFrame: ({ sequence, width, height, data }) => renderFrame({
    sequence,
    width,
    height,
    base64: data,
  }),
  onRecovery: ({ reason, surfacePresent }) => showRecovery(reason, surfacePresent),
}, { signal: abort.signal });
```

An overflow or detach triggers `list-workspaces`. The controller reattaches
when the same browser surface remains in the tree and stops when it disappears.
Idle stream read timeouts are ignored because a quiet browser remains healthy.

## Public SDK surface used

The example imports `CmuxClient`, `WebSocketTransport`, protocol types, errors,
and transport interfaces from `cmux/browser`. It calls typed client methods.
It does not call `sendRaw()`, the generic `request()` escape hatch, private
methods, generated source paths, or SDK-relative files.
