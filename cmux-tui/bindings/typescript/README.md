# cmux TypeScript Client

The typed client library for cmux-tui frontends. Generated protocol types cover
all 83 commands and 44 event shapes in protocol v10. The runtime adds
transport-independent requests, browser-safe attach streams, and Node.js
Unix-socket defaults.

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
const tab = pane && "tabs" in pane
  ? pane.tabs.find((_item, index) => BigInt(index) === pane.active_tab)
  : undefined;
const surface = tab?.surface;
if (surface === undefined) throw new Error("No active surface");
const stream = await client.attachSurface(surface);
void (async () => {
  for await (const event of stream) {
    if (event.event === "vt-state" || event.event === "output") terminal.write(event.data);
  }
})();
await client.send(surface, { bytes: new TextEncoder().encode("ls\r") });
```

Browser surfaces have a dedicated API whose event union narrows without an
overlapping unknown-event shape:

```ts
const abort = new AbortController();
const browser = await client.attachBrowserSurface(surface, {
  signal: abort.signal,
  cols: 120,
  rows: 40,
});
for await (const event of browser) {
  switch (event.event) {
    case "browser-state":
      updateAddressBar(event.url, event.title, event.status);
      if (event.frame) drawBase64Frame(event.frame);
      break;
    case "frame":
      drawBase64Frame(event);
      break;
    case "overflow":
      await resyncBrowserSurface(surface);
      break;
    case "detached":
      return;
    case "unknown":
      console.log("New browser event", event.wireEvent, event.raw);
      break;
  }
}
```

`BrowserAttachEvent` contains only the six documented browser attachment
events, so a switch over that type narrows each payload. `BrowserStreamEvent`
adds `UnknownBrowserAttachEvent`, whose distinct `event: "unknown"`
discriminant exposes the original name as `wireEvent` and the complete decoded
object as `raw`. Large integers in `raw` remain exact `bigint` values.
`attachSurface()` retains its existing event behavior.

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
Transports also bound inbound messages, outbound messages, and frames queued
before authentication.

`timeoutMs` controls command acknowledgements only. Quiet event streams wait
indefinitely by default. A client-wide `streamIdleTimeoutMs`, a per-stream
`idleTimeoutMs`, or `stream.next(timeoutMs)` opts into a finite idle timeout:

```ts
const client = new CmuxClient({
  transport,
  timeoutMs: 10_000,
  streamIdleTimeoutMs: 60_000,
});
const events = await client.subscribe({ idleTimeoutMs: 30_000 });
const event = await events.next({ timeoutMs: 5_000, signal: readAbort.signal });
```

`signal` on `subscribe()`, `attachSurface()`, or `attachBrowserSurface()`
cancels both the pending open and the resulting stream lifetime. A signal
passed to `next({ signal })` cancels only that read and leaves the stream open.
Cancellation rejects with `CmuxAbortError`. Abort listeners and timeout timers
are removed on delivery, timeout, cancellation, close, and transport failure.

## Typed requests and exact integers

Every command method delegates to the same generic escape hatch:

```ts
const result = await client.request("copy", { surface: 1n, mode: "screen" });
```

The `cmd` discriminator determines both required parameters and the successful
response data type. IDs, revisions, timestamps, frame sequences, and
reservation IDs are `bigint`. The dependency-free wire codec preserves the
full unsigned 64-bit range as JSON numbers and rejects unsafe JavaScript
integer values. Missing optional fields remain distinct from explicit `null`.

Typed calls inspect `COMMAND_METADATA[command].fields`. When a provided field
requires a newer protocol or capability, the client identifies lazily and
rejects before writing the command. `undefined` fields are omitted; explicit
`null` fields are present and receive the same compatibility check. This
covers versioned options such as `send.paste` and capability-scoped options
such as `subscribe.surface` and initial attach sizing.

## Command authority

`CmuxClient` from `cmux/browser` is transport-neutral and enables `control`
plus `frontend` commands by default. The Node Unix client from `cmux` also
enables `local-admin`. Known commands outside the enabled set reject with
`CmuxAuthorityError` before the client writes to its transport.

Provider-owned workspace commands always require an explicit opt-in:

```ts
const provider = new CmuxClient({
  transport,
  enableProviderAuthority: true,
});
await provider.markWorkspacesProviderManaged({ authority: providerSecret });
```

Use `authorities` to narrow a client to generated `CmuxAuthority` profiles.
Inherited profiles from `PROFILES` are included automatically. For example,
`authorities: ["frontend"]` also enables its inherited `control` authority.
`client.authorities` exposes the expanded immutable list.

`COMMAND_METADATA`, `EVENT_METADATA`, `PROTOCOL`, and `PROFILES` expose
generated version, capability, authority, and stream metadata. Known emitted
events form a discriminated union, serialized-only events stay outside that
union, and unknown future events remain available through the fallback event
shape. `sendRaw()` deliberately skips typed command and field version or
capability checks for forward compatibility, while retaining authority and
transport limits.

## Verification

```bash
npm ci
npm run check:generated
npm run build
npm test
CMUX_TUI_SOCKET=/path/to/session.sock npm run e2e
```

`npm test` also packs the SDK, installs it into a clean DOM-only TypeScript
consumer, compiles the browser attachment and cancellation APIs, and checks
that the `cmux/browser` dependency graph imports no Node modules.
