# cmux TypeScript Client

Node.js client for the cmux-tui Unix-socket JSON-lines protocol.

## Build

```bash
npm i cmux
npm install
npm run build
```

The package has no runtime dependencies. Node 20 or newer is required.

## Usage

```ts
import { CmuxClient } from "cmux";

const client = new CmuxClient();
const info = await client.identify();
const created = await client.newWorkspace({ name: "sdk-demo", cols: 80, rows: 24 });
await client.send(created.surface, { text: "echo hello\r" });
console.log((await client.readScreen(created.surface)).text);
await client.close();
```

`new CmuxClient()` uses `CMUX_TUI_SOCKET` when set, then legacy
`CMUX_MUX_SOCKET`, then the default session socket path.

## E2E

```bash
CMUX_TUI_SOCKET=/path/to/session.sock npm run e2e
```
