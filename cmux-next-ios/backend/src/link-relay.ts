import { DurableObject } from "cloudflare:workers"
import type { Env } from "./env.ts"
import { FIRST_GRANT, MIB, RELAY_CLOSE } from "./relay-access.ts"
import { checkFrame, RELAY_FRAME_MAX, withPeer } from "./relay-frame.ts"
import { APP_PING, APP_PONG, userHubName, uuidToBytes } from "./team-hub.ts"

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
 * no storage.
 */
export const relayRoomName = (ownerKey: string, space: string, sessionId: string) =>
  `${space ? `${space}|` : ""}relay:${ownerKey}:${sessionId}`

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

/**
 * RFD 0142 R3, tail replay: the header the Worker sets when a join asked for it (`?replay=1`). A device whose
 * latest join asked has the frames sent to it kept for [`REPLAY_AGE_MS`], and its next join (a roam: the new socket
 * replaces the old) gets them again right after `joined`. That covers what went into the old socket after the
 * device's network died (the relay cannot tell a dead TCP connection from a quiet one) and what arrived while it had
 * no socket at all. WireGuard drops the copies that did arrive (its replay window), so a duplicate costs bytes only.
 */
export const RELAY_REPLAY_HEADER = "x-cmux-relay-replay"
/** A kept frame older than this is not sent again (inner TCP's minimum retransmission timeout is 1 s). */
export const REPLAY_AGE_MS = 1000
/** Bytes kept per device, and per session (both devices); the oldest go first. Memory only: a wake forgets. */
export const REPLAY_DEVICE_BYTES = 128 * 1024
export const REPLAY_SESSION_BYTES = 256 * 1024

/** The frames lately sent (or meant) for one device, oldest first, as they were forwarded (peer id stamped). */
export class ReplayTail {
  private frames: { at: number; bytes: Uint8Array }[] = []
  size = 0

  push(bytes: Uint8Array, now = Date.now()) {
    if (bytes.length > REPLAY_DEVICE_BYTES) return
    this.frames.push({ at: now, bytes })
    this.size += bytes.length
    this.trim(now, REPLAY_DEVICE_BYTES)
  }

  /** Drop frames past [`REPLAY_AGE_MS`] and, oldest first, until at most `max` bytes are kept. */
  trim(now: number, max: number) {
    let drop = 0
    while (drop < this.frames.length) {
      const f = this.frames[drop]!
      if (now - f.at <= REPLAY_AGE_MS && this.size <= max) break
      this.size -= f.bytes.length
      drop += 1
    }
    if (drop) this.frames.splice(0, drop)
  }

  /** The oldest kept frame's time, or `Infinity` when empty. */
  oldest(): number {
    return this.frames[0]?.at ?? Number.POSITIVE_INFINITY
  }

  dropOldest() {
    const f = this.frames.shift()
    if (f) this.size -= f.bytes.length
  }

  /** Every frame still young enough, oldest first, and empty the tail. */
  take(now = Date.now()): Uint8Array[] {
    this.trim(now, REPLAY_DEVICE_BYTES)
    const out = this.frames.map((f) => f.bytes)
    this.frames = []
    this.size = 0
    return out
  }
}

/** The tag of a netcheck socket (never a device id: those are UUIDs). */
const NETCHECK_TAG = "netcheck"

interface RelayAttachment {
  readonly device: string
  readonly peer: string
  /** Whose budget this socket spends: the owner key and build space of the user's hub. */
  readonly owner: string
  readonly space: string
  /** This join asked for tail replay (RFD 0142 R3); absent on sockets joined before it. */
  readonly replay?: boolean
}

type Bucket = { t: number; at: number }

