import { DurableObject } from "cloudflare:workers"
import type { Env } from "./env.ts"
import { TaggedQueue, COALESCE_FLUSH_BYTES } from "./relay-coalesce.ts"
import { checkFrame, RELAY_FRAME_HEADER_LEN, RELAY_FRAME_MAX, splitTagged, withPeer } from "./relay-frame.ts"
import { APP_PING, APP_PONG, uuidToBytes } from "./team-hub.ts"

/**
 * The link's WebSocket relay (PROTOCOL.md "WebSocket relay", API 0.17.0): the last way a WireGuard link reaches
 * its peer when neither plain UDP nor a TURN server gets through, as on a network that lets only cmux's own
 * domains, or only HTTP inside TLS, out. One object per link session, named by the owner key, build space and
 * session id (`relayRoomName`), never a client value. The Worker admits a socket only for a device the owner's
 * hub bound to that session at its first signal (TeamHub `relayPeer`), and tells this object the device and its
 * peer in headers no client can set (the object is reached only through the Worker).
 *
 * It carries relay frames (`relay-frame.ts`) of kind `datagrams` and `tagged-datagrams` (hop/1 DATA records, RFD
 * 0142) from one party's socket to the other's, with the frame's peer id set to the sender's device id, and reads
 * nothing else: the datagrams are WireGuard ciphertext, end to end between the phone and the Mac. Tagged records
 * are coalesced per target socket within one event-loop turn and a class-1 record is dropped when a newer one of
 * the same key is queued with it (`relay-coalesce.ts`). Workers' WebSocket has no `bufferedAmount` or drain event
 * (developers.cloudflare.com/workers/runtime-apis/websockets, checked 2026-11-24), so the object cannot see a
 * send backlog: it coalesces only what it already holds. Hibernating WebSockets, tagged by device id, so a quiet session (a
 * link that settled on a direct path) costs nothing; the application ping is answered without waking it. It keeps
 * no storage.
 */
export const relayRoomName = (ownerKey: string, space: string, sessionId: string) =>
  `${space ? `${space}|` : ""}relay:${ownerKey}:${sessionId}`

/** Selected when a client offers it (never the bearer entry). */
export const RELAY_SUBPROTOCOL = "cmux-relay.v1"

/**
 * Per socket, in memory only (a wake forgets, which only ever allows more): frames and bytes a second. One object
 * passes about 4,000 incoming messages a second (cmux-transport relay_frame.rs, measured 2026-10-02), and a sender
 * packs every ready datagram into one frame of up to 16 KiB, so this is far above a terminal link and above a
 * screen share's video. Past it a frame is dropped silently: WireGuard and TCP inside it back off.
 */
export const RELAY_BUCKETS = { frames: { rate: 1500, burst: 3000 }, bytes: { rate: 8 * 1024 * 1024, burst: 16 * 1024 * 1024 } } as const

/** A notice (`peer` offline, `error`) goes to one socket at most this often per kind. */
export const RELAY_NOTICE_INTERVAL_MS = 5000

interface RelayAttachment {
  readonly device: string
  readonly peer: string
}

type Bucket = { t: number; at: number }

/** Per leg (one socket), in memory only like the buckets: what this object saw. A wake forgets. */
export interface LegCounters {
  framesIn: number
  bytesIn: number
  framesOut: number
  bytesOut: number
  /** Tagged records received, and the ones latest-wins dropped. */
  recordsIn: number
  recordsSuperseded: number
  /** Frames refused (bad frame, over the limit, rate limit) and notices sent. */
  refused: number
  notices: number
}

const newCounters = (): LegCounters => ({ framesIn: 0, bytesIn: 0, framesOut: 0, bytesOut: 0, recordsIn: 0, recordsSuperseded: 0, refused: 0, notices: 0 })

/** Tagged records waiting for the end of this turn, for one target socket. */
interface Pending {
  readonly queue: TaggedQueue
  readonly peer: Uint8Array
  from: WebSocket
  scheduled: boolean
}

