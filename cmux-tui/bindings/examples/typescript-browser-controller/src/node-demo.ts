import type { WebSocketConstructor } from "cmux/browser";
import { createWebSocketBrowserController } from "./index.js";

const url = process.env.CMUX_WS_URL;
if (!url) throw new Error("CMUX_WS_URL is required");

const Constructor = globalThis.WebSocket as unknown as WebSocketConstructor | undefined;
if (!Constructor) {
  throw new Error("This demo needs a Node runtime with global WebSocket or an injected compatible constructor");
}

const controller = createWebSocketBrowserController({
  url,
  WebSocket: Constructor,
  ...(process.env.CMUX_WS_TOKEN ? { authToken: process.env.CMUX_WS_TOKEN } : {}),
  onPairingChallenge: ({ code, peer }) => {
    console.error(`Approve pairing code ${code} for ${peer} in the trusted TUI`);
  },
});

const [command = "list", surfaceText, value] = process.argv.slice(2);
const surface = surfaceText === undefined ? undefined : BigInt(surfaceText);
const json = (item: unknown) => JSON.stringify(
  item,
  (_key, field) => typeof field === "bigint" ? field.toString() : field,
  2,
);

try {
  switch (command) {
    case "list":
      console.log(json(await controller.listBrowserTabs()));
      break;
    case "navigate":
      if (surface === undefined || value === undefined) {
        throw new Error("navigate needs <surface> <url>");
      }
      await controller.navigate(surface, value);
      break;
    case "reload":
      if (surface === undefined) throw new Error("reload needs <surface>");
      await controller.reload(surface);
      break;
    case "type":
      if (surface === undefined || value === undefined) {
        throw new Error("type needs <surface> <text>");
      }
      await controller.insertText(surface, value);
      break;
    case "watch": {
      if (surface === undefined) throw new Error("watch needs <surface>");
      const abort = new AbortController();
      process.once("SIGINT", () => abort.abort());
      await controller.followBrowser(surface, {
        onState: ({ status, url: currentUrl, title, error }) => {
          console.log(json({ kind: "state", status, url: currentUrl, title, error }));
        },
        onFrame: ({ sequence, width, height, source }) => {
          console.log(json({ kind: "frame", sequence, width, height, source }));
        },
        onRecovery: ({ reason, attempt, surfacePresent }) => {
          console.error(json({ kind: "recovery", reason, attempt, surfacePresent }));
        },
      }, { signal: abort.signal });
      break;
    }
    default:
      throw new Error(`unknown command ${command}`);
  }
} finally {
  await controller.close();
}
