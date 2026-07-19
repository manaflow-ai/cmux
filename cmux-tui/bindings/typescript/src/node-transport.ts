import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { CmuxConnectionError } from "./errors.js";
import type { Transport, Unsubscribe } from "./transport.js";

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
  private buffer = "";
  private connected = false;
  private closed = false;

  constructor(readonly socketPath: string) {
    this.socket = net.createConnection({ path: socketPath });
    this.socket.setEncoding("utf8");
    this.socket.on("connect", () => {
      this.connected = true;
      while (this.pending.length > 0) this.write(this.pending.shift()!);
    });
    this.socket.on("data", (chunk: string) => this.receive(chunk));
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

  private receive(chunk: string): void {
    this.buffer += chunk;
    for (;;) {
      const index = this.buffer.indexOf("\n");
      if (index < 0) return;
      const line = this.buffer.slice(0, index);
      this.buffer = this.buffer.slice(index + 1);
      if (line.trim() === "") continue;
      for (const handler of this.messageHandlers) handler(line);
    }
  }

  private fail(error: Error): void {
    for (const handler of this.errorHandlers) handler(error);
  }

  private finish(): void {
    if (this.closed) return;
    this.closed = true;
    this.pending.length = 0;
    for (const handler of this.closeHandlers) handler();
  }
}
