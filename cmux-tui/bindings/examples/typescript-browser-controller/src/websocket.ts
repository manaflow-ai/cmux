import {
  CmuxClient,
  WebSocketTransport,
  type CmuxClientOptions,
  type WebSocketConstructor,
  type WebSocketTransportOptions,
} from "cmux/browser";
import {
  BrowserController,
  type BrowserControllerOptions,
} from "./controller.js";

export interface WebSocketBrowserControllerOptions
  extends Omit<
    WebSocketTransportOptions,
    "WebSocket" | "authToken" | "onPairingCredential" | "onAuthenticationRejected"
  > {
  url: string | URL;
  /** Required injection keeps this controller usable in browsers and Node runtimes. */
  WebSocket: WebSocketConstructor;
  authToken?: string;
  onPairingCredential?(credential: string): void;
  onAuthenticationRejected?(): void;
  client?: Omit<CmuxClientOptions, "transport" | "streamTransportFactory">;
  controller?: Omit<BrowserControllerOptions, "createClient">;
}

/**
 * Creates reconnectable command and attachment clients over injected WebSockets.
 *
 * Pairing credentials issued by the first connection are retained in memory and
 * reused by fresh command and attachment transports.
 */
export function createWebSocketBrowserController(
  options: WebSocketBrowserControllerOptions,
): BrowserController {
  const {
    url,
    WebSocket,
    authToken,
    onPairingCredential,
    onAuthenticationRejected,
    client,
    controller,
    ...transportOptions
  } = options;
  let credential = authToken;

  const createTransport = () => new WebSocketTransport(url, {
    ...transportOptions,
    WebSocket,
    ...(credential === undefined ? {} : { authToken: credential }),
    onPairingCredential: (issued) => {
      credential = issued;
      onPairingCredential?.(issued);
    },
    onAuthenticationRejected: () => {
      credential = undefined;
      onAuthenticationRejected?.();
    },
  });

  return new BrowserController({
    ...controller,
    createClient: () => new CmuxClient({
      ...client,
      transport: createTransport(),
      streamTransportFactory: createTransport,
    }),
  });
}
