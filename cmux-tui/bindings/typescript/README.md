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
console.log(created.value.terminal?.id);
client.close();
```

`exact()` preserves argv. `shell()` asks the server to choose the target
platform shell. `shellExecutable()` sends `[executable, "-lc", script]`.
Mutations do not retry implicitly. Supply `idempotencyKey` and
`expectedRevision` through mutation options when the caller controls replay
or optimistic concurrency.

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
