import type { Principal } from "@cmux/ownership"
import { publishable, ReplicaStore } from "./store.ts"

/** The routing id of ops HostDO delivers from its mailbox (no reader socket waits for them). */
export const MAILBOX_TO = "mailbox"
/** The one op the mailbox keeps, and only on the host's Chief stream. */
export const MAILBOX_OP = "conversation.message.send"
export const chiefStream = (host: string) => `host:${host}/chief`

/**
 * The `cmux.wire/1` replica sockets of one HostDO (plans/cmux-next/object-sync/DESIGN.md
 * sections 6.3 and 7, phase 3). Two roles, both authenticated by the Worker:
 *
 * - the publisher: the host's own daemon install (the install that enrolled the host). One
 *   socket; a reconnect replaces the old one. It sends `publish {stream, snapshot | event}` for
 *   its host-homed streams, and the answers (`result`, `reject`, `request-settled`, `snapshot`)
 *   to the frames HostDO forwarded, each with the `to` it was given.
 * - a reader: a client of the host's owner. It speaks the ordinary client side of the wire
 *   (`subscribe {stream, after_seq?, pending?}`, `snapshot.request`, `op`) and gets the ordinary
 *   owner frames, plus `owner.status {stream, status, since, cached_seq}`.
 *
 * Rules:
 * - Reads never need the host: `subscribe` is answered from the replica (the events after the
 *   cursor when the tail holds them all, else the snapshot followed by the whole tail). A stream
 *   the host never published answers `owner.status` alone; its snapshot comes when the host does.
 * - Writes go to the home: an `op` is forwarded to the online host with the reader's principal
 *   and a `to`; the host's answers come back to that reader. With the host offline the op is
 *   refused at once (`reject owner_unreachable`, retryable, then `request-settled ok: false`), never
 *   queued (U5), with one exception: the Chief mailbox below. An op in flight when the publisher goes away (closed or replaced) gets the same
 *   refusal, so no reader waits forever. `snapshot.request` with pending keys goes to the online
 *   host (only the host knows its decided keys); otherwise the replica's snapshot answers it.
 * - Online means the current publisher's socket is open: the stored publisher id names it, and a
 *   socket that vanished without a close event (eviction, deploy) counts as offline. Frames from
 *   any other publisher socket (one being replaced) are ignored.
 * - `replica.purge` from the publisher (the host's off switch) forgets every stored stream and
 *   answers `replica.purged`; readers then see `owner.status` without `cached_seq`.
 * - A cursor ahead of the replica (the reader read the live host further) gets `owner.status`
 *   with the lower `cached_seq` and nothing else: the reader keeps its state, never goes back.
 * - The Chief mailbox (a450, cmux-prompts logs/iphone-chief-DESIGN.md): `conversation.message.send`
 *   on `host:<h>/chief` with the host offline is kept (one entry per idempotency key) and answered
 *   `op.queued {stream, idempotency_key, position}`. When a publisher connects, every kept op goes
 *   to it in order with `to: "mailbox"` and the sender's principal; the host's `request-settled`
 *   for it removes the entry (a retryable refusal keeps it for the next connect) and readers of
 *   the stream get `mailbox.settled {stream, idempotency_key, ok}`. The host dedupes by key, so a
 *   resend after a lost answer never makes a second message.
 * - Nothing here is committed by HostDO: the replica stores what the host published, in the
 *   host's `seq`, and forwards; the host is the only writer of these streams.
 */

export type Role = "publisher" | "reader"

/** The principal fields a replica keeps and forwards (a socket attachment holds at most 2 KB). */
export type ReplicaPrincipal = Pick<Principal, "identity" | "kind" | "user" | "team" | "install" | "grant" | "agent" | "install_kind" | "expires_at">

export const replicaPrincipal = (p: Principal): ReplicaPrincipal => ({
  identity: p.identity,
  ...(p.kind ? { kind: p.kind } : {}),
  ...(p.user ? { user: p.user } : {}),
  ...(p.team ? { team: p.team } : {}),
  ...(p.install ? { install: p.install } : {}),
  ...(p.grant ? { grant: p.grant } : {}),
  ...(p.agent ? { agent: p.agent } : {}),
  ...(p.install_kind ? { install_kind: p.install_kind } : {}),
  ...(p.expires_at !== undefined ? { expires_at: p.expires_at } : {})
})

export interface ReplicaAttachment {
  readonly role: Role
  readonly principal: ReplicaPrincipal
  /** Socket id: a reader's is the `to` of frames forwarded for it; a publisher's is the stored current one. */
  readonly id: string
  /** Streams this reader subscribed to (at most MAX_READER_STREAMS). */
  streams: Array<string>
}