export class LinkRelay extends DurableObject<Env> {
  private readonly buckets = new WeakMap<WebSocket, { frames: Bucket; bytes: Bucket }>()
  private readonly notices = new WeakMap<WebSocket, Map<string, number>>()
  private readonly attachments = new WeakMap<WebSocket, RelayAttachment>()
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
  /** Tail replay (RFD 0142 R3): per device whose latest join asked, the frames lately sent to it. */
  private readonly tails = new Map<string, ReplayTail>()

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(APP_PING, APP_PONG))
  }

  override async fetch(req: Request): Promise<Response> {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response("expected a WebSocket upgrade", { status: 426 })
    if (new URL(req.url).pathname === "/netcheck") return this.netcheck(req)
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
    const replay = req.headers.get(RELAY_REPLAY_HEADER) === "1"
    const att: RelayAttachment = replay ? { device, peer, owner, space, replay } : { device, peer, owner, space }
    server.serializeAttachment(att)
    this.attachments.set(server, att)
    // What was sent to this device lately goes again (when it asked), else its tail is forgotten.
    const tail = this.tails.get(device)
    const again = replay && tail ? tail.take() : []
    if (replay) this.tails.set(device, new ReplayTail())
    else this.tails.delete(device)
    const other = this.socketOf(peer)
    server.send(JSON.stringify({ type: "joined", peer: other !== undefined }))
    // Not awaited: a grant from the hub (a fresh wake has no credit) never holds the join's answer.
    if (again.length) void this.replay(server, att, again)
    if (other) other.send(JSON.stringify({ type: "peer", online: true }))
    const headers = new Headers()
    if (req.headers.get("x-cmux-relay-subprotocol")) headers.set("sec-websocket-protocol", RELAY_SUBPROTOCOL)
    return new Response(null, { status: 101, webSocket: client, headers })
  }

  /**
   * Send `frames` (a device's tail) on its new socket, charged to the owner's budget like any relayed frame: all of
   * them or, when the budget refuses, none.
   */
  private async replay(ws: WebSocket, att: RelayAttachment, frames: Uint8Array[]) {
    const bytes = frames.reduce((n, f) => n + f.length, 0)
    if (!(await this.spend(att, bytes))) return
    try {
      for (const f of frames) ws.send(f)
    } catch {}
  }

  /** The tail of `device` if its latest join asked for replay (a wake forgot the tail, never the ask). */
  private tailOf(device: string, socket: WebSocket | undefined): ReplayTail | undefined {
    const hit = this.tails.get(device)
    if (hit || !socket || !this.attachment(socket)?.replay) return hit
    const tail = new ReplayTail()
    this.tails.set(device, tail)
    return tail
  }

  /** Keep `bytes`, just sent (or meant) for `device`, within the device's and the session's bounds. */
  private record(tail: ReplayTail, bytes: Uint8Array) {
    const now = Date.now()
    tail.push(bytes, now)
    let total = 0
    for (const t of this.tails.values()) total += t.size
    while (total > REPLAY_SESSION_BYTES) {
      let oldest: ReplayTail | undefined
      for (const t of this.tails.values()) if (t.size && (!oldest || t.oldest() < oldest.oldest())) oldest = t
      if (!oldest) break
      const before = oldest.size
      oldest.dropOldest()
      total -= before - oldest.size
    }
  }

  /** Close every socket of this session with `code` (the hub's call when the session or a device ends). */
  async closeAll(code: number, reason: string): Promise<void> {
    this.tails.clear()
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
    // Text frames carry nothing (the ping is answered before it reaches here).
    if (typeof message === "string") return
    if (message.byteLength > RELAY_FRAME_MAX) return this.notice(ws, "error", { type: "error", code: "too_large" })
    if (!this.take(ws, message.byteLength)) return
    const bytes = new Uint8Array(message)
    const checked = checkFrame(bytes)
    if (!checked.ok) return this.notice(ws, "error", { type: "error", code: `bad_frame:${checked.error}` })
    // Only datagrams cross: the other kinds belong to the host relay, not to a two-party link.
    if (checked.kind !== "datagrams") return this.notice(ws, "error", { type: "error", code: "bad_frame:kind" })
    const att = this.attachment(ws)
    if (!att) return
    const target = this.socketOf(att.peer)
    const tail = this.tailOf(att.peer, target)
    if (!target) {
      // The peer's socket is gone (a roam in progress): kept for its next join when it asked, never spent until then.
      if (tail) this.record(tail, withPeer(bytes, uuidToBytes(att.device)))
      return this.notice(ws, "peer", { type: "peer", online: false })
    }
    if (!(await this.spend(att, bytes.length))) return this.notice(ws, "rate_limited", { type: "error", code: "rate_limited" })
    try {
      const out = withPeer(bytes, uuidToBytes(att.device))
      // Kept before the send: a send that throws, or that went into a socket whose network died, goes again.
      if (tail) this.record(tail, out)
      target.send(out)
    } catch {
      this.notice(ws, "peer", { type: "peer", online: false })
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
