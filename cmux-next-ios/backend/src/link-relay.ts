import { DurableObject } from "cloudflare:workers"
import type { Env } from "./env.ts"
import { TaggedQueue, COALESCE_FLUSH_BYTES } from "./relay-coalesce.ts"
import { FIRST_GRANT, MIB, RELAY_CLOSE } from "./relay-access.ts"
import { checkFrame, RELAY_FRAME_HEADER_LEN, RELAY_FRAME_MAX, splitTagged, withPeer } from "./relay-frame.ts"
import { CACHE_PATH_PREFIX, cacheFetch, RelayCache } from "./relay-cache.ts"
import { HoldQueue, parseHoldFrame } from "./relay-hold.ts"
import { APP_PING, APP_PONG, userHubName, uuidToBytes } from "./team-hub.ts"

export { relayRoomName } from "./placement.ts"

/** Selected when a client offers it (never the bearer entry). */
export const RELAY_SUBPROTOCOL = "cmux-relay.v1"

/** The header a join presents its own relay ticket in (the `relayTicket` its signaling socket received). */
export const RELAY_TICKET_HEADER = "x-cmux-relay-ticket"

/**
 * Per socket, in memory only (a wake forgets, which only ever allows more): frames and bytes a second. One object
 * passes about 4,000 incoming messages a second (cmux-transport relay_frame.rs, measured 2026-10-02), and a sender
 * packs every ready datagram into one frame of up to 16 KiB, so this is far above a terminal link and above a
 * screen share's video. Past it a frame is dropped silently: WireGuard and TCP inside it back off.
 */
export const RELAY_BUCKETS = { frames: { rate: 1500, burst: 3000 }, bytes: { rate: 8 * 1024 * 1024, burst: 16 * 1024 * 1024 } } as const

/**
 * Frames that may wait for one grant in flight (at most 4 MiB a session); past it they are dropped (WireGuard and
 * TCP resend). A burst that arrives during a session's first grant still fits.
 */
const MAX_WAITING = 256
/** A refusal holds at least this long (the hub's retry-after can be shorter on a fresh minute). */
const MIN_HOLD_MS = 250
/** A hub that failed is not asked again for this long, and nothing is relayed meanwhile (fail closed). */
const HUB_ERROR_HOLD_MS = 1000

/** A notice (`peer` offline, `error`) goes to one socket at most this often per kind. */
export const RELAY_NOTICE_INTERVAL_MS = 5000

/** How far back a rejoin's replay reaches: about one end-to-end retransmit timer of in-flight datagrams. */
export const RELAY_TAIL_MS = 1000
/** The most one session's tail holds (both directions); past it the oldest frames go first. */
export const RELAY_TAIL_BYTES = 256 * 1024

/** One frame of the tail, as it went (or would have gone) to `target`, peer id already stamped. */
interface TailFrame {
  readonly at: number
  readonly target: string
  readonly bytes: Uint8Array
  /** Whether its bytes came out of the owner's budget yet (a frame held with no socket to go to has not). */
  spent: boolean
  readonly from: RelayAttachment
}

/** The tag of a netcheck socket (never a device id: those are UUIDs). */
const NETCHECK_TAG = "netcheck"