/** Streams one reader socket follows; the stream name limit keeps the attachment small. */
export const MAX_READER_STREAMS = 12
const MAX_STREAM_NAME = 96
/** A subscribe may replay a 16 MiB tail: at most this many per reader socket per window. */
const SUBSCRIBE_LIMIT = 30
const SUBSCRIBE_WINDOW_MS = 10_000

/** What the object around the wire provides: its sockets and its clock. */
export interface ReplicaHost {
  readonly host: string
  /** The open publisher socket with this id. */
  publisher(id: string): WebSocket | undefined
  readers(): ReadonlyArray<WebSocket>
  reader(id: string): WebSocket | undefined
  now(): number
}

type Frame = { readonly t?: unknown } & Record<string, unknown>

const send = (ws: WebSocket | undefined, frame: unknown) => {
  if (!ws) return
  try {
    ws.send(typeof frame === "string" ? frame : JSON.stringify(frame))
  } catch {}
}

const parse = (message: string | ArrayBuffer): Frame | undefined => {
  try {
    const v = JSON.parse(typeof message === "string" ? message : new TextDecoder().decode(message)) as unknown
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Frame) : undefined
  } catch {
    return undefined
  }
}

/** Printable ASCII only, so 12 names stay far inside the 2 KB socket attachment. */
/** The host answers keys up to this length (cmux-tui host_replica.rs MAX_KEY_CHARS). */
const MAX_OP_KEY = 128
const isStream = (v: unknown): v is string => typeof v === "string" && v.length > 0 && v.length <= MAX_STREAM_NAME && /^[\x21-\x7e]+$/.test(v)
const keysOf = (v: unknown): Array<string> => (Array.isArray(v) ? v.filter((k): k is string => typeof k === "string").slice(0, 1000) : [])

export class ReplicaWire {
  /** Streams HostDO already asked the host to snapshot (cleared by the snapshot), so it asks once. */
  private readonly asked = new Set<string>()
  /** Subscribes per reader socket in the current window (in memory: a wake starts a new window). */
  private readonly subscribes = new Map<string, { at: number; n: number }>()
  /** Mailbox keys the host refused as retryable in this connection: kept for the next one. */
  private readonly retryLater = new Set<string>()

  constructor(
    private readonly store: ReplicaStore,
    private readonly env: ReplicaHost
  ) {}

  /** The current publisher socket, when it is open. */
  private publisher(): WebSocket | undefined {
    const id = this.store.presence().publisher
    return id === null ? undefined : this.env.publisher(id)
  }

  /** Online is a fact about the socket, not a stored flag: a socket can vanish without a close. */
  private presence(): { readonly status: "online" | "offline"; readonly since: number } {
    const p = this.store.presence()
    return { status: p.publisher !== null && this.env.publisher(p.publisher) ? "online" : "offline", since: p.since }
  }

  private status(stream: string, presence = this.presence()) {
    const cached = this.store.head(stream)
    return { t: "owner.status", stream, status: presence.status, since: presence.since, ...(cached === undefined ? {} : { cached_seq: cached }) }
  }

  /** Whether `id` is the current publisher (frames from a replaced one are ignored). */
  isCurrentPublisher(id: string): boolean {
    return this.store.presence().publisher === id
  }

  /** A publisher connected and replaced any older one: online now, and the heads it must resume after. */
  publisherOpened(ws: WebSocket, id: string): void {
    this.failInFlight("the host reconnected")
    this.store.setPresence(id, this.env.now())
    this.asked.clear()
    send(ws, { t: "welcome", role: "publisher", host: this.env.host, heads: this.store.heads() })
    this.broadcastPresence()
    this.retryLater.clear()
    for (const q of this.store.mailbox(this.env.now())) {
      const frame = parse(q.frame)
      if (frame) send(ws, { ...frame, to: MAILBOX_TO, principal: JSON.parse(q.principal) as unknown })
    }
  }

  private queueable(stream: string, f: Frame): boolean {
    return stream === chiefStream(this.env.host) && f.op === MAILBOX_OP
  }

  /** The host answered an op from the mailbox. */
  private onMailboxAnswer(frame: Frame): void {
    const key = typeof frame.idempotency_key === "string" ? frame.idempotency_key : undefined
    const stream = typeof frame.stream === "string" ? frame.stream : chiefStream(this.env.host)
    if (!key) return
    const id = `${stream}\n${key}`
    if (frame.t === "reject" && frame.retryable === true) this.retryLater.add(id)
    if (frame.t !== "request-settled") return
    const ok = frame.ok === true
    if (!ok && this.retryLater.has(id)) return
    this.retryLater.delete(id)
    if (!this.store.settleQueued(stream, key)) return
    for (const ws of this.subscribers(stream)) send(ws, { t: "mailbox.settled", stream, idempotency_key: key, ok })
  }

  /** A publisher socket closed; only the current one makes the host offline. */
  publisherClosed(id: string): void {
    if (!this.isCurrentPublisher(id)) return
    this.store.setPresence(null, this.env.now())
    this.failInFlight("the host went offline")
    this.broadcastPresence()
  }

