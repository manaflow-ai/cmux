import {
  browserId,
  type WebSocketConstructor,
} from "cmux-sdk/browser";
import { createWebSocketBrowserController } from "./index.js";

const url = process.env.CMUX_WS_URL;
if (!url) throw new Error("CMUX_WS_URL is required");

const Constructor = globalThis.WebSocket as unknown as
  | WebSocketConstructor
  | undefined;
if (!Constructor) {
  throw new Error(
    "This demo needs a Node runtime with global WebSocket or an injected constructor",
  );
}

const controller = createWebSocketBrowserController({
  url,
  WebSocket: Constructor,
  ...(process.env.CMUX_WS_TOKEN === undefined
    ? {}
    : { authToken: process.env.CMUX_WS_TOKEN }),
});

const [command = "list", idText, value] = process.argv.slice(2);
const id = idText === undefined ? undefined : browserId(idText);

try {
  switch (command) {
    case "list":
      console.log(JSON.stringify(await controller.listBrowserTabs(), null, 2));
      break;
    case "navigate":
      if (id === undefined || value === undefined) {
        throw new Error("navigate needs <browser-id> <url>");
      }
      await controller.navigate(id, value);
      break;
    case "reload":
      if (id === undefined) throw new Error("reload needs <browser-id>");
      await controller.reload(id);
      break;
    case "type":
      if (id === undefined || value === undefined) {
        throw new Error("type needs <browser-id> <text>");
      }
      await controller.insertText(id, value);
      break;
    case "watch": {
      if (id === undefined) throw new Error("watch needs <browser-id>");
      const abort = new AbortController();
      process.once("SIGINT", () => abort.abort());
      await controller.followBrowser(id, {
        onState: (state) => console.log(JSON.stringify(state)),
        onFrame: ({
          sequence,
          pointerFrameSeq,
          mimeType,
          widthPx,
          heightPx,
        }) => {
          console.log(JSON.stringify({
            kind: "frame",
            sequence,
            pointerFrameSeq,
            mimeType,
            widthPx,
            heightPx,
          }));
        },
        onRecovery: ({ reason, attempt, browserPresent }) => {
          console.error(JSON.stringify({
            kind: "recovery",
            reason,
            attempt,
            browserPresent,
          }));
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
