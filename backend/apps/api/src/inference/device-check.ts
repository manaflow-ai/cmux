import { importPKCS8, SignJWT } from "jose"
import type { Env } from "../env.ts"

/**
 * Apple DeviceCheck (two bits per device that survive a reinstall) for the free tier
 * (plans/cmux-next/model-router.md, cx-dna4.3, cx-ds09i). Bit 0 = "this device took a free grant",
 * bit 1 = "this device also took its one replacement key", with Apple's `last_update_time`
 * (YYYY-MM) as the month of the last write. One grant and one replacement key per device per
 * month; an earlier key keeps its grant until its month ends (accepted gap: Apple names no device,
 * so the old key cannot be revoked; a device has at most two live keys in one month).
 *
 * Needs the secrets INFERENCE_DEVICECHECK_KEY_P8 + INFERENCE_DEVICECHECK_KEY_ID (a key with the
 * DeviceCheck capability) and the var APPLE_TEAM_ID. Without them the free tier refuses (dark).
 */

export type DeviceBits = { readonly ok: true; readonly bit0: boolean; readonly bit1: boolean; readonly month: string | null } | { readonly ok: false; readonly reason: string }

export const deviceCheckConfigured = (env: Env) => Boolean(env.INFERENCE_DEVICECHECK_KEY_P8 && env.INFERENCE_DEVICECHECK_KEY_ID && env.APPLE_TEAM_ID)

const host = (env: Env) => (env.ENVIRONMENT !== "production" && env.INFERENCE_DEVICECHECK_DEVELOPMENT === "true" ? "https://api.development.devicecheck.apple.com" : "https://api.devicecheck.apple.com")

let cached: { key: CryptoKey; kid: string; jwt: string; exp: number } | undefined

const bearer = async (env: Env): Promise<string> => {
  const now = Math.floor(Date.now() / 1000)
  if (cached && cached.kid === env.INFERENCE_DEVICECHECK_KEY_ID && cached.exp - 300 > now) return cached.jwt
  const key = cached && cached.kid === env.INFERENCE_DEVICECHECK_KEY_ID ? cached.key : ((await importPKCS8(env.INFERENCE_DEVICECHECK_KEY_P8!, "ES256")) as CryptoKey)
  const jwt = await new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: env.INFERENCE_DEVICECHECK_KEY_ID! }).setIssuer(env.APPLE_TEAM_ID!).setIssuedAt(now).sign(key)
  cached = { key, kid: env.INFERENCE_DEVICECHECK_KEY_ID!, jwt, exp: now + 3000 }
  return jwt
}

const call = async (env: Env, path: string, body: Record<string, unknown>): Promise<Response> =>
  fetch(`${host(env)}/v1/${path}`, {
    method: "POST",
    headers: { authorization: `Bearer ${await bearer(env)}`, "content-type": "application/json" },
    body: JSON.stringify({ ...body, transaction_id: crypto.randomUUID(), timestamp: Date.now() })
  })

/** Reads the device's bits. A device Apple has never seen answers 200 with a plain-text body: no bits. */
export const queryBits = async (env: Env, deviceToken: string): Promise<DeviceBits> => {
  if (!deviceCheckConfigured(env)) return { ok: false, reason: "devicecheck.not_configured" }
  try {
    const r = await call(env, "query_two_bits", { device_token: deviceToken })
    if (r.status === 400) return { ok: false, reason: "devicecheck.bad_token" }
    if (!r.ok) return { ok: false, reason: `devicecheck.http_${r.status}` }
    const text = await r.text()
    if (!text.trim().startsWith("{")) return { ok: true, bit0: false, bit1: false, month: null }
    const j = JSON.parse(text) as { bit0?: unknown; bit1?: unknown; last_update_time?: unknown }
    return { ok: true, bit0: j.bit0 === true, bit1: j.bit1 === true, month: typeof j.last_update_time === "string" ? j.last_update_time : null }
  } catch {
    return { ok: false, reason: "devicecheck.unreachable" }
  }
}

/** Sets bit 0 (grant taken) and bit 1 (`replacement`: the month's replacement key taken); Apple stamps the month. */
export const markGranted = async (env: Env, deviceToken: string, replacement = false): Promise<boolean> => {
  try {
    const r = await call(env, "update_two_bits", { device_token: deviceToken, bit0: true, bit1: replacement })
    await r.body?.cancel()
    return r.ok
  } catch {
    return false
  }
}
