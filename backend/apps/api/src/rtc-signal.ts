import type { Attachment } from "./owner-do.ts"

/**
 * WebRTC signaling between one user's devices (plans/cmux-next/ios-rtc.md section 4). It rides the
 * user's own `/v1/wire/user` socket as non-ledger frames: nothing here commits state, and a device
 * is "online" exactly while its socket is open. The relay stamps `from` from the socket, never from
 * the frame, so a peer can only speak as itself; both ends are the same authenticated user.
 *
 * Client frames: `rtc.hello`, `rtc.hosts`, `rtc.signal`. Server frames: `rtc.welcome`, `rtc.hosts`,
 * `rtc.signal`, `rtc.error`.
 */
export interface RtcPeer {
  readonly role: "host" | "client"
  /** Stable per install and per build (a host per Mac app tag, a client per phone app install). */
  readonly peer: string
  readonly name: string
  /** Build lane of the app: `default`, `nightly`, a DEV tag. Clients filter hosts by it. */
  readonly tag: string
  readonly platform: string
  readonly app_version: string
  readonly since: number
}

type RtcAttachment = Attachment & { rtc?: RtcPeer }

const PEER = /^[A-Za-z0-9_.:-]{8,80}$/
const SESSION = /^[A-Za-z0-9_-]{8,64}$/
const KINDS = new Set(["offer", "answer", "candidate", "bye"])
/** An SDP with many candidates stays far below this; anything larger is not signaling. */
const MAX_SIGNAL_BYTES = 64 * 1024
const MAX_LABEL = 120

const send = (ws: WebSocket, frame: Record<string, unknown>) => {
  try {
    ws.send(JSON.stringify(frame))
  } catch {}
}

const text = (v: unknown, fallback: string) => (typeof v === "string" && v.length > 0 ? v.slice(0, MAX_LABEL) : fallback)

const peerOf = (ws: WebSocket) => (ws.deserializeAttachment() as RtcAttachment | null)?.rtc

const hostList = (sockets: ReadonlyArray<WebSocket>) =>
  sockets
    .map(peerOf)
    .filter((p): p is RtcPeer => p?.role === "host")
    .map(({ role: _role, ...host }) => host)
    .sort((a, b) => a.since - b.since)

const broadcastHosts = (sockets: ReadonlyArray<WebSocket>, except?: WebSocket) => {
  const hosts = hostList(sockets)
  for (const ws of sockets) if (ws !== except && peerOf(ws)?.role === "client") send(ws, { t: "rtc.hosts", hosts })
}

/** Handles one `rtc.*` frame; false for any other frame type. */
export const handleRtcFrame = (all: () => ReadonlyArray<WebSocket>, ws: WebSocket, frame: { readonly t?: string } & Record<string, unknown>): boolean => {
  if (typeof frame.t !== "string" || !frame.t.startsWith("rtc.")) return false
  const fail = (code: string, extra: Record<string, unknown> = {}) => send(ws, { t: "rtc.error", code, ...extra })
  switch (frame.t) {
    case "rtc.hello": {
      const role = frame.role
      const peer = frame.peer
      if ((role !== "host" && role !== "client") || typeof peer !== "string" || !PEER.test(peer)) {
        fail("validation.invalid", { message: "rtc.hello needs role host|client and a peer id" })
        return true
      }
      const a = ws.deserializeAttachment() as RtcAttachment
      const rtc: RtcPeer = {
        role,
        peer,
        name: text(frame.name, role === "host" ? "Mac" : "iPhone"),
        tag: text(frame.tag, "default"),
        platform: text(frame.platform, "unknown"),
        app_version: text(frame.app_version, ""),
        since: Date.now()
      }
      // One live socket per peer: a reconnect replaces the old one (no ghost host in the list).
      for (const other of all()) {
        if (other !== ws && peerOf(other)?.peer === peer) {
          try {
            other.close(4000, "replaced")
          } catch {}
        }
      }
      ws.serializeAttachment({ ...a, rtc } satisfies RtcAttachment)
      const others = all().filter((s) => s !== ws && peerOf(s)?.peer !== peer)
      send(ws, { t: "rtc.welcome", peer })
      if (role === "client") send(ws, { t: "rtc.hosts", hosts: hostList([ws, ...others]) })
      else broadcastHosts(others)
      return true
    }
    case "rtc.hosts": {
      send(ws, { t: "rtc.hosts", hosts: hostList(all()) })
      return true
    }
    case "rtc.signal": {
      const me = peerOf(ws)
      if (!me) {
        fail("rtc.no_hello")
        return true
      }
      const { to, session, kind } = frame
      if (typeof to !== "string" || !PEER.test(to) || typeof session !== "string" || !SESSION.test(session) || typeof kind !== "string" || !KINDS.has(kind)) {
        fail("validation.invalid", { message: "rtc.signal needs to, session and kind", ...(typeof session === "string" ? { session } : {}) })
        return true
      }
      const payload: Record<string, unknown> = { t: "rtc.signal", from: me.peer, from_role: me.role, session, kind }
      if (typeof frame.sdp === "string") payload.sdp = frame.sdp
      if (typeof frame.candidate === "string") payload.candidate = frame.candidate
      if (typeof frame.sdp_mid === "string") payload.sdp_mid = frame.sdp_mid
      if (typeof frame.sdp_mline_index === "number") payload.sdp_mline_index = frame.sdp_mline_index
      if (typeof frame.reason === "string") payload.reason = frame.reason.slice(0, MAX_LABEL)
      const encoded = JSON.stringify(payload)
      if (encoded.length > MAX_SIGNAL_BYTES) {
        fail("rtc.too_large", { session })
        return true
      }
      // Signaling only crosses roles: a phone talks to a Mac, a Mac answers a phone.
      const targets = all().filter((s) => {
        const p = peerOf(s)
        return p?.peer === to && p.role !== me.role
      })
      if (targets.length === 0) {
        fail("rtc.peer_offline", { session, to })
        return true
      }
      for (const target of targets) {
        try {
          target.send(encoded)
        } catch {}
      }
      return true
    }
    default:
      fail("validation.invalid", { message: `unknown frame ${frame.t}` })
      return true
  }
}

/** Called when a socket closes: clients learn at once that a host went away. */
export const rtcSocketClosed = (all: () => ReadonlyArray<WebSocket>, ws: WebSocket) => {
  if (peerOf(ws)?.role !== "host") return
  broadcastHosts(all().filter((s) => s !== ws))
}