export class LinkRelay extends DurableObject<Env> {
  private readonly buckets = new WeakMap<WebSocket, { frames: Bucket; bytes: Bucket }>()
  private readonly notices = new WeakMap<WebSocket, Map<string, number>>()
  private readonly attachments = new WeakMap<WebSocket, RelayAttachment>()
  private readonly counters = new WeakMap<WebSocket, LegCounters>()
  private readonly pending = new WeakMap<WebSocket, Pending>()

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(APP_PING, APP_PONG))
  }

  override async fetch(req: Request): Promise<Response> {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response("expected a WebSocket upgrade", { status: 426 })
    const device = req.headers.get("x-cmux-relay-device") ?? ""
    const peer = req.headers.get("x-cmux-relay-peer") ?? ""
    if (!device || !peer || device === peer) return new Response("bad relay join", { status: 400 })
    const pair = new WebSocketPair()
    const [client, server] = [pair[0], pair[1]]
    // One socket per device: a newer join (a redial, a roam onto a new network) replaces the older.
    for (const old of this.ctx.getWebSockets(device)) {
      try {
        old.close(4000, "replaced")
      } catch {}
    }
    this.ctx.acceptWebSocket(server, [device])
    const att: RelayAttachment = { device, peer }
    server.serializeAttachment(att)
    this.attachments.set(server, att)
    const other = this.socketOf(peer)
    server.send(JSON.stringify({ type: "joined", peer: other !== undefined }))
    if (other) other.send(JSON.stringify({ type: "peer", online: true }))
    const headers = new Headers()
    if (req.headers.get("x-cmux-relay-subprotocol")) headers.set("sec-websocket-protocol", RELAY_SUBPROTOCOL)
    return new Response(null, { status: 101, webSocket: client, headers })
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    // The only text a client sends is `stats`: its leg's counters and its peer's, as one text frame. The ping is
    // answered before it reaches here.
    if (typeof message === "string") {
      if (message === "stats") this.sendStats(ws)
      return
    }
    const c = this.legOf(ws)
    c.framesIn += 1
    c.bytesIn += message.byteLength
    if (message.byteLength > RELAY_FRAME_MAX) return this.refuse(ws, { type: "error", code: "too_large" })
    if (!this.take(ws, message.byteLength)) {
      c.refused += 1
      return
    }
    const bytes = new Uint8Array(message)
    const checked = checkFrame(bytes)
    if (!checked.ok) return this.refuse(ws, { type: "error", code: `bad_frame:${checked.error}` })
    // Only datagrams cross: the other kinds belong to the host relay, not to a two-party link.
    if (checked.kind !== "datagrams" && checked.kind !== "tagged-datagrams") return this.refuse(ws, { type: "error", code: "bad_frame:kind" })
    const att = this.attachment(ws)
    if (!att) return
    const target = this.socketOf(att.peer)
    if (!target) return this.notice(ws, "peer", { type: "peer", online: false })
    const peer = uuidToBytes(att.device)
    if (checked.kind === "tagged-datagrams") {
      this.enqueue(ws, target, peer, bytes, c)
      return
    }
    // A plain frame never overtakes records queued before it.
    this.flush(target)
    this.forward(ws, target, withPeer(bytes, peer))
  }

  /** Sends one frame to `target`; `from` hears the peer is gone when the send fails. */
  private forward(from: WebSocket, target: WebSocket, frame: Uint8Array) {
    try {
      target.send(frame)
      const t = this.legOf(target)
      t.framesOut += 1
      t.bytesOut += frame.length
    } catch {
      this.notice(from, "peer", { type: "peer", online: false })
    }
  }

  private enqueue(from: WebSocket, target: WebSocket, peer: Uint8Array, bytes: Uint8Array, c: LegCounters) {
    const records = splitTagged(bytes.subarray(RELAY_FRAME_HEADER_LEN))
    if (!records) return
    let p = this.pending.get(target)
    if (!p) {
      p = { queue: new TaggedQueue(), peer, from, scheduled: false }
      this.pending.set(target, p)
    }
    p.from = from
    for (const r of records) {
      c.recordsIn += 1
      c.recordsSuperseded += p.queue.add(r)
    }
    if (p.queue.bytes >= COALESCE_FLUSH_BYTES) return this.flush(target)
    if (!p.scheduled) {
      p.scheduled = true
      // The end of this turn: frames that arrive before it share one send.
      setTimeout(() => this.flush(target), 0)
    }
  }

  /** Sends what is queued for `target`, in order, as the fewest frames. */
  private flush(target: WebSocket) {
    const p = this.pending.get(target)
    if (!p || p.queue.length === 0) return
    for (const frame of p.queue.drain(p.peer, 4)) this.forward(p.from, target, frame)
  }

  private legOf(ws: WebSocket): LegCounters {
    let c = this.counters.get(ws)
    if (!c) {
      c = newCounters()
      this.counters.set(ws, c)
    }
    return c
  }

  private sendStats(ws: WebSocket) {
    const att = this.attachment(ws)
    const other = att ? this.socketOf(att.peer) : undefined
    try {
      ws.send(JSON.stringify({ type: "stats", leg: this.legOf(ws), peer: other ? this.legOf(other) : null }))
    } catch {}
  }

  private refuse(ws: WebSocket, frame: unknown) {
    this.legOf(ws).refused += 1
    this.notice(ws, "error", frame)
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    this.gone(ws)
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    this.gone(ws)
  }

  /** A socket closed: its peer hears it, unless a newer socket of the same device replaced it. */
  private gone(ws: WebSocket) {
    const att = this.attachment(ws)
    if (!att || this.socketOf(att.device, ws)) return
    try {
      this.socketOf(att.peer)?.send(JSON.stringify({ type: "peer", online: false }))
    } catch {}
  }

  private attachment(ws: WebSocket): RelayAttachment | undefined {
    const hit = this.attachments.get(ws)
    if (hit) return hit
    const att = ws.deserializeAttachment() as RelayAttachment | null
    if (att) this.attachments.set(ws, att)
    return att ?? undefined
  }

  /** The open socket of `device`, other than `except`. */
  private socketOf(device: string, except?: WebSocket): WebSocket | undefined {
    return this.ctx.getWebSockets(device).find((ws) => ws !== except && ws.readyState === WebSocket.OPEN)
  }

  private notice(ws: WebSocket, kind: string, frame: unknown) {
    let sent = this.notices.get(ws)
    if (!sent) {
      sent = new Map()
      this.notices.set(ws, sent)
    }
    const now = Date.now()
    const last = sent.get(kind)
    if (last !== undefined && now - last < RELAY_NOTICE_INTERVAL_MS) return
    sent.set(kind, now)
    this.legOf(ws).notices += 1
    try {
      ws.send(JSON.stringify(frame))
    } catch {}
  }

  private take(ws: WebSocket, bytes: number): boolean {
    const now = Date.now()
    let b = this.buckets.get(ws)
    if (!b) {
      b = { frames: { t: RELAY_BUCKETS.frames.burst, at: now }, bytes: { t: RELAY_BUCKETS.bytes.burst, at: now } }
      this.buckets.set(ws, b)
    }
    const refill = (bucket: Bucket, spec: { rate: number; burst: number }) => {
      bucket.t = Math.min(spec.burst, bucket.t + ((now - bucket.at) / 1000) * spec.rate)
      bucket.at = now
    }
    refill(b.frames, RELAY_BUCKETS.frames)
    refill(b.bytes, RELAY_BUCKETS.bytes)
    if (b.frames.t < 1 || b.bytes.t < bytes) return false
    b.frames.t -= 1
    b.bytes.t -= bytes
    return true
  }
}