  /** A reader socket closed: its ops in flight need no answer. */
  readerClosed(id: string): void {
    this.store.takeInFlight(id)
    this.subscribes.delete(id)
  }

  private takeSubscribe(id: string): boolean {
    const now = this.env.now()
    const w = this.subscribes.get(id)
    if (!w || now - w.at >= SUBSCRIBE_WINDOW_MS) {
      this.subscribes.set(id, { at: now, n: 1 })
      return true
    }
    if (w.n >= SUBSCRIBE_LIMIT) return false
    w.n += 1
    return true
  }

  readerOpened(ws: WebSocket, principal: ReplicaPrincipal): void {
    const p = this.presence()
    send(ws, { t: "welcome", role: "reader", host: this.env.host, principal: { user: principal.user, team: principal.team, install: principal.install }, owner: { status: p.status, since: p.since } })
  }

  onPublisher(message: string | ArrayBuffer): void {
    const f = parse(message)
    if (!f) return
    if (f.t === "publish") return this.publish(f)
    // The host's owner turned the replica off on the host (DESIGN.md L4): forget every stream now.
    if (f.t === "replica.purge") {
      // An op forwarded before the purge gets no answer from the host now: refuse it first.
      this.failInFlight("the host turned the replica off")
      this.store.purge()
      this.asked.clear()
      send(this.publisher(), { t: "replica.purged" })
      return this.broadcastPresence()
    }
    // An answer to a forwarded frame goes to the reader it names, without the routing field.
    if (f.to === MAILBOX_TO) {
      const { to: _to, ...frame } = f
      return this.onMailboxAnswer(frame)
    }
    if (typeof f.to === "string") {
      const { to, ...frame } = f
      if (frame.t === "request-settled" && typeof frame.idempotency_key === "string") this.store.settleInFlight(to, frame.idempotency_key)
      send(this.env.reader(to), frame)
    }
  }

  /** Every op in flight is refused (retryable) and settled not ok: its publisher is gone. */
  private failInFlight(message: string): void {
    for (const op of this.store.takeInFlight()) this.refuse(this.env.reader(op.reader), op.stream, op.key, message)
  }

  private refuse(ws: WebSocket | undefined, stream: string, key: string, message: string): void {
    send(ws, { t: "reject", stream, idempotency_key: key, code: "owner_unreachable", message, retryable: true })
    send(ws, { t: "request-settled", tx: "", idempotency_key: key, stream, sequence: 0, ok: false })
  }

  private publish(f: Frame): void {
    const stream = f.stream
    if (!isStream(stream) || !publishable(this.env.host, stream)) return send(this.publisher(), { t: "error", code: "validation.invalid", message: "not a stream this host may publish", stream })
    const snapshot = f.snapshot as Frame | undefined
    const event = f.event as Frame | undefined
    if (snapshot && typeof snapshot === "object" && snapshot.t === "snapshot" && snapshot.stream === stream && Number.isSafeInteger(snapshot.seq)) {
      const seq = snapshot.seq as number
      // Decided keys answer one reader's pending intents; the stored snapshot carries none.
      const text = JSON.stringify({ ...snapshot, decided: [] })
      if (!this.store.putSnapshot(stream, seq, text)) {
        // Not asked any more: the host's next snapshot or event for this stream is tried again.
        this.asked.delete(stream)
        return send(this.publisher(), { t: "error", code: "replica.refused", message: "snapshot too large or too many streams", stream })
      }
      this.asked.delete(stream)
      for (const ws of this.subscribers(stream)) send(ws, text)
      return
    }
    if (event && typeof event === "object" && event.t === "event" && event.stream === stream && Number.isSafeInteger(event.seq)) {
      const text = JSON.stringify(event)
      const r = this.store.appendEvent(stream, event.seq as number, text)
      if (r.kind === "applied") {
        for (const ws of this.subscribers(stream)) send(ws, text)
        if (r.compact) this.askSnapshot(stream)
      } else if (r.kind === "too_large") {
        send(this.publisher(), { t: "error", code: "replica.refused", message: "event too large; the replica waits for a snapshot", stream })
        this.askSnapshot(stream)
      } else if (r.kind !== "duplicate") this.askSnapshot(stream)
      return
    }
    send(this.publisher(), { t: "error", code: "validation.invalid", message: "publish needs a snapshot or an event of its stream", stream })
  }

  private askSnapshot(stream: string): void {
    if (this.asked.has(stream)) return
    this.asked.add(stream)
    send(this.publisher(), { t: "snapshot.request", stream, pending: [] })
  }

