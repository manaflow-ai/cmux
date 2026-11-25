import { DurableObject } from "cloudflare:workers"
import type { Env } from "./env.ts"
import { RELAY_BUCKETS, RELAY_NOTICE_INTERVAL_MS } from "./link-relay.ts"
import { checkFrame, hubHeader, RELAY_FRAME_HEADER_LEN, RELAY_FRAME_MAX, withPeer, type HubRole } from "./relay-frame.ts"
import { APP_PING, APP_PONG, uuidToBytes } from "./team-hub.ts"

/**
 * The three-way hub (RFD 0142 R6; PROTOCOL.md "Three-way hub"): one room per agent session where both sources of
 * the session's events (the Mac and the AutoCloud VM) upload and every viewer (the phone, another Mac) downloads
 * once. Named by the owner key, build space and session id (`hubRoomName`), never a client value; the Worker
 * admits only the owner's registered devices and tells this object each socket's device and role in headers no
 * client can set.
 *
 * It carries relay frames of kind `hub` (`relay-frame.ts`) and reads only their clear 35-byte header: the body is
 * sealed end to end by the source to the viewers with a key no relay holds, and the header is the seal's associated
 * data, so editing it is caught by the viewer (`cmux_transport::hub`). The rule, the same as
 * `cmux_transport::hub::HubRelayRule`:
 *
 * - a frame `to` viewers whose `(epoch, seq)` is newer than the highest this room forwarded goes to every viewer
 *   once; an older or equal one (the other source's copy, a replay) is dropped and counted. The source that is
 *   behind is the warm standby: when the Mac sleeps, the VM's frames are the newest and flow with no gap;
 * - a frame `to` the other source (Mac-to-VM sync when the two have no direct path) goes to that source as is.
 *
 * The frame's peer id is set to the sender's device id, and the header's source role must be the socket's own.
 * Constant cost: the high-water mark and the counters live in memory only (a wake forgets them, which only lets
 * one more copy through, and the viewer drops duplicates itself), no storage write per frame, hibernating sockets,
 * and the application ping is answered without waking the object.
 */
export const hubRoomName = (ownerKey: string, space: string, sessionId: string) => `${space ? `${space}|` : ""}hub:${ownerKey}:${sessionId}`

/** Offered by a hub client and echoed by a hub relay: the capability handshake (`cmux_transport::hub::HUB_SUBPROTOCOL`). */
export const HUB_SUBPROTOCOL = "cmux-hub.v1"
/** The hub header version this relay speaks; sent in `joined`. */
export const HUB_VERSION = 1

export type HubSocketRole = HubRole | "viewer"

interface HubAttachment {
  readonly device: string
  readonly role: HubSocketRole
  /** The room's session id (a UUID), from the Worker. */
  readonly session: string
}

type Bucket = { t: number; at: number }

const sameBytes = (a: Uint8Array, b: Uint8Array) => a.length === b.length && a.every((x, i) => x === b[i])

const tagOf = (role: HubSocketRole, device: string) => (role === "viewer" ? `viewer:${device}` : `source:${role}`)

