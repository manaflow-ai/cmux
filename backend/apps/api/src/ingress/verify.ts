/**
 * Webhook verification primitives (spec integrations.md "Architecture"):
 * raw body, bounded size, HMAC with a constant-time compare, replay window.
 * Nothing here logs a body, a header value or a secret.
 */

export const MAX_WEBHOOK_BYTES = 1024 * 1024
/** Seconds a signed timestamp stays valid (Slack and Stripe use five minutes). */
export const REPLAY_WINDOW_SECONDS = 300

const enc = new TextEncoder()

export type RawBody = { ok: true; bytes: Uint8Array; text: string } | { ok: false; status: 413 | 400; message: string }

/** Reads at most MAX_WEBHOOK_BYTES; refuses a larger declared or actual body without buffering it. */
export const readRawBody = async (request: Request, max = MAX_WEBHOOK_BYTES): Promise<RawBody> => {
  const declared = Number(request.headers.get("content-length") ?? "0")
  if (Number.isFinite(declared) && declared > max) return { ok: false, status: 413, message: "body too large" }
  if (!request.body) return { ok: true, bytes: new Uint8Array(), text: "" }
  const reader = request.body.getReader()
  const chunks: Array<Uint8Array> = []
  let size = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    size += value.byteLength
    if (size > max) {
      await reader.cancel().catch(() => undefined)
      return { ok: false, status: 413, message: "body too large" }
    }
    chunks.push(value)
  }
  const bytes = new Uint8Array(size)
  let o = 0
  for (const c of chunks) {
    bytes.set(c, o)
    o += c.byteLength
  }
  return { ok: true, bytes, text: new TextDecoder().decode(bytes) }
}

const hmacKey = (secret: string | Uint8Array) =>
  crypto.subtle.importKey("raw", typeof secret === "string" ? enc.encode(secret) : secret, { name: "HMAC", hash: "SHA-256" }, false, ["sign"])

export const hmacHex = async (secret: string | Uint8Array, message: string | Uint8Array): Promise<string> => {
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(secret), typeof message === "string" ? enc.encode(message) : message)
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("")
}

/** Constant-time string compare (length leaks only, which is public for hex digests). */
export const timingSafeEqual = (a: string, b: string): boolean => {
  const x = enc.encode(a)
  const y = enc.encode(b)
  if (x.byteLength !== y.byteLength) return false
  let diff = 0
  for (let i = 0; i < x.byteLength; i++) diff |= x[i]! ^ y[i]!
  return diff === 0
}

/** A unix-seconds timestamp within the replay window of `now` (ms). */
export const freshTimestamp = (seconds: string | null | undefined, now: number, window = REPLAY_WINDOW_SECONDS): boolean => {
  if (!seconds || !/^[0-9]{1,12}$/.test(seconds)) return false
  return Math.abs(now / 1000 - Number(seconds)) <= window
}

export const sha256Hex = async (data: string | Uint8Array): Promise<string> => {
  const d = await crypto.subtle.digest("SHA-256", typeof data === "string" ? enc.encode(data) : data)
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("")
}