  onReader(ws: WebSocket, a: ReplicaAttachment, message: string | ArrayBuffer): ReplicaAttachment {
    const f = parse(message)
    if (!f) {
      send(ws, { t: "error", code: "validation.invalid", message: "frames are JSON" })
      return a
    }
    const stream = f.stream
    switch (f.t) {
      case "subscribe": {
        if (!isStream(stream) || !publishable(this.env.host, stream)) break
        if (!this.takeSubscribe(a.id)) {
          send(ws, { t: "error", code: "rate_limited", message: "too many subscribes; retry later", stream })
          return a
        }
        if (!a.streams.includes(stream) && a.streams.length >= MAX_READER_STREAMS) {
          send(ws, { t: "error", code: "validation.invalid", message: `at most ${MAX_READER_STREAMS} streams per socket`, stream })
          return a
        }
        const next = a.streams.includes(stream) ? a : { ...a, streams: [...a.streams, stream] }
        this.answerSubscribe(ws, a, stream, typeof f.after_seq === "number" ? f.after_seq : undefined, keysOf(f.pending))
        return next
      }
      case "unsubscribe":
        return isStream(stream) ? { ...a, streams: a.streams.filter((s) => s !== stream) } : a
      case "snapshot.request": {
        if (!isStream(stream) || !publishable(this.env.host, stream)) break
        const pending = keysOf(f.pending)
        if (pending.length > 0 && this.publisher()) return (this.forward(a, { t: "snapshot.request", stream, pending }), a)
        this.sendSnapshot(ws, stream)
        return a
      }
      case "op": {
        const key = typeof f.idempotency_key === "string" ? f.idempotency_key : ""
        if (!isStream(stream) || !key || key.length > MAX_OP_KEY) break
        if (!this.publisher() && this.queueable(stream, f)) {
          const { to: _to, principal: _principal, ...op } = f
          const r = this.store.enqueue(stream, key, JSON.stringify(op), JSON.stringify(a.principal), this.env.now())
          if (r.kind === "queued") send(ws, { t: "op.queued", stream, idempotency_key: key, position: r.position })
          else {
            send(ws, { t: "reject", stream, idempotency_key: key, code: r.kind === "full" ? "mailbox_full" : "validation.too_large", message: r.kind === "full" ? "the Mac's mailbox is full" : "message too large to keep", retryable: r.kind === "full" })
            send(ws, { t: "request-settled", tx: "", idempotency_key: key, stream, sequence: 0, ok: false })
          }
          return a
        }
        if (!this.publisher()) {
          this.refuse(ws, stream, key, "the host is offline")
          return a
        }
        if (!this.store.addInFlight(a.id, key, stream)) {
          send(ws, { t: "reject", stream, idempotency_key: key, code: "rate_limited", message: "too many ops in flight on this socket", retryable: true })
          send(ws, { t: "request-settled", tx: "", idempotency_key: key, stream, sequence: 0, ok: false })
          return a
        }
        this.forward(a, f)
        return a
      }
      default:
        break
    }
    send(ws, { t: "error", code: "validation.invalid", message: `unknown or incomplete frame ${String(f.t)}` })
    return a
  }

  /** A frame for the host with the reader's id and principal (the host authorizes ops by it). */
  private forward(a: ReplicaAttachment, f: Frame): void {
    send(this.publisher(), { ...f, to: a.id, principal: a.principal })
  }

  private answerSubscribe(ws: WebSocket, a: ReplicaAttachment, stream: string, after: number | undefined, pending: Array<string>): void {
    send(ws, this.status(stream))
    // Pending intents are settled by the host's decided keys, which only the live host has.
    if (pending.length > 0 && this.publisher()) return this.forward(a, { t: "snapshot.request", stream, pending })
    // The reader is ahead of the replica: owner.status (cached_seq below its cursor) says so; nothing goes back.
    const head = this.store.head(stream)
    if (after !== undefined && head !== undefined && after > head) return
    const replay = after === undefined ? undefined : this.store.eventsAfter(stream, after)
    if (replay) {
      for (const e of replay) send(ws, e.text)
      return
    }
    this.sendSnapshot(ws, stream)
  }

  /** The stored snapshot and every event after it: one consistent sequence. */
  private sendSnapshot(ws: WebSocket, stream: string): void {
    const snap = this.store.snapshot(stream)
    if (!snap) return
    send(ws, snap.text)
    for (const e of this.store.eventsAfter(stream, snap.seq) ?? []) send(ws, e.text)
  }

  private subscribers(stream: string): Array<WebSocket> {
    return this.env.readers().filter((ws) => (ws.deserializeAttachment() as ReplicaAttachment | null)?.streams.includes(stream))
  }

  private broadcastPresence(): void {
    const p = this.presence()
    for (const ws of this.env.readers()) {
      const a = ws.deserializeAttachment() as ReplicaAttachment | null
      for (const stream of a?.streams ?? []) send(ws, this.status(stream, p))
    }
  }
}
