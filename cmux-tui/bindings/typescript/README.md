# cmux TypeScript Client

The typed client library for cmux-tui frontends. It exposes every implemented
command and event in protocol v9, transport-independent request handling,
browser-safe attach streams, and Node.js Unix-socket defaults.

## Install and build

```bash
npm install cmux
npm run build
```

The package has no runtime dependencies. The Node entry requires Node 20 or
newer. Browser bundles resolve the root `browser` export condition, and the
same browser-safe surface is available explicitly from `cmux/browser`.

## Building a frontend

This example uses an existing xterm.js terminal and a cmux WebSocket endpoint.
Attach payloads are decoded to `Uint8Array`, which xterm.js accepts directly.

```ts
import { Terminal } from "@xterm/xterm";
import { CmuxClient, WebSocketTransport } from "cmux";
const terminal = new Terminal();
const transport = new WebSocketTransport("ws://127.0.0.1:9000/api/v1/ws", {
  onPairingChallenge: ({ code }) => showCode(code),
});
const client = new CmuxClient({ transport });
const info = await client.identify();
console.log(`cmux protocol ${info.protocol}`);
const tree = await client.listWorkspaces();
const workspace = tree.workspaces.find(({ active }) => active);
const screen = workspace?.screens.find(({ active }) => active);
const pane = screen?.panes.find((item) => "tabs" in item);
const surface = pane && "tabs" in pane ? pane.tabs[pane.active_tab]?.surface : undefined;
if (surface === undefined) throw new Error("No active surface");
const stream = await client.attachSurface(surface);
void (async () => {
  for await (const event of stream) {
    if (event.event === "vt-state" || event.event === "output") terminal.write(event.data);
  }
})();
await client.send(surface, { bytes: new TextEncoder().encode("ls\r") });
```

Without `authToken`, the transport requests a short-lived pairing code and
holds protocol requests until a trusted TUI approves it. The approval issues a
credential through `onPairingCredential` for reconnects. For automation, a
server started with `--ws-token` accepts that static token instead:

```ts
const transport = new WebSocketTransport("ws://127.0.0.1:7681", {
  authToken: "replace-with-a-secret",
});
```

`WebSocketTransport` uses the browser's global `WebSocket`. In Node, inject any
compatible constructor without adding a runtime dependency to this package:

```ts
import WebSocket from "ws";
import { CmuxClient, WebSocketTransport } from "cmux";

const client = new CmuxClient({
  transport: new WebSocketTransport("ws://127.0.0.1:9000/api/v1/ws", WebSocket),
});
```

## Node Unix socket

The default Node entry preserves the original zero-argument API:

```ts
import { CmuxClient } from "cmux/node";

const client = new CmuxClient();
const created = await client.newWorkspace({ name: "sdk-demo", cols: 80, rows: 24 });
await client.send(created.surface, { text: "echo hello\r" });
console.log((await client.readScreen(created.surface)).text);
await client.close();
```

`new CmuxClient()` uses `CMUX_TUI_SOCKET`, then legacy `CMUX_MUX_SOCKET`, then
the default session socket. Unix subscribe and attach streams retain dedicated
connections. An injected transport can multiplex attach streams and one
subscription on its main connection; concurrent subscriptions require a
`streamTransportFactory` because overflow events are terminal to one stream.
Each stream retains at most 256 unread events, and each encoded attach payload
is limited to 16 MiB by default. `maxBufferedEvents` and
`maxAttachEncodedChars` may lower those limits for constrained clients.

## Raw typed requests

Every command method delegates to the same generic escape hatch:

```ts
const result = await client.request({ cmd: "copy", surface: 1, mode: "screen" });
```

The `cmd` discriminator determines both required parameters and the successful
response data type. `sendRaw()` remains available for untyped forward
compatibility.

## Verification

```bash
npm ci
npm run build
npm test
CMUX_TUI_SOCKET=/path/to/session.sock npm run e2e
```
