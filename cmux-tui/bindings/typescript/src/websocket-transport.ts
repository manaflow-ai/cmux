import { CmuxConnectionError } from "./errors.js";
import type { OnDispatched, Transport, Unsubscribe } from "./transport.js";
import {
  MAX_INBOUND_MESSAGE_BYTES,
  MAX_OUTBOUND_MESSAGE_BYTES,
  MAX_PENDING_BYTES,
  MAX_PENDING_MESSAGES,
  MAX_PREAUTH_MESSAGE_BYTES,
  positiveLimit,
  utf8ByteLength,
} from "./transport-limits.js";
import { parseWireJson } from "./wire-json.js";

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
}

/** Browser-safe text-frame transport with bounded pre-open buffering. */
export class WebSocketTransport implements Transport {
  private readonly socket: WebSocketLike;
  private readonly pending: PendingMessage[] = [];
  private readonly messages = new Set<(json: string) => void>();
  private readonly closes = new Set<() => void>();
  private readonly errors = new Set<(error: Error) => void>();
  private readonly maxInboundMessageBytes: number;
  private readonly maxOutboundMessageBytes: number;
  private readonly maxPendingBytes: number;
  private readonly maxPendingMessages: number;
  private readonly maxPreauthenticationMessageBytes: number;
  private readonly authToken: string | undefined;
  private readonly onPairingChallenge: ((challenge: PairingChallenge) => void) | undefined;
  private readonly onPairingCredential: ((credential: string) => void) | undefined;
  private readonly onAuthenticationRejected: (() => void) | undefined;
  private pendingBytes = 0;
  private flushing = false;
  private authenticated = false;
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
    this.maxPreauthenticationMessageBytes = positiveLimit(
      "maxPreauthenticationMessageBytes",
      options.maxPreauthenticationMessageBytes,
      MAX_PREAUTH_MESSAGE_BYTES,
    );
    this.authToken = options.authToken;
    this.onPairingChallenge = options.onPairingChallenge;
    this.onPairingCredential = options.onPairingCredential;
    this.onAuthenticationRejected = options.onAuthenticationRejected;
    this.socket = new Constructor(url, options.protocols);
    this.listen("open", () => this.open());
    this.listen("message", (event) => this.receive(event));
    this.listen("error", (event) => this.fail(eventError(event)));
    this.listen("close", (event) => this.finish(event));
  }

  send(json: string): void {
    this.enqueue(json, () => undefined);
  }

  sendCancellable(json: string, onDispatched: OnDispatched): Unsubscribe {
    return this.enqueue(json, onDispatched);
  }

  private enqueue(json: string, onDispatched: OnDispatched): Unsubscribe {
    if (this.closed) throw new CmuxConnectionError("WebSocket transport is closed");
    const bytes = utf8ByteLength(json);
    if (bytes > this.maxOutboundMessageBytes) {
      throw new CmuxConnectionError(
        `outbound message exceeds ${this.maxOutboundMessageBytes} bytes`,
      );
    }
    const mustBuffer =
      !this.authenticated
      || this.socket.readyState !== 1
      || this.flushing
      || this.pending.length > 0;
    if (
      mustBuffer
      && (this.pending.length >= this.maxPendingMessages
        || bytes > this.maxPendingBytes - this.pendingBytes)
    ) {
      throw new CmuxConnectionError("pending WebSocket message buffer is full");
    }
    const message = { json, bytes, onDispatched };
    this.pending.push(message);
    this.pendingBytes += bytes;
    if (this.authenticated && this.socket.readyState === 1) this.flush();
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

  private open(): void {
    if (this.closed) return;
    if (this.authToken === undefined) {
      this.sendPreamble(
        "pairing",
        JSON.stringify({ pair: { request: true } }),
      );
      return;
    }
    if (!this.sendPreamble(
      "authentication",
      JSON.stringify({ auth: { token: this.authToken } }),
    )) {
      return;
    }
    this.authenticated = true;
    this.flush();
  }

  private sendPreamble(kind: "pairing" | "authentication", json: string): boolean {
    try {
      this.socket.send(json);
      return true;
    } catch (error) {
      this.failAndClose(new CmuxConnectionError(
        `WebSocket ${kind} preamble failed: ${error instanceof Error ? error.message : String(error)}`,
      ));
      return false;
    }
  }

  private flush(): void {
    if (this.flushing || this.closed) return;
    this.flushing = true;
    try {
      while (
        !this.closed
        && this.authenticated
        && this.socket.readyState === 1
        && this.pending.length > 0
      ) {
        const message = this.pending.shift()!;
        this.pendingBytes -= message.bytes;
        try {
          message.onDispatched();
          this.socket.send(message.json);
        } catch (error) {
          this.failAndClose(new CmuxConnectionError(
            `WebSocket dispatch failed: ${error instanceof Error ? error.message : String(error)}`,
          ));
          return;
        }
      }
    } finally {
      this.flushing = false;
    }
  }

  private receive(event: WebSocketEventMap["message"] | unknown): void {
    const data =
      event && typeof event === "object" && "data" in event
        ? (event as { data: unknown }).data
        : event;
    if (typeof data !== "string") {
      this.failAndClose(
        new CmuxConnectionError("WebSocket server sent a non-text frame"),
        1003,
        "text frames required",
      );
      return;
    }
    const maximum = this.authenticated
      ? this.maxInboundMessageBytes
      : this.maxPreauthenticationMessageBytes;
    if (utf8ByteLength(data) > maximum) {
      this.failAndClose(
        new CmuxConnectionError(
          `WebSocket message exceeds ${maximum} bytes`,
        ),
        1009,
        "message too large",
      );
      return;
    }
    if (!this.authenticated) {
      this.receivePairing(data);
      return;
    }
    for (const handler of this.messages) handler(data);
  }

  private receivePairing(json: string): void {
    let value: unknown;
    try {
      value = parseWireJson(json);
    } catch {
      this.fail(new CmuxConnectionError("WebSocket server sent invalid pairing data"));
      return;
    }
    if (!value || typeof value !== "object") {
      this.fail(new CmuxConnectionError("WebSocket server sent invalid pairing data"));
      return;
    }
    const message = value as Record<string, unknown>;
    if (message.pairing && typeof message.pairing === "object") {
      const pairing = message.pairing as Record<string, unknown>;
      if (
        (
          typeof pairing.id === "bigint"
          || (typeof pairing.id === "number" && Number.isSafeInteger(pairing.id))
        )
        && typeof pairing.code === "string"
        && typeof pairing.peer === "string"
        && typeof pairing.expires_in === "number"
      ) {
        this.onPairingChallenge?.({
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
        invokeCallbacks([
          () => this.flush(),
          ...(this.onPairingCredential
            ? [() => this.onPairingCredential!(credential)]
            : []),
        ]);
        return;
      }
    }
    if (message.pairing_error && typeof message.pairing_error === "object") {
      const pairingError = message.pairing_error as Record<string, unknown>;
      this.fail(new CmuxConnectionError(
        typeof pairingError.message === "string"
          ? pairingError.message
          : "Pairing failed",
      ));
      return;
    }
    this.fail(new CmuxConnectionError("WebSocket server sent invalid pairing data"));
  }

  private fail(error: Error): void {
    invokeCallbacks(
      [...this.errors].map((handler) => () => handler(error)),
    );
  }

  private failAndClose(error: Error, code?: number, reason?: string): void {
    invokeCallbacks([
      () => this.fail(error),
      () => this.socket.close(code, reason),
    ]);
  }

  private finish(event?: WebSocketEventMap["close"]): void {
    if (this.closed) return;
    this.closed = true;
    this.pending.length = 0;
    this.pendingBytes = 0;
    const callbacks: Array<() => void> = [];
    if (event?.code === 1008 && event.reason === "authentication failed") {
      if (this.onAuthenticationRejected) callbacks.push(this.onAuthenticationRejected);
    }
    callbacks.push(...this.closes);
    invokeCallbacks(callbacks);
  }
}

function invokeCallbacks(callbacks: Iterable<() => void>): void {
  let callbackThrew = false;
  let callbackError: unknown;
  for (const callback of callbacks) {
    try {
      callback();
    } catch (error) {
      if (!callbackThrew) {
        callbackThrew = true;
        callbackError = error;
      }
    }
  }
  if (callbackThrew) throw callbackError;
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
