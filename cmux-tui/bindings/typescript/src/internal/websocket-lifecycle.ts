import type { Unsubscribe } from "../transport.js";
import { utf8ByteLength } from "../transport-limits.js";
import { parseWireJson } from "../wire-json.js";

export interface WebSocketLifecycleSocket {
  readonly readyState: number;
  send(data: string): void;
  close(code?: number, reason?: string): void;
}

export interface WebSocketLifecycleCloseEvent {
  readonly code?: number;
  readonly reason?: string;
}

export interface WebSocketLifecycleChallenge {
  readonly id: bigint;
  readonly code: string;
  readonly peer: string;
  readonly expiresIn: number;
}

export interface WebSocketLifecycleOptions {
  readonly socket: WebSocketLifecycleSocket;
  readonly authToken?: string;
  readonly maxInboundMessageBytes: number;
  readonly maxPreauthenticationMessageBytes: number;
  readonly createError: (message: string) => Error;
  readonly createAuthenticationRejectedError: () => Error;
  readonly flushPending: () => void;
  readonly clearPending: () => void;
  readonly deliverMessage: (json: string) => void;
  readonly onPairingChallenge?: (challenge: WebSocketLifecycleChallenge) => void;
  readonly onPairingCredential?: (credential: string) => void;
  readonly onAuthenticationRejected?: () => void;
}

type WebSocketHandshakeMode = "pairing" | "credential";

/** Shared authentication and terminal-state owner for public WebSocket adapters. */
export class WebSocketLifecycle {
  private readonly socket: WebSocketLifecycleSocket;
  private readonly authToken: string | undefined;
  private readonly handshakeMode: WebSocketHandshakeMode;
  private readonly maxInboundMessageBytes: number;
  private readonly maxPreauthenticationMessageBytes: number;
  private readonly createError: (message: string) => Error;
  private readonly createAuthenticationRejectedError: () => Error;
  private readonly flushPending: () => void;
  private readonly clearPending: () => void;
  private readonly deliverMessage: (json: string) => void;
  private readonly onPairingChallenge: WebSocketLifecycleOptions["onPairingChallenge"];
  private readonly onPairingCredential: WebSocketLifecycleOptions["onPairingCredential"];
  private readonly onAuthenticationRejected: WebSocketLifecycleOptions["onAuthenticationRejected"];
  private readonly errorHandlers = new Set<(error: Error) => void>();
  private readonly closeHandlers = new Set<() => void>();
  private authenticated = false;
  private closing = false;
  private closed = false;

  constructor(options: WebSocketLifecycleOptions) {
    this.socket = options.socket;
    this.authToken = options.authToken;
    this.handshakeMode = options.authToken === undefined
      ? "pairing"
      : "credential";
    this.maxInboundMessageBytes = options.maxInboundMessageBytes;
    this.maxPreauthenticationMessageBytes = options.maxPreauthenticationMessageBytes;
    this.createError = options.createError;
    this.createAuthenticationRejectedError =
      options.createAuthenticationRejectedError;
    this.flushPending = options.flushPending;
    this.clearPending = options.clearPending;
    this.deliverMessage = options.deliverMessage;
    this.onPairingChallenge = options.onPairingChallenge;
    this.onPairingCredential = options.onPairingCredential;
    this.onAuthenticationRejected = options.onAuthenticationRejected;
  }

  get terminal(): boolean {
    return this.closing || this.closed;
  }

  get canDispatch(): boolean {
    return !this.terminal && this.authenticated && this.socket.readyState === 1;
  }

  assertOpen(): void {
    if (this.terminal) throw this.createError("WebSocket transport is closed");
  }

  onError(handler: (error: Error) => void): Unsubscribe {
    this.errorHandlers.add(handler);
    return () => this.errorHandlers.delete(handler);
  }

  onClose(handler: () => void): Unsubscribe {
    this.closeHandlers.add(handler);
    if (this.closed) queueMicrotask(handler);
    return () => this.closeHandlers.delete(handler);
  }

  open(): void {
    if (this.terminal) return;
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
    this.flushPending();
  }

  receive(event: unknown): void {
    if (this.terminal) return;
    const data =
      event && typeof event === "object" && "data" in event
        ? (event as { data: unknown }).data
        : event;
    if (typeof data !== "string") {
      this.failAndClose(
        this.createError("WebSocket server sent a non-text frame"),
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
        this.createError(`WebSocket message exceeds ${maximum} bytes`),
        1009,
        "message too large",
      );
      return;
    }
    if (!this.authenticated) {
      this.receivePairing(data);
      return;
    }
    this.deliverMessage(data);
  }

  receiveError(event: unknown): void {
    if (this.terminal) return;
    void event;
    this.fail(this.createError("WebSocket transport error"));
  }

