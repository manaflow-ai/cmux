import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import * as net from "node:net";
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

/**
 * Validates the session component used by the default Unix socket path.
 *
 * Session names may contain legacy spaces, Unicode, punctuation, and long
 * text. They must remain one non-empty path component and cannot contain
 * separators, NUL, control characters, or Unicode line separators.
 */
export function validateSessionName(session: string): void {
  const invalid =
    session.length === 0
    || session === "."
    || session === ".."
    || [...session].some((character) => {
      const codePoint = character.codePointAt(0)!;
      return (
        character === "/"
        || character === "\\"
        || character === "\u0000"
        || codePoint <= 0x1f
        || (codePoint >= 0x7f && codePoint <= 0x9f)
        || codePoint === 0x85
        || codePoint === 0x2028
        || codePoint === 0x2029
        || (codePoint >= 0xd800 && codePoint <= 0xdfff)
      );
    });
  if (invalid) {
    throw new TypeError(
      "session name must be a non-empty path component "
      + "without separators or control characters",
    );
  }
}

/** Resolves the default Unix socket path for a session. */
export function defaultSocketPath(session = "main"): string {
  return defaultSocketPaths(session)[0];
}

/** Candidate paths in server lookup order. */
export function defaultSocketPaths(session = "main"): string[] {
  validateSessionName(session);
  const uid = process.getuid?.() ?? 0;
  const base = process.env.XDG_RUNTIME_DIR || process.env.TMPDIR || "/tmp";
  const fileName = `${session}.sock`;
  const preferred = path.join(base, `cmux-tui-${uid}`, fileName);
  // A fitting preferred path is authoritative. Do not probe a same-name
  // /tmp socket in that case, because it can belong to another runtime.
  if (unixSocketPathFits(preferred)) return [preferred];
  const candidates: string[] = [];
  // Only try the raw /tmp compatibility path after the preferred base failed.
  // When the preferred base is already /tmp this is the same path.
  if (base !== "/tmp") {
    const fallback = path.join("/tmp", `cmux-tui-${uid}`, fileName);
    if (unixSocketPathFits(fallback)) candidates.push(fallback);
  }
  if (candidates.length) return candidates;
  const digest = createHash("sha256").update(session, "utf8").digest("hex");
  const hashed = path.join(base, `cmux-tui-hashed-${uid}`, `${digest}.sock`);
  const hashedFallback = path.join("/tmp", `cmux-tui-hashed-${uid}`, `${digest}.sock`);
  if (unixSocketPathFits(hashed)) candidates.push(hashed);
  if (unixSocketPathFits(hashedFallback) && !candidates.includes(hashedFallback)) candidates.push(hashedFallback);
  return candidates;
}

function unixSocketPathFits(socketPath: string): boolean {
  // Node implements IPC paths as named pipes on Windows, not sockaddr_un.
  if (process.platform === "win32") return true;
  const capacity = process.platform === "darwin" ? 104 : 108;
  return Buffer.byteLength(socketPath) < capacity;
}

/** Reads the current or legacy cmux-tui socket environment variable. */
export function envSocketPath(): string | undefined {
  return process.env.CMUX_TUI_SOCKET || process.env.CMUX_MUX_SOCKET;
}

/**
 * Validate a Node Unix-socket path before asking net.createConnection to use it.
 * Node passes this value to sockaddr_un, whose sun_path field is bounded.
 * Linux abstract-namespace sockets use a leading NUL and are kept supported.
 */
export function validateUnixSocketPath(socketPath: string): void {
  if (socketPath.length === 0) {
    throw new TypeError("Unix socket path must be non-empty");
  }
  const abstract = socketPath.startsWith("\u0000");
  if (abstract && process.platform !== "linux") {
    throw new TypeError("abstract Unix socket paths are only supported on Linux");
  }
  const nulOffset = abstract ? 1 : 0;
  if (socketPath.slice(nulOffset).includes("\u0000")) {
    throw new TypeError("Unix socket path must not contain embedded NUL characters");
  }
  if (!unixSocketPathFits(socketPath)) {
    const capacity = process.platform === "darwin" ? 104 : 108;
    throw new RangeError(
      `Unix socket path exceeds the ${capacity - 1}-byte platform limit`,
    );
  }
}

/** Compatibility validator used by the high-level and raw Node clients. */
export function validateSocketPath(socketPath: string): void {
  if (socketPath.length === 0) {
    throw new TypeError("socketPath must be a non-empty path");
  }
  validateUnixSocketPath(socketPath);
}

export interface UnixSocketTransportOptions {
  /** Additional paths to try after ENOENT/ECONNREFUSED during initial connect. */
  fallbackSocketPaths?: readonly string[];
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
  private socket: net.Socket;
  private readonly fallbackSocketPaths: string[];
  private fallbackIndex = 0;
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
  private closing = false;
  private closed = false;

  constructor(public socketPath: string, options: UnixSocketTransportOptions = {}) {
    validateUnixSocketPath(socketPath);
    for (const fallback of options.fallbackSocketPaths ?? []) {
      validateUnixSocketPath(fallback);
    }
    this.fallbackSocketPaths = [...(options.fallbackSocketPaths ?? [])].filter((p) => p !== socketPath);
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
    this.bindSocket(this.socket);
  }

  private bindSocket(socket: net.Socket): void {
    socket.on("connect", () => {
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
    socket.on("data", (chunk: Buffer) => {
      try {
        this.receive(chunk);
      } catch (error) {
        try {
          this.failAndClose(error instanceof Error ? error : new Error(String(error)));
        } catch {
          // Error observers must not throw through the EventEmitter callback.
        }
      }
    });
    socket.on("error", (error: NodeJS.ErrnoException) => {
      // Node may deliver a queued error after a fallback socket replaced it.
      // Ignore events from that stale EventEmitter, as they do not describe
      // the active connection.
      if (socket !== this.socket) return;
      // destroy() may emit a queued error after an intentional close.
      if (this.closing || this.closed) return;
      if (!this.connected && (error.code === "ENOENT" || error.code === "ECONNREFUSED") && this.fallbackIndex < this.fallbackSocketPaths.length) {
        const next = this.fallbackSocketPaths[this.fallbackIndex++];
        socket.destroy();
        // A connection cannot carry a partial JSON line across sockets.
        this.inbound.reset();
        this.socketPath = next;
        this.socket = net.createConnection({ path: next });
        this.bindSocket(this.socket);
        return;
      }
      const prefix = this.connected
        ? "socket error"
        : `cannot connect to session socket ${this.socketPath}`;
      this.connected = false;
      this.fail(new CmuxConnectionError(`${prefix}: ${error.message}`));
    });
    socket.on("close", () => { if (socket === this.socket) this.finish(); });
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
    if (this.closing || this.closed) throw new CmuxConnectionError("session socket closed");
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
    if (!this.closing && !this.closed) {
      this.closing = true;
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
