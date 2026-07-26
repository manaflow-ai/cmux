import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { CmuxConnectionError } from "./errors.js";
import { RENDER_ATTACH_MAX_ENCODED_CHARS } from "./protocol/render.js";
import type { Transport, Unsubscribe } from "./transport.js";

export const UNIX_SOCKET_MESSAGE_MAX_BYTES = RENDER_ATTACH_MAX_ENCODED_CHARS;
const UNIX_SOCKET_RETAINED_BUFFER_BYTES = 64 * 1024;

/** Resolves the default Unix socket path for a session. */
export function defaultSocketPath(session = "main"): string {
  const base = process.env.TMPDIR || os.tmpdir();
  return path.join(base, `cmux-tui-${process.getuid?.() ?? 0}`, `${session}.sock`);
}

/** Reads the current or legacy cmux-tui socket environment variable. */
export function envSocketPath(): string | undefined {
  return process.env.CMUX_TUI_SOCKET || process.env.CMUX_MUX_SOCKET;
}

/** Unix-socket JSON-lines transport for Node.js. */
export class UnixSocketTransport implements Transport {
  private readonly socket: net.Socket;
  private readonly pending: string[] = [];
  private readonly messageHandlers = new Set<(json: string) => void>();
  private readonly closeHandlers = new Set<() => void>();
  private readonly errorHandlers = new Set<(error: Error) => void>();
  private buffer = Buffer.alloc(0);
  private bufferedBytes = 0;
  private connected = false;
  private closed = false;

  constructor(readonly socketPath: string) {
    this.socket = net.createConnection({ path: socketPath });
    this.socket.on("connect", () => {
      this.connected = true;
      while (this.pending.length > 0) this.write(this.pending.shift()!);
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
    if (this.connected) this.write(json);
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
    if (!this.closed) this.socket.destroy();
  }

  private write(json: string): void {
    this.socket.write(`${json}\n`, "utf8", (error) => {
      if (error) this.fail(new CmuxConnectionError(`socket write failed: ${error.message}`));
    });
  }

  private receive(chunk: Buffer): void {
    let start = 0;
    while (start < chunk.length) {
      const newline = chunk.indexOf(0x0a, start);
      const end = newline < 0 ? chunk.length : newline;
      const bytes = end - start;
      if (bytes > UNIX_SOCKET_MESSAGE_MAX_BYTES - this.bufferedBytes) {
        this.fail(new CmuxConnectionError(
          `Unix socket message exceeds ${UNIX_SOCKET_MESSAGE_MAX_BYTES} bytes`,
        ));
        this.socket.destroy();
        return;
      }
      if (bytes > 0) {
        this.ensureCapacity(this.bufferedBytes + bytes);
        chunk.copy(this.buffer, this.bufferedBytes, start, end);
        this.bufferedBytes += bytes;
      }
      if (newline < 0) return;
      const line = this.takeLine();
      start = newline + 1;
      if (line.trim() === "") continue;
      for (const handler of this.messageHandlers) handler(line);
    }
  }

  private ensureCapacity(requiredBytes: number): void {
    if (requiredBytes <= this.buffer.length) return;
    let capacity = Math.max(8 * 1024, this.buffer.length);
    while (capacity < requiredBytes) {
      capacity = Math.min(UNIX_SOCKET_MESSAGE_MAX_BYTES, capacity * 2);
    }
    const next = Buffer.allocUnsafe(capacity);
    this.buffer.copy(next, 0, 0, this.bufferedBytes);
    this.buffer = next;
  }

  private takeLine(): string {
    const line = this.buffer.toString("utf8", 0, this.bufferedBytes);
    this.bufferedBytes = 0;
    if (this.buffer.length > UNIX_SOCKET_RETAINED_BUFFER_BYTES) {
      this.buffer = Buffer.alloc(0);
    }
    return line;
  }

  private fail(error: Error): void {
    for (const handler of this.errorHandlers) handler(error);
  }

  private finish(): void {
    if (this.closed) return;
    this.closed = true;
    this.pending.length = 0;
    this.buffer = Buffer.alloc(0);
    this.bufferedBytes = 0;
    for (const handler of this.closeHandlers) handler();
  }
}