  dispatch(
    json: string,
    onDispatched: () => void = () => undefined,
    dispatchGuard: () => boolean = () => true,
  ): "sent" | "vetoed" | "failed" {
    if (!this.canDispatch) return "failed";
    try {
      if (!dispatchGuard()) return "vetoed";
      onDispatched();
      this.socket.send(json);
      return "sent";
    } catch {
      this.failAndClose(this.createError("WebSocket dispatch failed"));
      return "failed";
    }
  }

  close(): void {
    if (this.terminal) return;
    this.closing = true;
    this.socket.close();
  }

  finish(
    eventOrCode?: WebSocketLifecycleCloseEvent | number,
    rawReason?: unknown,
  ): void {
    if (this.closed) return;
    this.closing = true;
    this.closed = true;
    const event = normalizeCloseEvent(eventOrCode, rawReason);
    const callbacks: Array<() => void> = [this.clearPending];
    if (
      this.handshakeMode === "credential"
      && event?.code === 1008
      && event.reason === "authentication failed"
    ) {
      callbacks.push(() => this.fail(this.createAuthenticationRejectedError()));
      if (this.onAuthenticationRejected) callbacks.push(this.onAuthenticationRejected);
    }
    callbacks.push(...this.closeHandlers);
    invokeCallbacks(callbacks);
  }

  private sendPreamble(kind: "pairing" | "authentication", json: string): boolean {
    if (utf8ByteLength(json) > this.maxPreauthenticationMessageBytes) {
      this.failAndClose(
        this.createError(
          `WebSocket ${kind} preamble exceeds ${this.maxPreauthenticationMessageBytes} bytes`,
        ),
        1009,
        "message too large",
      );
      return false;
    }
    try {
      this.socket.send(json);
      return true;
    } catch {
      this.failAndClose(
        this.createError(`WebSocket ${kind} preamble failed`),
      );
      return false;
    }
  }

  private receivePairing(json: string): void {
    let value: unknown;
    try {
      value = parseWireJson(json);
    } catch {
      this.failInvalidPairing();
      return;
    }
    if (!value || typeof value !== "object") {
      this.failInvalidPairing();
      return;
    }
    const message = value as Record<string, unknown>;
    const challenge = pairingChallenge(message.pairing);
    if (challenge) {
      this.onPairingChallenge?.(challenge);
      return;
    }
    if (message.paired && typeof message.paired === "object") {
      const credential = (message.paired as Record<string, unknown>).credential;
      if (typeof credential === "string") {
        this.authenticated = true;
        invokeCallbacks([
          this.flushPending,
          ...(this.onPairingCredential
            ? [() => this.onPairingCredential!(credential)]
            : []),
        ]);
        return;
      }
    }
    if (message.pairing_error && typeof message.pairing_error === "object") {
      this.failAndClose(
        this.createError("WebSocket pairing failed"),
        1008,
        "pairing failed",
      );
      return;
    }
    this.failInvalidPairing();
  }

  private failInvalidPairing(): void {
    this.failAndClose(
      this.createError("WebSocket server sent invalid pairing data"),
      1002,
      "invalid pairing data",
    );
  }

  private fail(error: Error): void {
    invokeCallbacks(
      [...this.errorHandlers].map((handler) => () => handler(error)),
    );
  }

  private failAndClose(error: Error, code?: number, reason?: string): void {
    if (this.terminal) return;
    this.closing = true;
    invokeCallbacks([
      () => this.fail(error),
      () => this.socket.close(code, reason),
    ]);
  }
}

function normalizeCloseEvent(
  eventOrCode: WebSocketLifecycleCloseEvent | number | undefined,
  rawReason: unknown,
): WebSocketLifecycleCloseEvent {
  if (typeof eventOrCode === "number") {
    return {
      code: eventOrCode,
      reason: decodeCloseReason(rawReason),
    };
  }
  return eventOrCode ?? {};
}

function decodeCloseReason(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (value instanceof ArrayBuffer) {
    return new TextDecoder().decode(new Uint8Array(value));
  }
  if (ArrayBuffer.isView(value)) {
    return new TextDecoder().decode(
      new Uint8Array(value.buffer, value.byteOffset, value.byteLength),
    );
  }
  return undefined;
}

function pairingChallenge(value: unknown): WebSocketLifecycleChallenge | undefined {
  if (!value || typeof value !== "object") return undefined;
  const pairing = value as Record<string, unknown>;
  const id = pairing.id;
  if (
    !(
      typeof id === "bigint"
      || (typeof id === "number" && Number.isSafeInteger(id))
    )
    || typeof pairing.code !== "string"
    || typeof pairing.peer !== "string"
    || typeof pairing.expires_in !== "number"
  ) {
    return undefined;
  }
  return {
    id: typeof id === "bigint" ? id : BigInt(id),
    code: pairing.code,
    peer: pairing.peer,
    expiresIn: pairing.expires_in,
  };
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
