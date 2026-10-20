import {
  CmuxAuthenticationRejectedError,
  CmuxConnectionError,
} from "./errors.js";
import { WebSocketLifecycle } from "./internal/websocket-lifecycle.js";
import type {
  DispatchGuard,
  OnDispatched,
  Transport,
  Unsubscribe,
} from "./transport.js";
import {
  MAX_INBOUND_MESSAGE_BYTES,
  MAX_OUTBOUND_MESSAGE_BYTES,
  MAX_PENDING_BYTES,
  MAX_PENDING_MESSAGES,
  MAX_PREAUTH_MESSAGE_BYTES,
  positiveLimit,
  utf8ByteLength,
} from "./transport-limits.js";

interface WebSocketEventMap {
  open: unknown;
  message: { data: unknown };
  close: { code?: number; reason?: string };
  error: unknown;
}

/** Browser WebSocket subset, injectable for tests and compatible runtimes. */
export interface WebSocketLike {
  readonly readyState: number;
  send(data: string): void;
  close(code?: number, reason?: string): void;
  addEventListener?<Kind extends keyof WebSocketEventMap>(
    type: Kind,
    listener: (event: WebSocketEventMap[Kind]) => void,
  ): void;
  removeEventListener?<Kind extends keyof WebSocketEventMap>(
    type: Kind,
    listener: (event: WebSocketEventMap[Kind]) => void,
  ): void;
  on?(type: string, listener: (...args: unknown[]) => void): void;
}

export interface WebSocketConstructor {
  new (url: string | URL, protocols?: string | string[]): WebSocketLike;
}

export interface WebSocketTransportOptions {
  readonly protocols?: string | string[];
  readonly authToken?: string;
  /** Called while the server waits for a trusted TUI to approve this connection. */
  readonly onPairingChallenge?: (challenge: PairingChallenge) => void;
  /** Receives the credential issued after approval for reconnects. */
  readonly onPairingCredential?: (credential: string) => void;
  /** Called when a supplied token or reconnect credential is rejected. */
  readonly onAuthenticationRejected?: () => void;
  readonly WebSocket?: WebSocketConstructor;
  readonly maxInboundMessageBytes?: number;
  readonly maxOutboundMessageBytes?: number;
  readonly maxPendingBytes?: number;
  readonly maxPendingMessages?: number;
  readonly maxPreauthenticationMessageBytes?: number;
}

export interface PairingChallenge {
  readonly code: string;
  readonly peer: string;
  readonly expiresIn: number;
}

interface PendingMessage {
  readonly json: string;
  readonly bytes: number;
  readonly onDispatched: OnDispatched;
  readonly dispatchGuard: DispatchGuard | undefined;
}

/** Browser-safe text-frame transport with bounded pre-open buffering. */
export class WebSocketTransport implements Transport {
  readonly supportsDispatchGuard: true = true;
  private readonly socket: WebSocketLike;
  private readonly lifecycle: WebSocketLifecycle;
  private readonly pending: PendingMessage[] = [];
  private readonly messages = new Set<(json: string) => void>();
  private readonly maxOutboundMessageBytes: number;
  private readonly maxPendingBytes: number;
  private readonly maxPendingMessages: number;
  private pendingBytes = 0;
  private flushing = false;

  constructor(url: string | URL, options: WebSocketTransportOptions = {}) {
    const Constructor = options.WebSocket ?? globalWebSocket();
    const maxInboundMessageBytes = positiveLimit(
      "maxInboundMessageBytes",
      options.maxInboundMessageBytes,
      MAX_INBOUND_MESSAGE_BYTES,
    );
    this.maxOutboundMessageBytes = positiveLimit(
      "maxOutboundMessageBytes",
      options.maxOutboundMessageBytes,
      MAX_OUTBOUND_MESSAGE_BYTES,
    );
    this.maxPendingBytes = positiveLimit(
      "maxPendingBytes",
      options.maxPendingBytes,
      MAX_PENDING_BYTES,
    );
    this.maxPendingMessages = positiveLimit(
      "maxPendingMessages",
      options.maxPendingMessages,
      MAX_PENDING_MESSAGES,
    );
    const maxPreauthenticationMessageBytes = positiveLimit(
      "maxPreauthenticationMessageBytes",
      options.maxPreauthenticationMessageBytes,
      MAX_PREAUTH_MESSAGE_BYTES,
    );
    this.socket = new Constructor(url, options.protocols);
    this.lifecycle = new WebSocketLifecycle({
      socket: this.socket,
      authToken: options.authToken,
      maxInboundMessageBytes,
      maxPreauthenticationMessageBytes,
      createError: (message) => new CmuxConnectionError(message),
      createAuthenticationRejectedError: () =>
        new CmuxAuthenticationRejectedError("WebSocket authentication rejected"),
      flushPending: () => this.flush(),
      clearPending: () => this.clearPending(),
      deliverMessage: (json) => this.deliverMessage(json),
      onPairingChallenge: options.onPairingChallenge
        ? ({ code, peer, expiresIn }) =>
          options.onPairingChallenge?.({ code, peer, expiresIn })
        : undefined,
      onPairingCredential: options.onPairingCredential,
      onAuthenticationRejected: options.onAuthenticationRejected,
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
      throw new CmuxConnectionError(
        `outbound message exceeds ${this.maxOutboundMessageBytes} bytes`,
      );
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
      throw new CmuxConnectionError("pending WebSocket message buffer is full");
    }
    const message = { json, bytes, onDispatched, dispatchGuard };
    this.pending.push(message);
    this.pendingBytes += bytes;
    if (this.lifecycle.canDispatch) this.flush();
    return () => {
      const index = this.pending.indexOf(message);
      if (index < 0) return;
      this.pending.splice(index, 1);
      this.pendingBytes -= bytes;
    };
  }

  onMessage(handler: (json: string) => void): Unsubscribe {
    this.messages.add(handler);
    return () => this.messages.delete(handler);
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

  private listen<Kind extends keyof WebSocketEventMap>(
    type: Kind,
    handler: (event: WebSocketEventMap[Kind], ...args: unknown[]) => void,
  ): void {
    if (this.socket.addEventListener) {
      this.socket.addEventListener(type, handler);
      return;
    }
    if (this.socket.on) {
      this.socket.on(type, handler as (...args: unknown[]) => void);
      return;
    }
    throw new CmuxConnectionError("WebSocket does not support event listeners");
  }

  private flush(): void {
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
    for (const handler of this.messages) handler(json);
  }
}

function globalWebSocket(): WebSocketConstructor {
  const Constructor = (
    globalThis as typeof globalThis & { WebSocket?: WebSocketConstructor }
  ).WebSocket;
  if (!Constructor) {
    throw new CmuxConnectionError(
      "WebSocket is unavailable; inject a compatible constructor",
    );
  }
  return Constructor;
}
