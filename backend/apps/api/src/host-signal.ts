import type { ErrorBody } from "./mobile-session.ts"

/**
 * WebRTC signaling relay checks (b1-control-do.md section 5; a0-rpc.md section 5.12). Signals are
 * ephemeral: HostDO validates, rewrites `from` and forwards; nothing is stored or logged.
 */

export const SIGNAL_KINDS = new Set(["offer", "answer", "ice", "ice.end", "bye"])
const SESSION = /^sess_[A-Za-z0-9]{2,64}$/
const BYE_REASONS = new Set(["closed", "failed", "superseded", "revoked"])

/** Token bucket: SIGNAL_BURST frames, refilled over SIGNAL_WINDOW_MS. */
export const SIGNAL_BURST = 120
export const SIGNAL_WINDOW_MS = 10_000

const bad = (message: string): ErrorBody => ({ code: "validation.invalid", message, retryable: false })
const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v)
const onlyKeys = (o: Record<string, unknown>, keys: ReadonlyArray<string>) => Object.keys(o).every((k) => keys.includes(k))
const BASE64 = /^[A-Za-z0-9+/_-]+={0,2}$/
/** `auth {key, sig}`: the signer's P-256 key and its signature over the DTLS fingerprint binding (b2-webrtc.md section 8). Peers verify it; the relay only bounds its shape. */
const authError = (auth: unknown): ErrorBody | undefined => {
  if (auth === undefined) return undefined
  if (!isObj(auth) || !onlyKeys(auth, ["key", "sig"])) return bad("auth must be {key, sig}")
  for (const field of [auth.key, auth.sig]) {
    if (typeof field !== "string" || field.length < 1 || field.length > 256 || !BASE64.test(field)) return bad("auth.key and auth.sig must be base64 of at most 256 characters")
  }
  return undefined
}

/** Checks a signal body against families/signal.schema.json. */
export const signalBodyError = (kind: string, body: unknown): ErrorBody | undefined => {
  if (!isObj(body)) return bad("signal body must be an object")
  switch (kind) {
    case "offer":
      if (!onlyKeys(body, ["sdp", "ice_restart", "carrier", "auth"])) return bad("unknown offer field")
      if (typeof body.sdp !== "string" || body.sdp.length < 1 || body.sdp.length > 65536) return bad("offer.sdp must be 1 to 65536 characters")
      if (body.ice_restart !== undefined && typeof body.ice_restart !== "boolean") return bad("offer.ice_restart must be a boolean")
      if (body.carrier !== undefined && body.carrier !== "webrtc" && body.carrier !== "webrtc-wg") return bad("offer.carrier must be webrtc or webrtc-wg")
      return authError(body.auth)
    case "answer":
      if (!onlyKeys(body, ["sdp", "auth"]) || typeof body.sdp !== "string" || body.sdp.length < 1 || body.sdp.length > 65536) return bad("answer.sdp must be 1 to 65536 characters")
      return authError(body.auth)
    case "ice": {
      if (!onlyKeys(body, ["candidate", "sdp_mid", "sdp_mline_index"])) return bad("unknown ice field")
      if (typeof body.candidate !== "string" || body.candidate.length > 1024) return bad("ice.candidate must be at most 1024 characters")
      const mid = body.sdp_mid
      const index = body.sdp_mline_index
      if (mid !== null && (typeof mid !== "string" || mid.length > 64)) return bad("ice.sdp_mid must be a short string or null")
      if (index !== null && (!Number.isInteger(index) || (index as number) < 0)) return bad("ice.sdp_mline_index must be a non-negative integer or null")
      return undefined
    }
    case "ice.end":
      return Object.keys(body).length === 0 ? undefined : bad("ice.end has no fields")
    case "bye":
      return onlyKeys(body, ["reason"]) && typeof body.reason === "string" && BYE_REASONS.has(body.reason) ? undefined : bad("bye.reason must be closed, failed, superseded or revoked")
    default:
      return bad(`unknown signal kind ${kind}`)
  }
}

/** The relayable parts of a signal frame, or the error to answer. */
export const parseSignal = (frame: Record<string, unknown>): { ok: true; kind: string; session: string; to: string; body: Record<string, unknown> } | { ok: false; error: ErrorBody } => {
  const { kind, session, to, body } = frame
  if (typeof kind !== "string" || !SIGNAL_KINDS.has(kind)) return { ok: false, error: bad("signal.kind must be offer, answer, ice, ice.end or bye") }
  if (typeof session !== "string" || !SESSION.test(session)) return { ok: false, error: bad("signal.session must be a sess_ id") }
  if (typeof to !== "string" || to.length === 0 || to.length > 128) return { ok: false, error: bad("signal.to is required") }
  const err = signalBodyError(kind, body)
  if (err) return { ok: false, error: err }
  return { ok: true, kind, session, to, body: body as Record<string, unknown> }
}

/** Per-socket signal budget (memory only: an evicted object starts every socket with a full bucket). */
export class SignalBudget {
  private readonly buckets = new WeakMap<WebSocket, { tokens: number; at: number }>()

  take(ws: WebSocket, now = Date.now()): boolean {
    const b = this.buckets.get(ws) ?? { tokens: SIGNAL_BURST, at: now }
    const refill = ((now - b.at) / SIGNAL_WINDOW_MS) * SIGNAL_BURST
    const tokens = Math.min(SIGNAL_BURST, b.tokens + refill)
    if (tokens < 1) {
      this.buckets.set(ws, { tokens, at: now })
      return false
    }
    this.buckets.set(ws, { tokens: tokens - 1, at: now })
    return true
  }
}