export class HubRelay extends DurableObject<Env> {
  private readonly buckets = new WeakMap<WebSocket, { frames: Bucket; bytes: Bucket }>()
  private readonly notices = new WeakMap<WebSocket, Map<string, number>>()
  private readonly attachments = new WeakMap<WebSocket, HubAttachment>()
  /** The highest `(epoch, seq)` forwarded to viewers, in memory only. */
  private high: { epoch: bigint; seq: bigint } | undefined
  private forwarded = 0
  private dropped = 0

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(APP_PING, APP_PONG))
  }

  override async fetch(req: Request): Promise<Response> {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response("expected a WebSocket upgrade", { status: 426 })
    const device = req.headers.get("x-cmux-hub-device") ?? ""
    const role = (req.headers.get("x-cmux-hub-role") ?? "") as HubSocketRole
    const session = req.headers.get("x-cmux-hub-session") ?? ""
    if (!device || !session || !["mac", "vm", "viewer"].includes(role)) return new Response("bad hub join", { status: 400 })
    // One socket per source role and per viewer device: a newer join (a redial, a roam) replaces the older.
    const tag = tagOf(role, device)
    for (const old of this.ctx.getWebSockets(tag)) {
      try {
        old.close(4000, "replaced")
      } catch {}
    }
    const pair = new WebSocketPair()
    const [client, server] = [pair[0], pair[1]]
    this.ctx.acceptWebSocket(server, [tag, role === "viewer" ? "viewer" : "source", `device:${device}`])
    const att: HubAttachment = { device, role, session }
    server.serializeAttachment(att)
    this.attachments.set(server, att)
    server.send(JSON.stringify({ type: "joined", hub: HUB_VERSION, sources: { mac: this.source("mac") !== undefined, vm: this.source("vm") !== undefined } }))
    if (role !== "viewer") this.tellAll({ type: "source", role, online: true }, server)
    const headers = new Headers()
    if (req.headers.get("x-cmux-hub-subprotocol")) headers.set("sec-websocket-protocol", HUB_SUBPROTOCOL)
    return new Response(null, { status: 101, webSocket: client, headers })
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message === "string") {
      // The one text request: this room's counters (diagnostics and the tests); the ping never reaches here.
      if (message === '{"type":"stats"}') ws.send(JSON.stringify({ type: "stats", forwarded: this.forwarded, dropped: this.dropped }))
      return
    }
    if (message.byteLength > RELAY_FRAME_MAX) return this.notice(ws, "error", { type: "error", code: "too_large" })
    if (!this.take(ws, message.byteLength)) return
    const bytes = new Uint8Array(message)
    const checked = checkFrame(bytes)
    if (!checked.ok) return this.notice(ws, "error", { type: "error", code: `bad_frame:${checked.error}` })
    if (checked.kind !== "hub") return this.notice(ws, "error", { type: "error", code: "bad_frame:kind" })
    const att = this.attachment(ws)
    if (!att) return
    // Viewers only download; a source speaks only as itself and only for this room's session.
    if (att.role === "viewer") return this.notice(ws, "error", { type: "error", code: "bad_hub:viewer" })
    const header = hubHeader(bytes.subarray(RELAY_FRAME_HEADER_LEN))!
    if (header.source !== att.role) return this.notice(ws, "error", { type: "error", code: "bad_hub:role" })
    if (!sameBytes(header.session, uuidToBytes(att.session))) return this.notice(ws, "error", { type: "error", code: "bad_hub:session" })
    const out = withPeer(bytes, uuidToBytes(att.device))
    if (header.to !== "viewers") {
      const target = this.source(header.to)
      if (!target) return this.notice(ws, "source", { type: "source", role: header.to, online: false })
      try {
        target.send(out)
      } catch {}
      return
    }
    const high = this.high
    if (high && (header.epoch < high.epoch || (header.epoch === high.epoch && header.seq <= high.seq))) {
      this.dropped += 1
      return
    }
    this.high = { epoch: header.epoch, seq: header.seq }
    this.forwarded += 1
    for (const viewer of this.ctx.getWebSockets("viewer")) {
      if (viewer.readyState !== WebSocket.OPEN) continue
      try {
        viewer.send(out)
      } catch {}
    }
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    this.gone(ws)
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    this.gone(ws)
  }

  /** A source closed: everyone hears it, unless a newer socket of the same role replaced it. */
  private gone(ws: WebSocket) {
    const att = this.attachment(ws)
    if (!att || att.role === "viewer" || this.source(att.role, ws)) return
    this.tellAll({ type: "source", role: att.role, online: false }, ws)
  }

  private tellAll(frame: unknown, except?: WebSocket) {
    const text = JSON.stringify(frame)
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === except || ws.readyState !== WebSocket.OPEN) continue
      try {
        ws.send(text)
      } catch {}
    }
  }

  private attachment(ws: WebSocket): HubAttachment | undefined {
    const hit = this.attachments.get(ws)
    if (hit) return hit
    const att = ws.deserializeAttachment() as HubAttachment | null
    if (att) this.attachments.set(ws, att)
    return att ?? undefined
  }

  private source(role: HubRole, except?: WebSocket): WebSocket | undefined {
    return this.ctx.getWebSockets(`source:${role}`).find((ws) => ws !== except && ws.readyState === WebSocket.OPEN)
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