interface RelayAttachment {
  readonly device: string
  readonly peer: string
  /** Whose budget this socket spends: the owner key and build space of the user's hub. */
  readonly owner: string
  readonly space: string
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

/**
 * The link's WebSocket relay (PROTOCOL.md "WebSocket relay", API 0.17.0): the last way a WireGuard link reaches
 * its peer when neither plain UDP nor a TURN server gets through, as on a network that lets only cmux's own
 * domains, or only HTTP inside TLS, out. One object per link session, named by the owner key, build space and
 * session id (`relayRoomName`), never a client value. The Worker admits a socket only for a device the owner's
 * hub bound to that session at its first signal and that presents its own relay ticket (TeamHub `relayPeer`),
 * and tells this object the device, its peer, the owner key and the build space in headers no client can set
 * (the object is reached only through the Worker). Each MiB relayed is first granted by the owner's hub
 * (`relayBudget`, one budget across all of the user's sessions). The hub closes the live sockets when the session
 * ends, a device or the account is removed (`closeAll`), and the kill switch closes them at their next frame.
 *
 * It carries relay frames (`relay-frame.ts`) of kind `datagrams` from one party's socket to the other's, with the
 * frame's peer id set to the sender's device id, and reads nothing else: the datagrams are WireGuard ciphertext,
 * end to end between the phone and the Mac. Hibernating WebSockets, tagged by device id, so a quiet session (a
 * link that settled on a direct path) costs nothing; the application ping is answered without waking it. It keeps
 * no storage, except the relay-held send queue's sealed items when `LINK_RELAY_HOLD=on` (RFD 0142 R8,
 * `relay-hold.ts`): bounded, expiring in 10 minutes, and never readable here. A source device's cache room (named by
 * `relayCacheRoomName`, never a session) keeps sealed snapshots and deltas when `LINK_RELAY_CACHE=on` (RFD 0142 R2
 * and R9, `relay-cache.ts`): bounded, expiring, and never readable here either.
 *
 * Tail replay (RFD 0142 R3, make-before-break): it keeps the last [`RELAY_TAIL_MS`] of frames it relayed or held
 * toward each device, in memory and at most [`RELAY_TAIL_BYTES`] a session. A frame sent into a socket that is
 * still open but whose network just went away (the phone moved from Wi-Fi to cell) is lost there, as is one sent
 * while the device has no socket. When that device joins again (a newer socket replacing the old, or a redial),
 * the tail goes out on the new socket at once, so the receiver has what was in flight one relay leg after it is
 * back instead of after the sender's retransmit timer. The replayed datagrams are the same WireGuard ciphertext;
 * the ones that did arrive die in WireGuard's replay window. The relay sees nothing it did not already see, and
 * nothing is ever written to storage.
 *
 * Latest-wins (RFD 0142 R5): it also carries `tagged-datagrams` (hop/1 DATA records). Tagged records are coalesced
 * per target socket within one event-loop turn, and a class-1 record is dropped when a newer one of the same key is
 * queued with it (`relay-coalesce.ts`). Workers' WebSocket has no `bufferedAmount` or drain event
 * (developers.cloudflare.com/workers/runtime-apis/websockets, checked 2026-11-24), so the object cannot see a send
 * backlog: it coalesces only what it already holds. A client's text `stats` is answered with per-leg counters.
 *
 * Prewarmed (RFD 0142 C4, PROTOCOL.md "Relay placement"): the hub creates and places this object when it forwards
 * the session's first `wg-init` (`/prewarm`, no socket), so a later join finds it made and placed instead of
 * paying for creation and a cold start while a link waits on its last path.
 */
export class LinkRelay extends DurableObject<Env> {
  private readonly buckets = new WeakMap<WebSocket, { frames: Bucket; bytes: Bucket }>()
  private readonly notices = new WeakMap<WebSocket, Map<string, number>>()
  private readonly attachments = new WeakMap<WebSocket, RelayAttachment>()
  private readonly counters = new WeakMap<WebSocket, LegCounters>()
  private readonly pending = new WeakMap<WebSocket, Pending>()
  /**
   * This session's lease on the owner's budget (memory only; a wake starts with none and asks again): bytes it may
   * still relay, the size of its next grant ([`FIRST_GRANT`], doubling up to a MiB), until when the hub's last
   * refusal or failure holds (frames are dropped here meanwhile, never one hub call per frame), the one grant
   * request in flight, and how many frames wait for it.
   */
  private credit = 0
  private grantSize = FIRST_GRANT
  private deniedUntil = 0
  private asking: Promise<void> | undefined
  private waiting = 0
  /** The tail ([`RELAY_TAIL_MS`], [`RELAY_TAIL_BYTES`]): memory only, oldest first. */
  private tail: TailFrame[] = []
  private tailBytes = 0
  private readonly holds: HoldQueue
  private readonly cache: RelayCache

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    this.holds = new HoldQueue(ctx.storage)
    this.cache = new RelayCache(ctx.storage)
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(APP_PING, APP_PONG))
  }

  /** When this instance last took a prewarm (diagnostics and tests: in memory, a wake forgets it). */
  prewarmedAt: number | undefined

  override async fetch(req: Request): Promise<Response> {
    const path = new URL(req.url).pathname
    // The hub's prewarm: reaching the object created and placed it; nothing else to do. No socket, no storage.
    if (path === "/prewarm") {
      this.prewarmedAt = Date.now()
      return new Response(null, { status: 204 })
    }
    // The sealed snapshot cache and delta log (RFD 0142 R2, R9; relay-cache.ts): plain HTTP from the Worker, which
    // checked the devices. Only a source's cache room (`relayCacheRoomName`) is ever sent these.
    if (path.startsWith(CACHE_PATH_PREFIX)) return cacheFetch(this.cache, req, path)
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response("expected a WebSocket upgrade", { status: 426 })
    if (path === "/netcheck") return this.netcheck(req)
    const device = req.headers.get("x-cmux-relay-device") ?? ""
    const peer = req.headers.get("x-cmux-relay-peer") ?? ""
    const owner = req.headers.get("x-cmux-relay-owner") ?? ""
    const space = req.headers.get("x-cmux-relay-space") ?? ""
    if (!device || !peer || !owner || device === peer) return new Response("bad relay join", { status: 400 })
    const pair = new WebSocketPair()
    const [client, server] = [pair[0], pair[1]]
    // One socket per device: a newer join (a redial, a roam onto a new network) replaces the older.
    for (const old of this.ctx.getWebSockets(device)) {
      try {
        old.close(RELAY_CLOSE.replaced, "replaced")
      } catch {}
    }
    this.ctx.acceptWebSocket(server, [device])
    const att: RelayAttachment = { device, peer, owner, space }
    server.serializeAttachment(att)
    this.attachments.set(server, att)
    const other = this.socketOf(peer)
    server.send(JSON.stringify({ type: "joined", peer: other !== undefined }))
    if (other) other.send(JSON.stringify({ type: "peer", online: true }))
    await this.replayTail(server, device)
    if (this.holdOn()) await this.drainHeld(server, device)
    const headers = new Headers()
    if (req.headers.get("x-cmux-relay-subprotocol")) headers.set("sec-websocket-protocol", RELAY_SUBPROTOCOL)
    return new Response(null, { status: 101, webSocket: client, headers })
  }

  /** Close every socket of this session with `code` (the hub's call when the session or a device ends). */
  async closeAll(code: number, reason: string): Promise<void> {
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.close(code, reason)
      } catch {}
    }
  }

  /**
   * A netcheck socket (`placement.ts`): the runtime answers its `ping` with `pong` without waking this object, and
   * anything else closes it. Tagged `netcheck`, never a device, so it can never receive a relay frame.
   */
  private netcheck(req: Request): Response {
    const pair = new WebSocketPair()
    const [client, server] = [pair[0], pair[1]]
    this.ctx.acceptWebSocket(server, [NETCHECK_TAG])
    const headers = new Headers()
    if (req.headers.get("x-cmux-relay-subprotocol")) headers.set("sec-websocket-protocol", RELAY_SUBPROTOCOL)
    return new Response(null, { status: 101, webSocket: client, headers })
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    // The kill switch stops what is already relaying too, at its next frame.
    if (this.env.LINK_RELAY_MODE === "off") return this.closeAll(RELAY_CLOSE.off, "relay_off")
    if (this.ctx.getTags(ws).includes(NETCHECK_TAG)) {
      try {
        ws.close(1008, "netcheck answers ping only")
      } catch {}
      return
    }
    // Text frames: `stats` (this leg's counters and its peer's, as one text frame) or the relay-held send queue's.
    // The ping is answered before it reaches here.
    if (typeof message === "string") {
      if (message === "stats") return this.sendStats(ws)
      return this.holdText(ws, message)
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
    const peer = uuidToBytes(att.device)
    const stamped = withPeer(bytes, peer)
    if (!target) {
      // Held for the peer's rejoin (it may be between two sockets), unspent until it goes.
      this.keep(att.peer, stamped, false, att)
      return this.notice(ws, "peer", { type: "peer", online: false })
    }
    // Tagged frames spend the owner's budget as they arrive, as plain ones do (a superseded record was still relayed in).
    if (!(await this.spend(att, bytes.length))) {
      c.refused += 1
      return this.notice(ws, "rate_limited", { type: "error", code: "rate_limited" })
    }
    this.keep(att.peer, stamped, true, att)
    if (checked.kind === "tagged-datagrams") {
      this.enqueue(ws, target, peer, bytes, c)
      return
    }
    // A plain frame never overtakes records queued before it.
    this.flush(target)
    this.forward(ws, target, stamped)
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

  /** Add a frame to the tail, dropping what is older than [`RELAY_TAIL_MS`] or past [`RELAY_TAIL_BYTES`]. */
  private keep(target: string, bytes: Uint8Array, spent: boolean, from: RelayAttachment) {
    if (this.env.LINK_RELAY_TAIL === "off") return
    const now = Date.now()
    this.prune(now)
    if (bytes.length > RELAY_TAIL_BYTES) return
    this.tail.push({ at: now, target, bytes, spent, from })
    this.tailBytes += bytes.length
    while (this.tailBytes > RELAY_TAIL_BYTES) this.tailBytes -= this.tail.shift()!.bytes.length
  }

  private prune(now: number) {
    let drop = 0
    while (drop < this.tail.length && now - this.tail[drop]!.at > RELAY_TAIL_MS) this.tailBytes -= this.tail[drop++]!.bytes.length
    if (drop) this.tail.splice(0, drop)
  }

  /**
   * `device` just joined on `ws`: send it, oldest first, every frame of the last [`RELAY_TAIL_MS`] that went (or
   * would have gone) to it, and take them out of the tail. A held frame spends its budget now; one the budget
   * refuses is dropped, as it would have been live.
   */
  private async replayTail(ws: WebSocket, device: string) {
    this.prune(Date.now())
    const mine = this.tail.filter((f) => f.target === device)
    if (mine.length === 0) return
    this.tail = this.tail.filter((f) => f.target !== device)
    for (const f of mine) this.tailBytes -= f.bytes.length
    for (const f of mine) {
      if (!f.spent && !(await this.spend(f.from, f.bytes.length))) continue
      try {
        ws.send(f.bytes)
      } catch {
        return
      }
    }
  }

  override async alarm(): Promise<void> {
    const now = Date.now()
    await this.holds.onAlarm(now)
    // A cache room's expiry shares the one alarm: re-arm for the earlier of the two.
    const next = await this.cache.purge(now)
    if (next !== undefined) {
      const current = await this.ctx.storage.getAlarm()
      if (current === null || current > next) await this.ctx.storage.setAlarm(next)
    }
  }

  private holdOn(): boolean {
    return this.env.LINK_RELAY_HOLD === "on"
  }

  /**
   * A `hold` or `held_ack` text frame (RFD 0142 R8). A hold is acked at once, kept, and handed to the peer now if
   * it is joined, else when it joins; the peer's `held_ack` deletes it and tells the sender `delivered`.
   */
  private async holdText(ws: WebSocket, text: string): Promise<void> {
    const parsed = parseHoldFrame(text)
    if (parsed === null) return
    const att = this.attachment(ws)
    if (!att) return
    if (parsed === "bad") return this.notice(ws, "hold_bad", { type: "hold_refused", code: "bad" })
    if (!this.holdOn()) {
      if (parsed.type === "hold") ws.send(JSON.stringify({ type: "hold_refused", id: parsed.id, code: "off" }))
      return
    }
    if (!this.take(ws, text.length)) return
    const now = Date.now()
    if (parsed.type === "held_ack") {
      const from = await this.holds.ack(att.device, parsed.id, now)
      if (from) {
        try {
          this.socketOf(from)?.send(JSON.stringify({ type: "delivered", id: parsed.id }))
        } catch {}
      }
      return
    }
    const answer = await this.holds.hold(att.device, att.peer, parsed.id, parsed.sealed, now)
    try {
      ws.send(JSON.stringify(answer))
    } catch {}
    if (answer.type !== "held" || answer.delivered) return
    const target = this.socketOf(att.peer)
    if (target) await this.drainHeld(target, att.peer, parsed.id)
  }

  /** Hand `device` everything held for it, oldest first (again on every join: delivery is at least once). */
  private async drainHeld(ws: WebSocket, device: string, only?: string) {
    for (const item of await this.holds.items(device)) {
      if (only !== undefined && item.id !== only) continue
      try {
        ws.send(JSON.stringify({ type: "held_item", id: item.id, from: item.from, sealed: item.sealed, at: item.at, expiresAt: item.expiresAt }))
      } catch {
        return
      }
    }
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

  /**
   * Spend `bytes` of the owner's relay budget (review of #53240): from this session's credit, else one grant from
   * the owner's hub at a time ([`FIRST_GRANT`], doubling up to a MiB while the session keeps relaying), with at most
   * [`MAX_WAITING`] frames waiting for it. A refusal holds for the hub's `retryAfterMs`, and a hub that fails
   * (overloaded, unreachable) grants nothing and is not asked again for [`HUB_ERROR_HOLD_MS`]: the budget fails
   * closed, and frames are dropped here meanwhile without a hub call each.
   */
  private async spend(att: RelayAttachment, bytes: number): Promise<boolean> {
    for (;;) {
      if (this.credit >= bytes) {
        this.credit -= bytes
        return true
      }
      if (Date.now() < this.deniedUntil) return false
      if (this.asking) {
        if (this.waiting >= MAX_WAITING) return false
        this.waiting += 1
        try {
          await this.asking
        } finally {
          this.waiting -= 1
        }
        continue
      }
      this.asking = this.askGrant(att, bytes)
      try {
        await this.asking
      } finally {
        this.asking = undefined
      }
    }
  }

  /** One grant request to the owner's hub; its answer lands in the lease (credit, or a hold). */
  private async askGrant(att: RelayAttachment, bytes: number): Promise<void> {
    const size = Math.max(this.grantSize, bytes)
    try {
      const hub = this.env.TEAM_HUB.get(this.env.TEAM_HUB.idFromName(userHubName(att.owner, att.space)))
      const answer = await hub.relayBudget({ ownerKey: att.owner, space: att.space }, size / MIB)
      if (answer.granted) {
        this.credit += size
        this.grantSize = Math.min(size * 2, MIB)
        return
      }
      this.grantSize = FIRST_GRANT
      this.deniedUntil = Date.now() + Math.min(Math.max(answer.retryAfterMs, MIN_HOLD_MS), 60_000)
    } catch (e) {
      console.log(JSON.stringify({ msg: "relay budget unavailable", error: String(e) }))
      this.grantSize = FIRST_GRANT
      this.deniedUntil = Date.now() + HUB_ERROR_HOLD_MS
    }
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
