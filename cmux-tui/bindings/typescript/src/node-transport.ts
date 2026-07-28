import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { Buffer } from "node:buffer";
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

/** Resolves the default Unix socket path for a session. */
export function defaultSocketPath(session = "main"): string {
  const base = process.env.TMPDIR || os.tmpdir();
  return path.join(base, `cmux-tui-${process.getuid?.() ?? 0}`, `${session}.sock`);
}

/** Reads the current or legacy cmux-tui socket environment variable. */
export function envSocketPath(): string | undefined {
  return process.env.CMUX_TUI_SOCKET || process.env.CMUX_MUX_SOCKET;
}

export interface UnixSocketTransportOptions {
  maxInboundMessageBytes?: number;
  maxOutboundMessageBytes?: number;
  maxPendingBytes?: number;
  maxPendingMessages?: number;
}

/** Unix-socket JSON-lines transport for Node.js. */
export class UnixSocketTransport implements Transport {
  private readonly socket: net.Socket;
  private readonly pending: string[] = [];
  private readonly messageHandlers = new Set<(json: string) => void>();
  private readonly closeHandlers = new Set<() => void>();
  private readonly errorHandlers = new Set<(error: Error) => void>();
  private readonly maxInboundMessageBytes: number;
  private readonly maxOutboundMessageBytes: number;
  private readonly maxPendingBytes: number;
  private readonly maxPendingMessages: number;
  private buffer = Buffer.alloc(0);
  private pendingBytes = 0;
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
    this.socket = net.createConnection({ path: socketPath });
    this.socket.on("connect", () => {
      this.connected = true;
      while (this.pending.length > 0) {
        const message = this.pending.shift()!;
        this.pendingBytes -= utf8ByteLength(message);
        this.write(message);
      }
    });
    this.socket.on("data", (chunk: Buffer) => this.receive(chunk));
    this.socket.on("error", (error) => {
      const prefix = this.connected ? "socket error" : `cannot connect to session socket ${this.socketPath}`;
      this.fail(new CmuxConnectionError(`${prefix}: ${error.message}`));
    });
    this.socket.on("close", () => this.finish());
  }

  send(json: string): void {
    if (this.closed) throw new CmuxConnectionError("session socket closed");
    const bytes = utf8ByteLength(json);
    if (bytes > this.maxOutboundMessageBytes) {
      throw new CmuxConnectionError(
        `outbound message exceeds ${this.maxOutboundMessageBytes} bytes`,
      );
    }
    if (this.connected) this.write(json);
    else {
      if (
        this.pending.length >= this.maxPendingMessages
        || bytes > this.maxPendingBytes - this.pendingBytes
      ) {
        throw new CmuxConnectionError("pending socket message buffer is full");
      }
      this.pending.push(json);
      this.pendingBytes += bytes;
    }
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
    if (!this.closed) this.socket.destroy();
  }

  private write(json: string): void {
    this.socket.write(`${json}\n`, "utf8", (error) => {
      if (error) this.fail(new CmuxConnectionError(`socket write failed: ${error.message}`));
    });
  }

  private receive(chunk: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      const index = this.buffer.indexOf(0x0a);
      if (index < 0) {
        if (this.buffer.byteLength > this.maxInboundMessageBytes) {
          this.failAndClose(
            new CmuxConnectionError(
              `inbound message exceeds ${this.maxInboundMessageBytes} bytes`,
            ),
          );
        }
        return;
      }
      if (index > this.maxInboundMessageBytes) {
        this.failAndClose(
          new CmuxConnectionError(
            `inbound message exceeds ${this.maxInboundMessageBytes} bytes`,
          ),
        );
        return;
      }
      const bytes = this.buffer.subarray(0, index);
      this.buffer = this.buffer.slice(index + 1);
      let line: string;
      try {
        line = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
      } catch {
        this.failAndClose(new CmuxConnectionError("inbound message is not valid UTF-8"));
        return;
      }
      if (line.trim() === "") continue;
      for (const handler of this.messageHandlers) handler(line);
    }
  }

  private fail(error: Error): void {
    for (const handler of this.errorHandlers) handler(error);
  }

  private failAndClose(error: Error): void {
    this.fail(error);
    this.socket.destroy();
  }

  private finish(): void {
    if (this.closed) return;
    this.closed = true;
    this.pending.length = 0;
    this.pendingBytes = 0;
    this.buffer = Buffer.alloc(0);
    for (const handler of this.closeHandlers) handler();
  }
}
