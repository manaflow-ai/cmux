# cmux TypeScript SDK

The package root is the handwritten cmux resource API. It provides branded
opaque IDs, tagged selectors, typed handles and snapshots, mutation receipts,
structured errors, and cancellable `AsyncIterable` streams. The package has no
runtime dependencies and its Node entry requires Node 20+.

```ts
import {
  NodeClient,
  exact,
  sessionId,
  workspaceId,
} from "cmux/node";

const client = new NodeClient();
const session = client.session(
  sessionId("session_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
);
const workspace = session.workspace(
  workspaceId("ws_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
);
const created = await workspace.run({
  command: exact(["printf", "%s\n", "$HOME"]),
});
console.log(created.value.terminal.id);
client.close();
```

`exact()` preserves argv. `shell()` asks the server to choose the target
platform shell. `shellExecutable()` sends `[executable, "-lc", script]`.
Mutations do not retry implicitly. Supply `idempotencyKey` and
`expectedRevision` through mutation options when the caller controls replay
or optimistic concurrency.

Creation results form a strict `CreatedPath` discriminated union.
`workspace.run`, `pane.run`, pane and screen creation, terminal-tab creation,
and browser-tab creation return their exact path variants. Branch-dependent
workspace creation returns the union, and `kind` narrows every required handle:

```ts
const created = await session.createWorkspace({ initialContent: "empty" });
if (created.value.kind === "workspace") {
  console.log(created.value.workspace.id);
}
```

`Session.creation.resolve()` remains union-valued because a correlation key can
refer to any creation operation.

Browser frames expose `pointerFrameSeq: DecimalString | null`. A null token
means the retained pixels are renderable but cannot receive pointer input.
Pass the non-null token from the exact presented frame to `mouse` or `wheel`;
the SDK requires and validates it before sending `pointer_frame_seq`:

```ts
if (frame.pointerFrameSeq !== null) {
  await browser.mouse({
    kind: "down",
    xPx: 24,
    yPx: 40,
    button: "left",
    pointerFrameSeq: frame.pointerFrameSeq,
  });
}
```

Report a terminal's first agent state directly through its session:

```ts
const reported = await session.reportAgent({
  terminalId: created.value.terminal.id,
  state: "working",
  source: "socket",
});
```

After a dispatched `terminal.wait()` or `terminal.waitExit()` reaches its local
deadline or abort signal, the SDK confirms `request.cancel` on the same
connection before reusing it. A completion that wins the server race is drained
instead. Cleanup failure closes the connection while preserving the original
`CmuxTimeoutError` or `CmuxAbortError`.

Streams retain at most 256 unread messages and 16 MiB. Overflow ends only that
stream with a recoverable gap and sends best-effort cancellation. Pass an
`AbortSignal`, call `cancel()`, or close the client to release work.

Browser code uses the browser-safe entry:

```ts
import { Client, WebSocketTransport } from "cmux/browser";

const client = new Client({
  transport: new WebSocketTransport("wss://example.test/cmux", {
    authToken: credential,
  }),
});
```

The `cmux` and `cmux/browser` dependency graphs import no Node modules. The
`cmux/node` entry adds Unix-socket discovery and transport.

The generated protocol-v10 API and numeric mux identities are available only
from `cmux/raw`:

```ts
import { CmuxClient, COMMAND_METADATA } from "cmux/raw";
```

Package verification builds all entry points, installs the tarball into a
clean TypeScript consumer, and checks that browser imports cannot reach Node,
raw, or generated modules:

```bash
npm ci
npm run build
npm test
```
