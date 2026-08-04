import { CmuxConnectionError } from "./errors.js";
import type { Transport, Unsubscribe } from "./transport.js";
import {
  MAX_INBOUND_MESSAGE_BYTES,
  MAX_OUTBOUND_MESSAGE_BYTES,
  MAX_PENDING_BYTES,
  MAX_PENDING_MESSAGES,
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
  readonly WebSocket?: WebSocketConstructor;
  readonly maxInboundMessageBytes?: number;
  readonly maxOutboundMessageBytes?: number;
  readonly maxPendingBytes?: number;
  readonly maxPendingMessages?: number;
}

/** Browser-safe text-frame transport with bounded pre-open buffering. */
export class WebSocketTransport implements Transport {
  private readonly socket: WebSocketLike;
  private readonly pending: string[] = [];
  private readonly messages = new Set<(json: string) => void>();
  private readonly closes = new Set<() => void>();
  private readonly errors = new Set<(error: Error) => void>();
  private readonly maxInboundMessageBytes: number;
  private readonly maxOutboundMessageBytes: number;
  private readonly maxPendingBytes: number;
  private readonly maxPendingMessages: number;
  private pendingBytes = 0;
  private opened = false;
  private closed = false;

  constructor(url: string | URL, options: WebSocketTransportOptions = {}) {
    const Constructor = options.WebSocket ?? globalWebSocket();
    this.maxInboundMessageBytes = positiveLimit(
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
    this.socket = new Constructor(url, options.protocols);
    this.listen("open", () => {
      this.opened = true;
      if (options.authToken !== undefined) {
        this.socket.send(JSON.stringify({ auth: { token: options.authToken } }));
      }
      this.flush();
    });
    this.listen("message", (event) => this.receive(event));
    this.listen("error", (event) => this.fail(eventError(event)));
    this.listen("close", () => this.finish());
  }

  send(json: string): void {
    if (this.closed) throw new CmuxConnectionError("WebSocket transport is closed");
    const bytes = utf8ByteLength(json);
    if (bytes > this.maxOutboundMessageBytes) {
      throw new CmuxConnectionError(
        `outbound message exceeds ${this.maxOutboundMessageBytes} bytes`,
      );
    }
    if (this.opened && this.socket.readyState === 1) {
      this.socket.send(json);
      return;
    }
    if (
      this.pending.length >= this.maxPendingMessages
      || bytes > this.maxPendingBytes - this.pendingBytes
    ) {
      throw new CmuxConnectionError("pending WebSocket message buffer is full");
    }
    this.pending.push(json);
    this.pendingBytes += bytes;
  }

  onMessage(handler: (json: string) => void): Unsubscribe {
    this.messages.add(handler);
    return () => this.messages.delete(handler);
  }

  onClose(handler: () => void): Unsubscribe {
    this.closes.add(handler);
    if (this.closed) queueMicrotask(handler);
    return () => this.closes.delete(handler);
  }

  onError(handler: (error: Error) => void): Unsubscribe {
    this.errors.add(handler);
    return () => this.errors.delete(handler);
  }

  close(): void {
    if (!this.closed) this.socket.close();
  }

  private listen<Kind extends keyof WebSocketEventMap>(
    type: Kind,
    handler: (event: WebSocketEventMap[Kind]) => void,
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
    while (this.pending.length > 0) {
      const message = this.pending.shift()!;
      this.pendingBytes -= utf8ByteLength(message);
      this.socket.send(message);
    }
  }

  private receive(event: WebSocketEventMap["message"] | unknown): void {
    const data =
      event && typeof event === "object" && "data" in event
        ? (event as { data: unknown }).data
        : event;
    if (typeof data !== "string") {
      this.fail(new CmuxConnectionError("WebSocket server sent a non-text frame"));
      this.socket.close(1003, "text frames required");
      return;
    }
    if (utf8ByteLength(data) > this.maxInboundMessageBytes) {
      this.fail(
        new CmuxConnectionError(
          `WebSocket message exceeds ${this.maxInboundMessageBytes} bytes`,
        ),
      );
      this.socket.close(1009, "message too large");
      return;
    }
    for (const handler of this.messages) handler(data);
  }

  private fail(error: Error): void {
    for (const handler of this.errors) handler(error);
  }

  private finish(): void {
    if (this.closed) return;
    this.closed = true;
    this.pending.length = 0;
    this.pendingBytes = 0;
    for (const handler of this.closes) handler();
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

function eventError(event: unknown): Error {
  if (event instanceof Error) return event;
  if (
    event
    && typeof event === "object"
    && "error" in event
    && (event as { error?: unknown }).error instanceof Error
  ) {
    return (event as { error: Error }).error;
  }
  return new CmuxConnectionError("WebSocket transport error");
}
