import type { Transport, Unsubscribe } from "./transport.js";

interface WebSocketEventMap {
  open: unknown;
  message: { data: unknown };
  close: { code?: number; reason?: string };
  error: unknown;
}

/** The WebSocket subset used by `WebSocketTransport`. */
export interface WebSocketLike {
  readonly readyState: number;
  send(data: string): void;
  close(code?: number, reason?: string): void;
  addEventListener?<K extends keyof WebSocketEventMap>(
    type: K,
    listener: (event: WebSocketEventMap[K]) => void,
  ): void;
  removeEventListener?<K extends keyof WebSocketEventMap>(
    type: K,
    listener: (event: WebSocketEventMap[K]) => void,
  ): void;
  on?(type: string, listener: (...args: unknown[]) => void): void;
  off?(type: string, listener: (...args: unknown[]) => void): void;
}

/** A browser- or Node-compatible WebSocket constructor. */
export interface WebSocketConstructor {
  new (url: string | URL, protocols?: string | string[]): WebSocketLike;
}

export interface WebSocketTransportOptions {
  protocols?: string | string[];
  /** Sends the cmux-tui WebSocket authentication preamble before queued protocol requests. */
  authToken?: string;
  /** Called while the server waits for a trusted TUI to approve this connection. */
  onPairingChallenge?(challenge: PairingChallenge): void;
  /** Receives the credential issued after approval for reconnects. */
  onPairingCredential?(credential: string): void;
  /** Called when a supplied token or reconnect credential is rejected. */
  onAuthenticationRejected?(): void;
  /** Inject a compatible constructor such as the Node `ws` package. */
  WebSocket?: WebSocketConstructor;
}

export interface PairingChallenge {
  id: number;
  code: string;
  peer: string;
  expiresIn: number;
}

/** Sends and receives one JSON message per WebSocket text frame. */
export class WebSocketTransport implements Transport {
  private readonly socket: WebSocketLike;
  private readonly pending: string[] = [];
  private readonly messageHandlers = new Set<(json: string) => void>();
  private readonly closeHandlers = new Set<() => void>();
  private readonly errorHandlers = new Set<(error: Error) => void>();
  private readonly authToken: string | undefined;
  private readonly onPairingChallenge: ((challenge: PairingChallenge) => void) | undefined;
  private readonly onPairingCredential: ((credential: string) => void) | undefined;
  private readonly onAuthenticationRejected: (() => void) | undefined;
  private authenticated = false;
  private closed = false;

  constructor(url: string | URL, options: WebSocketTransportOptions | WebSocketConstructor = {}) {
    const normalized = typeof options === "function" ? { WebSocket: options } : options;
    const Constructor = normalized.WebSocket ?? this.globalConstructor();
    this.authToken = normalized.authToken;
    this.onPairingChallenge = normalized.onPairingChallenge;
    this.onPairingCredential = normalized.onPairingCredential;
    this.onAuthenticationRejected = normalized.onAuthenticationRejected;
    this.socket = new Constructor(url, normalized.protocols);
    this.listen("open", () => this.flush());
    this.listen("message", (event) => this.receive(event));
    this.listen("error", (event) => this.fail(this.eventError(event)));
    this.listen("close", (event) => this.finish(event));
  }

  send(json: string): void {
    if (this.closed) throw new Error("WebSocket transport is closed");
    if (this.socket.readyState === 1 && this.authenticated) this.socket.send(json);
    else this.pending.push(json);
  }

  onMessage(handler: (json: string) => void): Unsubscribe {
    this.messageHandlers.add(handler);
    return () => this.messageHandlers.delete(handler);
  }

  onClose(handler: () => void): Unsubscribe {
    this.closeHandlers.add(handler);
    if (this.closed) queueMicrotask(handler);
    return () => this.closeHandlers.delete(handler);
  }

  onError(handler: (error: Error) => void): Unsubscribe {
    this.errorHandlers.add(handler);
    return () => this.errorHandlers.delete(handler);
  }

