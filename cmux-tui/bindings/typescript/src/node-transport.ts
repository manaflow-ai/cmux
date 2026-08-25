import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { CmuxConnectionError } from "./errors.js";
import { NewlineFrameBuffer } from "./internal/newline-frame-buffer.js";
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
  positiveLimit,
  utf8ByteLength,
} from "./transport-limits.js";

/** Resolves the default Unix socket path for a session. */
export function defaultSocketPath(session = "main"): string {
  const base = process.env.TMPDIR || os.tmpdir();
  return path.join(base, `cmux-tui-${process.getuid?.() ?? 0}`, `${session}.sock`);
}

/** Reads the current or legacy cmux-tui socket environment variable. */
export function envSocketPath(): string | undefined {
  return process.env.CMUX_TUI_SOCKET || process.env.CMUX_MUX_SOCKET;
}

export function validateSocketPath(socketPath: string): void {
  if (socketPath.length === 0) throw new TypeError("socketPath must be a non-empty path");
}

export interface UnixSocketTransportOptions {
  maxInboundMessageBytes?: number;
  maxOutboundMessageBytes?: number;
  maxPendingBytes?: number;
  maxPendingMessages?: number;
}

interface PendingMessage {
  readonly json: string;
  readonly bytes: number;
  readonly onDispatched: OnDispatched;
  readonly dispatchGuard: DispatchGuard | undefined;
}

/** Unix-socket JSON-lines transport for Node.js. */
export class UnixSocketTransport implements Transport {
  readonly supportsDispatchGuard: true = true;
  private readonly socket: net.Socket;
  private readonly pending: PendingMessage[] = [];
  private readonly messageHandlers = new Set<(json: string) => void>();
  private readonly closeHandlers = new Set<() => void>();
  private readonly errorHandlers = new Set<(error: Error) => void>();
  private readonly maxInboundMessageBytes: number;
  private readonly maxOutboundMessageBytes: number;
  private readonly maxPendingBytes: number;
  private readonly maxPendingMessages: number;
  private readonly inbound: NewlineFrameBuffer;
  private pendingBytes = 0;
  private flushing = false;
  private connected = false;
  private closed = false;

  constructor(readonly socketPath: string, options: UnixSocketTransportOptions = {}) {
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
    this.inbound = new NewlineFrameBuffer(
      this.maxInboundMessageBytes,
      (line) => {
        for (const handler of this.messageHandlers) handler(line);
      },
      (error) => this.failAndClose(error),
    );
    this.socket = net.createConnection({ path: socketPath });
    this.socket.on("connect", () => {
      this.connected = true;
      try {
        this.flushPending();
      } catch (error) {
        this.connected = false;
        try {
          this.failAndClose(new CmuxConnectionError(
            `socket dispatch failed: ${error instanceof Error ? error.message : String(error)}`,
          ));
        } catch {
          // Error observers already ran; do not throw through EventEmitter.
        }
      }
    });
    this.socket.on("data", (chunk: Buffer) => this.receive(chunk));
    this.socket.on("error", (error) => {
      const prefix = this.connected
        ? "socket error"
        : `cannot connect to session socket ${this.socketPath}`;
      this.connected = false;
      this.fail(new CmuxConnectionError(`${prefix}: ${error.message}`));
    });
    this.socket.on("close", () => this.finish());
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
    if (this.closed) throw new CmuxConnectionError("session socket closed");
    const bytes = utf8ByteLength(json);
    if (bytes > this.maxOutboundMessageBytes) {
      throw new CmuxConnectionError(
        `outbound message exceeds ${this.maxOutboundMessageBytes} bytes`,
      );
    }
    const mustBuffer =
      !this.connected
      || this.socket.destroyed
      || this.flushing
      || this.pending.length > 0;
    if (
      mustBuffer
      && (this.pending.length >= this.maxPendingMessages
        || bytes > this.maxPendingBytes - this.pendingBytes)
    ) {
      throw new CmuxConnectionError("pending socket message buffer is full");
    }
    const message = { json, bytes, onDispatched, dispatchGuard };
    this.pending.push(message);
    this.pendingBytes += bytes;
    if (this.connected) this.flushPending();
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
    this.closeHandlers.add(handler);
    if (this.closed) queueMicrotask(handler);
    return () => this.closeHandlers.delete(handler);
  }

  onError(handler: (error: Error) => void): Unsubscribe {
    this.errorHandlers.add(handler);
    return () => this.errorHandlers.delete(handler);
  }

  close(): void {
    if (!this.closed) {
      this.inbound.dispose();
      this.socket.destroy();
    }
  }

  private write(json: string): void {
    this.socket.write(`${json}\n`, "utf8", (error) => {
      if (error) this.fail(new CmuxConnectionError(`socket write failed: ${error.message}`));
    });
  }

  private flushPending(): void {
    if (this.flushing) return;
    this.flushing = true;
    try {
      while (
        !this.closed
        && !this.socket.destroyed
        && this.connected
        && this.pending.length > 0
      ) {
        const message = this.pending.shift()!;
        this.pendingBytes -= message.bytes;
        if (message.dispatchGuard?.() === false) continue;
        message.onDispatched();
        this.write(message.json);
      }
    } finally {
      this.flushing = false;
    }
  }

  private receive(chunk: Buffer): void {
    this.inbound.push(chunk);
  }

  private fail(error: Error): void {
    invokeCallbacks(
      [...this.errorHandlers].map((handler) => () => handler(error)),
    );
  }

  private failAndClose(error: Error): void {
    invokeCallbacks([
      () => this.fail(error),
      () => this.socket.destroy(),
    ]);
  }

  private finish(): void {
    if (this.closed) return;
    this.closed = true;
    this.pending.length = 0;
    this.pendingBytes = 0;
    invokeCallbacks([
      () => this.inbound.dispose(),
      ...this.closeHandlers,
    ]);
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
