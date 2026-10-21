import type { HibernatingSocket } from "./hibernating-socket.ts"
import type { ObjectStorage } from "./storage.ts"

/** A Durable Object id: the name it was made from and a stable hex string. */
export interface ObjectId {
  readonly name: string
  toString(): string
  equals(other: ObjectId): boolean
}

/**
 * `ctx` of one object (DurableObjectState): its id, storage, accepted sockets and background work.
 * `blockConcurrencyWhile` work started in the constructor is awaited by the runtime before the
 * object receives its first call (the Durable Object start gate).
 */
export class ObjectState {
  private readonly sockets = new Set<HibernatingSocket>()
  private readonly starting: Array<Promise<unknown>> = []
  private readonly background = new Set<Promise<unknown>>()

  constructor(
    readonly id: ObjectId,
    readonly storage: ObjectStorage
  ) {}

  blockConcurrencyWhile<T>(fn: () => Promise<T> | T): Promise<T> {
    const p = Promise.resolve().then(fn)
    this.starting.push(p)
    return p
  }

  /** Resolves when every start gate opened (the runtime awaits it before a call). */
  async ready(): Promise<void> {
    while (this.starting.length) await this.starting.shift()
  }

  waitUntil(p: Promise<unknown>): void {
    const tracked = p.catch((e) => console.error(JSON.stringify({ msg: "waitUntil rejected", error: String(e).slice(0, 300) })))
    this.background.add(tracked)
    void tracked.finally(() => this.background.delete(tracked))
  }

  /** Resolves when background work started so far has settled (tests, shutdown). */
  async idle(): Promise<void> {
    while (this.background.size) await Promise.all([...this.background])
  }

  acceptWebSocket(ws: HibernatingSocket, _tags?: ReadonlyArray<string>): void {
    this.sockets.add(ws)
  }

  getWebSockets(tag?: string): Array<HibernatingSocket> {
    return [...this.sockets].filter((s) => s.readyState === 1 && (tag === undefined || s.tags.includes(tag)))
  }

  getTags(ws: HibernatingSocket): ReadonlyArray<string> {
    return ws.tags
  }

  /** The runtime drops a socket whose peer closed. */
  forget(ws: HibernatingSocket): void {
    this.sockets.delete(ws)
  }

  setWebSocketAutoResponse(): void {}

  getWebSocketAutoResponse(): null {
    return null
  }

  abort(reason?: string): never {
    throw new Error(`object aborted: ${reason ?? ""}`)
  }
}