  close(): void {
    if (this.closed) return;
    this.socket.close();
  }

  private globalConstructor(): WebSocketConstructor {
    const Constructor = (globalThis as typeof globalThis & { WebSocket?: WebSocketConstructor }).WebSocket;
    if (!Constructor) throw new Error("WebSocket is not available; inject a compatible constructor");
    return Constructor;
  }

  private listen<K extends keyof WebSocketEventMap>(
    type: K,
    handler: (event: WebSocketEventMap[K]) => void,
  ): void {
    if (this.socket.addEventListener) {
      this.socket.addEventListener(type, handler);
      return;
    }
    if (this.socket.on) {
      this.socket.on(type, handler as (...args: unknown[]) => void);
      return;
    }
    throw new Error("injected WebSocket does not support event listeners");
  }

  private flush(): void {
    if (this.closed) return;
    if (this.authToken !== undefined) {
      this.socket.send(JSON.stringify({ auth: { token: this.authToken } }));
      this.authenticated = true;
      this.flushPending();
    } else {
      this.socket.send(JSON.stringify({ pair: { request: true } }));
    }
  }

  private flushPending(): void {
    while (this.pending.length > 0) this.socket.send(this.pending.shift()!);
  }

  private receive(event: WebSocketEventMap["message"] | unknown): void {
    const data = event && typeof event === "object" && "data" in event ? (event as { data: unknown }).data : event;
    if (typeof data !== "string") {
      this.fail(new Error("WebSocket server sent a non-text frame"));
      return;
    }
    if (!this.authenticated) {
      this.receivePairing(data);
      return;
    }
    for (const handler of this.messageHandlers) handler(data);
  }

  private receivePairing(json: string): void {
    let value: unknown;
    try {
      value = JSON.parse(json);
    } catch {
      this.fail(new Error("WebSocket server sent invalid pairing data"));
      return;
    }
    if (!value || typeof value !== "object") {
      this.fail(new Error("WebSocket server sent invalid pairing data"));
      return;
    }
    const message = value as Record<string, unknown>;
    if (message.pairing && typeof message.pairing === "object") {
      const pairing = message.pairing as Record<string, unknown>;
      if (
        typeof pairing.id === "number"
        && typeof pairing.code === "string"
        && typeof pairing.peer === "string"
        && typeof pairing.expires_in === "number"
      ) {
        this.onPairingChallenge?.({
          id: pairing.id,
          code: pairing.code,
          peer: pairing.peer,
          expiresIn: pairing.expires_in,
        });
        return;
      }
    }
    if (message.paired && typeof message.paired === "object") {
      const credential = (message.paired as Record<string, unknown>).credential;
      if (typeof credential === "string") {
        this.authenticated = true;
        this.onPairingCredential?.(credential);
        this.flushPending();
        return;
      }
    }
    if (message.pairing_error && typeof message.pairing_error === "object") {
      const pairingError = message.pairing_error as Record<string, unknown>;
      this.fail(new Error(
        typeof pairingError.message === "string" ? pairingError.message : "Pairing failed",
      ));
      return;
    }
    this.fail(new Error("WebSocket server sent invalid pairing data"));
  }

  private eventError(event: unknown): Error {
    if (event instanceof Error) return event;
    if (event && typeof event === "object" && "error" in event && (event as { error?: unknown }).error instanceof Error) {
      return (event as { error: Error }).error;
    }
    return new Error("WebSocket transport error");
  }

  private fail(error: Error): void {
    for (const handler of this.errorHandlers) handler(error);
  }

  private finish(event?: WebSocketEventMap["close"]): void {
    if (this.closed) return;
    this.closed = true;
    this.pending.length = 0;
    if (event?.code === 1008 && event.reason === "authentication failed") {
      this.onAuthenticationRejected?.();
    }
    for (const handler of this.closeHandlers) handler();
  }
}
