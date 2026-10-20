import {
  Client,
  WebSocketTransport,
  type ClientOptions,
  type WebSocketConstructor,
  type WebSocketTransportOptions,
} from "cmux-sdk/browser";
import {
  BrowserController,
  type BrowserControllerOptions,
} from "./controller.js";

export interface WebSocketBrowserControllerOptions
  extends Omit<WebSocketTransportOptions, "WebSocket"> {
  readonly url: string | URL;
  /** Required injection keeps this controller usable in browsers and Node. */
  readonly WebSocket: WebSocketConstructor;
  readonly client?: Omit<ClientOptions, "transport">;
  readonly controller?: Omit<BrowserControllerOptions, "createClient">;
}

/** Create a reconnectable resource client over injected WebSockets. */
export function createWebSocketBrowserController(
  options: WebSocketBrowserControllerOptions,
): BrowserController {
  const {
    url,
    WebSocket,
    client,
    controller,
    ...transportOptions
  } = options;
  return new BrowserController({
    ...controller,
    createClient: () => new Client({
      ...client,
      transport: new WebSocketTransport(url, {
        ...transportOptions,
        WebSocket,
      }),
    }),
  });
}
