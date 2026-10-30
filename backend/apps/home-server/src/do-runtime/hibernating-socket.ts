/** The transport under one accepted socket (a Bun ServerWebSocket, or a fake in tests). */
export interface SocketTransport {
  send(data: string | ArrayBuffer | Uint8Array): unknown
  close(code?: number, reason?: string): unknown
}

/** WebSocket ready states (same values as the WHATWG WebSocket). */
const OPEN = 1
const CLOSING = 2
const CLOSED = 3

/**
 * The server side of one socket as a Durable Object sees it after `ctx.acceptWebSocket`: `send`,
 * `close`, and the attachment that survives hibernation (here: lives as long as the socket,
 * copied with structuredClone as the runtime serializes it).
 */
export class HibernatingSocket {
  readyState = OPEN
  private attachment: unknown = null

  constructor(
    private readonly transport: SocketTransport,
    readonly tags: ReadonlyArray<string> = []
  ) {}

  send(data: string | ArrayBuffer | ArrayBufferView): void {
    if (this.readyState !== OPEN) throw new Error("WebSocket is not open")
    this.transport.send(typeof data === "string" || data instanceof ArrayBuffer ? data : new Uint8Array(data.buffer, data.byteOffset, data.byteLength))
  }

  close(code = 1000, reason = ""): void {
    if (this.readyState === CLOSED) return
    this.readyState = CLOSING
    // Codes 1005 and 1006 cannot be sent; Bun takes 1000 and 3000-4999.
    const sendable = code === 1000 || (code >= 3000 && code <= 4999) ? code : 1000
    try {
      this.transport.close(sendable, reason.slice(0, 120))
    } catch {}
  }

  serializeAttachment(value: unknown): void {
    this.attachment = value === undefined ? null : structuredClone(value)
  }

  deserializeAttachment(): unknown {
    return this.attachment === null ? null : structuredClone(this.attachment)
  }

  /** The runtime marks the socket closed when the peer is gone. */
  markClosed(): void {
    this.readyState = CLOSED
  }
}
