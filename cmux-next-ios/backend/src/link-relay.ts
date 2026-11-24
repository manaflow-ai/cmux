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

/** A notice (`peer` offline, `error`) goes to one socket at most this often per kind. */
export const RELAY_NOTICE_INTERVAL_MS = 5000

interface RelayAttachment {
  readonly device: string
  readonly peer: string
  /** Whose budget this socket spends: the owner key and build space of the user's hub. */
  readonly owner: string
  readonly space: string
}

type Bucket = { t: number; at: number }

export class LinkRelay extends DurableObject<Env> {
  private readonly buckets = new WeakMap<WebSocket, { frames: Bucket; bytes: Bucket }>()
  private readonly notices = new WeakMap<WebSocket, Map<string, number>>()
  private readonly attachments = new WeakMap<WebSocket, RelayAttachment>()
  /** Bytes each socket may still relay before asking its owner's hub for more (memory only). */
  private readonly credit = new WeakMap<WebSocket, number>()
  /** The size of each socket's next grant ([`FIRST_GRANT`], doubling up to a MiB). */
  private readonly grantSize = new WeakMap<WebSocket, number>()
  /** A budget request in flight per socket: frames behind it wait for it, so they keep their order. */
  private readonly asking = new WeakMap<WebSocket, Promise<void>>()

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(APP_PING, APP_PONG))
  }

  override async fetch(req: Request): Promise<Response> {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response("expected a WebSocket upgrade", { status: 426 })
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

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    // The kill switch stops what is already relaying too, at its next frame.
    if (this.env.LINK_RELAY_MODE === "off") return this.closeAll(RELAY_CLOSE.off, "relay_off")
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
    if (!target) return this.notice(ws, "peer", { type: "peer", online: false })
    if (!(await this.spend(ws, att, bytes.length))) return this.notice(ws, "rate_limited", { type: "error", code: "rate_limited" })
    try {
      target.send(withPeer(bytes, uuidToBytes(att.device)))
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
   * Spend `bytes` of the owner's relay budget: from this socket's credit, else a grant from the owner's hub
   * ([`FIRST_GRANT`], doubling up to a MiB while the socket keeps relaying; one at a time per socket, and frames
   * that arrive meanwhile wait for it, in order). A refused grant starts over at the first size, so a link's
   * keepalives still pass while a busy one waits. A hub that cannot be reached grants it: a hiccup there must
   * not cut every relayed link, and the per-socket limit still holds.
   */
  private async spend(ws: WebSocket, att: RelayAttachment, bytes: number): Promise<boolean> {
    for (;;) {
      const inFlight = this.asking.get(ws)
      if (!inFlight) break
      await inFlight
    }
    let credit = this.credit.get(ws) ?? 0
    if (credit < bytes) {
      let grant: (granted: boolean) => void = () => {}
      const granted = new Promise<boolean>((resolve) => (grant = resolve))
      this.asking.set(ws, granted.then(() => {}))
      try {
        const hub = this.env.TEAM_HUB.get(this.env.TEAM_HUB.idFromName(userHubName(att.owner, att.space)))
        const size = Math.max(this.grantSize.get(ws) ?? FIRST_GRANT, bytes)
        const ok = await hub.relayBudget({ ownerKey: att.owner, space: att.space }, size / MIB).catch((e: unknown) => {
          console.log(JSON.stringify({ msg: "relay budget unavailable", error: String(e) }))
          return true
        })
        if (ok) credit += size
        this.grantSize.set(ws, ok ? Math.min(size * 2, MIB) : FIRST_GRANT)
        grant(ok)
      } finally {
        this.asking.delete(ws)
      }
    }
    if (credit < bytes) {
      this.credit.set(ws, credit)
      return false
    }
    this.credit.set(ws, credit - bytes)
    return true
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
