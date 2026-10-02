import { pathToFileURL } from "node:url";
import { NodeClient } from "../src/node.ts";

const script = Bun.argv[2];
if (!script) throw new Error("cmux run needs a script path");

const socketPath = process.env.CMUX_TUI_SOCKET;
const session = process.env.CMUX_TUI_SESSION;
if (!socketPath && !session) throw new Error("CMUX_TUI_SOCKET or CMUX_TUI_SESSION is required");

const client = new NodeClient(socketPath ? { socketPath } : { session });
Object.defineProperty(globalThis, "cmux", {
  configurable: false,
  enumerable: true,
  value: client,
  writable: false,
});
Object.defineProperty(globalThis, "cmuxArgs", {
  configurable: false,
  enumerable: true,
  value: Bun.argv.slice(3),
  writable: false,
});

try {
  await import(pathToFileURL(script).href);
} finally {
  client.close();
}
