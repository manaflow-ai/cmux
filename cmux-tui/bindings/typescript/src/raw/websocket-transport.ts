import type {
  DispatchGuard,
  OnDispatched,
  Transport,
  Unsubscribe,
} from "../transport.js";
import { WebSocketLifecycle } from "../internal/websocket-lifecycle.js";
import { CmuxAuthenticationRejectedError } from "./errors.js";
import {
  MAX_INBOUND_MESSAGE_BYTES,
  MAX_OUTBOUND_MESSAGE_BYTES,
  MAX_PENDING_BYTES,
  MAX_PENDING_MESSAGES,
  MAX_PREAUTH_MESSAGE_BYTES,
  positiveLimit,
  utf8ByteLength,
} from "../transport-limits.js";

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
  maxInboundMessageBytes?: number;
  maxOutboundMessageBytes?: number;
  maxPendingBytes?: number;
  maxPendingMessages?: number;
  maxPreauthenticationMessageBytes?: number;
}

export interface PairingChallenge {
  id: bigint;
  code: string;
  peer: string;
  expiresIn: number;
}

interface PendingMessage {
  readonly json: string;
  readonly bytes: number;
  readonly onDispatched: OnDispatched;
  readonly dispatchGuard: DispatchGuard | undefined;
}

/** Sends and receives one JSON message per WebSocket text frame. */
export class WebSocketTransport implements Transport {
  readonly supportsDispatchGuard: true = true;
  private readonly socket: WebSocketLike;
  private readonly lifecycle: WebSocketLifecycle;
  private readonly pending: PendingMessage[] = [];
  private readonly messageHandlers = new Set<(json: string) => void>();
  private readonly maxOutboundMessageBytes: number;
  private readonly maxPendingBytes: number;
  private readonly maxPendingMessages: number;
  private pendingBytes = 0;
  private flushing = false;

  constructor(url: string | URL, options: WebSocketTransportOptions | WebSocketConstructor = {}) {
    const normalized: WebSocketTransportOptions = typeof options === "function"
      ? { WebSocket: options }
      : options;
    const Constructor = normalized.WebSocket ?? this.globalConstructor();
    const maxInboundMessageBytes = positiveLimit(
      "maxInboundMessageBytes",
      normalized.maxInboundMessageBytes,
      MAX_INBOUND_MESSAGE_BYTES,
    );
    this.maxOutboundMessageBytes = positiveLimit(
      "maxOutboundMessageBytes",
      normalized.maxOutboundMessageBytes,
      MAX_OUTBOUND_MESSAGE_BYTES,
    );
    this.maxPendingBytes = positiveLimit(
      "maxPendingBytes",
      normalized.maxPendingBytes,
      MAX_PENDING_BYTES,
    );
    this.maxPendingMessages = positiveLimit(
      "maxPendingMessages",
      normalized.maxPendingMessages,
      MAX_PENDING_MESSAGES,
    );
    const maxPreauthenticationMessageBytes = positiveLimit(
      "maxPreauthenticationMessageBytes",
      normalized.maxPreauthenticationMessageBytes,
      MAX_PREAUTH_MESSAGE_BYTES,
    );
    this.socket = new Constructor(url, normalized.protocols);
    this.lifecycle = new WebSocketLifecycle({
      socket: this.socket,
      authToken: normalized.authToken,
      maxInboundMessageBytes,
      maxPreauthenticationMessageBytes,
      createError: (message) => new Error(message),
      createAuthenticationRejectedError: () =>
        new CmuxAuthenticationRejectedError("WebSocket authentication rejected"),
      flushPending: () => this.flushPending(),
      clearPending: () => this.clearPending(),
      deliverMessage: (json) => this.deliverMessage(json),
      onPairingChallenge: normalized.onPairingChallenge,
      onPairingCredential: normalized.onPairingCredential,
      onAuthenticationRejected: normalized.onAuthenticationRejected,
    });
    this.listen("open", () => this.lifecycle.open());
    this.listen("message", (event) => this.lifecycle.receive(event));
    this.listen("error", (event) => this.lifecycle.receiveError(event));
    this.listen("close", (event, reason) => {
      this.lifecycle.finish(event, reason);
    });
  }

  send(json: string): void {
    this.enqueue(json, () => undefined);
  }

  sendCancellable(
    json: string,
    onDispatched: OnDispatched,
    dispatchGuard?: DispatchGuard,
  ): Unsubscribe {
    return this.enqueue(json, onDispatched, dispatchGuard);
  }

  private enqueue(
    json: string,
    onDispatched: OnDispatched,
    dispatchGuard?: DispatchGuard,
  ): Unsubscribe {
    this.lifecycle.assertOpen();
    const bytes = utf8ByteLength(json);
    if (bytes > this.maxOutboundMessageBytes) {
      throw new Error(`outbound message exceeds ${this.maxOutboundMessageBytes} bytes`);
    }
    const mustBuffer =
      !this.lifecycle.canDispatch
      || this.flushing
      || this.pending.length > 0;
    if (
      mustBuffer
      && (this.pending.length >= this.maxPendingMessages
        || bytes > this.maxPendingBytes - this.pendingBytes)
    ) {
      throw new Error("pending WebSocket message buffer is full");
    }
    const message = { json, bytes, onDispatched, dispatchGuard };
    this.pending.push(message);
    this.pendingBytes += bytes;
    if (this.lifecycle.canDispatch) this.flushPending();
    return () => {
      const index = this.pending.indexOf(message);
      if (index < 0) return;
      this.pending.splice(index, 1);
      this.pendingBytes -= bytes;
    };
  }

  onMessage(handler: (json: string) => void): Unsubscribe {
    this.messageHandlers.add(handler);
    return () => this.messageHandlers.delete(handler);
  }

  onClose(handler: () => void): Unsubscribe {
    return this.lifecycle.onClose(handler);
  }

  onError(handler: (error: Error) => void): Unsubscribe {
    return this.lifecycle.onError(handler);
  }

  close(): void {
    this.lifecycle.close();
  }

  private globalConstructor(): WebSocketConstructor {
    const Constructor = (globalThis as typeof globalThis & { WebSocket?: WebSocketConstructor }).WebSocket;
    if (!Constructor) throw new Error("WebSocket is not available; inject a compatible constructor");
    return Constructor;
  }

  private listen<K extends keyof WebSocketEventMap>(
    type: K,
    handler: (event: WebSocketEventMap[K], ...args: unknown[]) => void,
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

  private flushPending(): void {
    if (this.flushing || !this.lifecycle.canDispatch) return;
    this.flushing = true;
    try {
      while (this.lifecycle.canDispatch && this.pending.length > 0) {
        const message = this.pending.shift()!;
        this.pendingBytes -= message.bytes;
        const result = this.lifecycle.dispatch(
          message.json,
          message.onDispatched,
          message.dispatchGuard,
        );
        if (result === "vetoed") continue;
        if (result === "failed") return;
      }
    } finally {
      this.flushing = false;
    }
  }

  private clearPending(): void {
    this.pending.length = 0;
    this.pendingBytes = 0;
  }

  private deliverMessage(json: string): void {
    for (const handler of this.messageHandlers) handler(json);
  }
}
