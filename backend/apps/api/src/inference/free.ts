import { createLocalJWKSet, decodeJwt, jwtVerify, SignJWT, type JWK } from "jose"
import { verifyAttestation, type AttestedKey } from "../app-attest.ts"
import { issuer, publicJwks, signer } from "../auth.ts"
import type { Env } from "../env.ts"
import { deviceCheckConfigured, markGranted, queryBits } from "./device-check.ts"
import type { Caller } from "./route.ts"

/**
 * The free tier (plans/cmux-next/model-router.md, cx-dna4.3): a genuine cmux app on a genuine
 * Apple device gets a small daily quota on the free models without a sign-in.
 *
 *   POST /v1/inference/free/challenge  -> { challenge, expires_at }  (stateless, HMAC, 5 min)
 *   POST /v1/inference/free/attest     { platform, key_id, attestation, challenge, device_token }
 *                                      App Attest attestation over the challenge + DeviceCheck
 *                                      bit 0 (one grant per device per month) -> { token, expires_at }
 *   POST /v1/inference/free/token      { key_id, challenge, assertion } -> a fresh token; the
 *                                      assertion's counter must grow, so a copied token or a replayed
 *                                      assertion cannot extend access
 *
 * The token is an ES256 JWT of this API with `aud inference` (installPrincipal accepts only
 * `aud api`, so it can never act on anything else), 1 hour. Off unless INFERENCE_FREE_ENABLED=1,
 * the DeviceCheck key and INFERENCE_FREE_APP_IDS are all set: a missing piece refuses (dark).
 * An attestation failure is never retried into a weaker path: no attestation, no free tier.
 */

const CHALLENGE_TTL_MS = 5 * 60_000
const TOKEN_TTL_S = 3600
const AUD = "inference"

const err = (status: number, code: string, message: string) => Response.json({ error: { code, message, type: status === 429 ? "insufficient_quota" : "invalid_request_error" } }, { status })
const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const unb64u = (s: string): Uint8Array | null => {
  if (!/^[A-Za-z0-9_-]{1,200}$/.test(s)) return null
  try {
    return Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(s.length / 4) * 4, "=")), (c) => c.charCodeAt(0))
  } catch {
    return null
  }
}

const freeOn = (env: Env) => env.INFERENCE_ENABLED === "1" && env.INFERENCE_FREE_ENABLED === "1"
const appIds = (env: Env) => (env.INFERENCE_FREE_APP_IDS ?? "").split(",").map((s) => s.trim()).filter(Boolean)
const ready = (env: Env) => freeOn(env) && deviceCheckConfigured(env) && appIds(env).length > 0
const device = (env: Env, keyId: string) => env.FREE_DEVICE_DO.get(env.FREE_DEVICE_DO.idFromName(keyId))
const clientIp = (request: Request) => request.headers.get("cf-connecting-ip") ?? "unknown"

let macKey: { env: string; key: CryptoKey } | undefined
/** HMAC key for challenges, derived from the API signing key (no extra secret to rotate). */
const challengeKey = async (env: Env) => {
  if (macKey?.env === env.ENVIRONMENT) return macKey.key
  const seed = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`cmux-free-challenge-v1\n${env.ENVIRONMENT}\n${env.JWT_PRIVATE_JWK}`))
  const key = await crypto.subtle.importKey("raw", seed, { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"])
  macKey = { env: env.ENVIRONMENT, key }
  return key
}

/** challenge = b64u(issued_at_ms(8) || random(16) || hmac(24 bytes)[0..16]). */
const newChallenge = async (env: Env, now: number) => {
  const body = new Uint8Array(24)
  new DataView(body.buffer).setBigUint64(0, BigInt(now))
  crypto.getRandomValues(body.subarray(8))
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", await challengeKey(env), body)).subarray(0, 16)
  const out = new Uint8Array(40)
  out.set(body)
  out.set(mac, 24)
  return b64u(out)
}

const challengeValid = async (env: Env, challenge: unknown, now: number): Promise<boolean> => {
  if (typeof challenge !== "string") return false
  const raw = unb64u(challenge)
  if (!raw || raw.length !== 40) return false
  const issued = Number(new DataView(raw.buffer, raw.byteOffset).getBigUint64(0))
  if (!(issued <= now + 5_000 && now - issued <= CHALLENGE_TTL_MS)) return false
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", await challengeKey(env), raw.subarray(0, 24))).subarray(0, 16)
  let diff = 0
  for (let i = 0; i < 16; i++) diff |= mac[i]! ^ raw[24 + i]!
  return diff === 0
}

const mint = async (env: Env, keyId: string) => {
  const { key, kid } = await signer(env)
  const now = Math.floor(Date.now() / 1000)
  const token = await new SignJWT({ fr: 1 }).setProtectedHeader({ alg: "ES256", kid, typ: "cmux-free+jwt" }).setIssuer(issuer(env)).setAudience(AUD).setSubject(keyId).setIssuedAt(now).setExpirationTime(now + TOKEN_TTL_S).sign(key)
  return Response.json({ token, expires_at: (now + TOKEN_TTL_S) * 1000, token_type: "Bearer" })
}

const readJson = async (request: Request): Promise<Record<string, unknown> | null> => {
  const text = await request.text()
  if (text.length > 64 * 1024) return null
  try {
    const v = JSON.parse(text) as unknown
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null
  } catch {
    return null
  }
}

const keyIdOk = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9+/=_-]{20,100}$/.test(v)

export const handleFree = async (env: Env, path: string, request: Request): Promise<Response> => {
  if (request.method !== "POST") return err(405, "method", "POST only")
  if (!ready(env)) return err(503, "free.not_configured", "the free tier is not available on this deployment")
  const ip = clientIp(request)
  if (env.INFERENCE_FREE_IP_LIMIT && !(await env.INFERENCE_FREE_IP_LIMIT.limit({ key: ip })).success) return err(429, "free.rate", "too many requests from this network")
  const now = Date.now()
  if (path === "/v1/inference/free/challenge") return Response.json({ challenge: await newChallenge(env, now), expires_at: now + CHALLENGE_TTL_MS })
  const body = await readJson(request)
  if (!body) return err(400, "validation.invalid", "body must be a JSON object")
  if (!keyIdOk(body.key_id)) return err(400, "validation.invalid", "key_id is required")
  if (!(await challengeValid(env, body.challenge, now))) return err(403, "free.challenge", "the challenge is invalid or expired")
  const challengeBytes = new TextEncoder().encode(body.challenge as string)
  const stub = device(env, body.key_id)

  if (path === "/v1/inference/free/token") {
    if (typeof body.assertion !== "string" || body.assertion.length > 4096) return err(400, "validation.invalid", "assertion is required")
    if (!(await stub.assert(challengeBytes, body.assertion))) return err(403, "free.assertion", "the assertion did not verify")
    return mint(env, body.key_id)
  }
  if (path !== "/v1/inference/free/attest") return err(404, "not_found", "not found")

  if (env.INFERENCE_FREE_GRANT_LIMIT && !(await env.INFERENCE_FREE_GRANT_LIMIT.limit({ key: ip })).success) return err(429, "free.rate", "too many new devices from this network")
  if (body.platform !== "mac" && body.platform !== "ios") return err(400, "validation.invalid", "platform must be mac or ios")
  if (typeof body.attestation !== "string" || body.attestation.length > 16_384) return err(400, "validation.invalid", "attestation is required")
  if (typeof body.device_token !== "string" || body.device_token.length < 16 || body.device_token.length > 8192) return err(400, "validation.invalid", "device_token is required")
  let attested: AttestedKey | undefined
  let reason = "no app id matched"
  for (const appId of appIds(env)) {
    const r = verifyAttestation({ attestation: body.attestation, keyId: body.key_id, clientData: challengeBytes, appId, allowDevelopment: env.INFERENCE_FREE_ATTEST_DEVELOPMENT === "true", now })
    if (r.ok) {
      attested = r.key
      break
    }
    reason = r.reason
  }
  if (!attested) {
    console.warn(JSON.stringify({ msg: "inference.free.attest_refused", reason }))
    return err(403, "free.attestation", "this device could not be verified")
  }
  if (!(await stub.known())) {
    // A new install: one grant per device per month (DeviceCheck bit 0, stamped with the month).
    const bits = await queryBits(env, body.device_token)
    if (!bits.ok) return err(bits.reason === "devicecheck.bad_token" ? 403 : 503, "free.devicecheck", "this device could not be verified")
    if (bits.bit0 && bits.month === new Date(now).toISOString().slice(0, 7)) return err(403, "free.device_used", "this device already used its free access this month; sign in to continue")
    if (!(await markGranted(env, body.device_token))) return err(503, "free.devicecheck", "this device could not be verified")
  }
  if (!(await stub.register(attested, body.platform))) return err(403, "free.attestation", "this device could not be verified")
  console.log(JSON.stringify({ msg: "inference.free.granted", platform: body.platform }))
  return mint(env, body.key_id)
}

/** A free-tier token, or undefined (any other token goes to the normal sign-in check). */
export const freeCaller = async (env: Env, token: string): Promise<Caller | undefined> => {
  try {
    if (decodeJwt(token).aud !== AUD) return undefined
  } catch {
    return undefined
  }
  if (!freeOn(env)) return undefined
  try {
    const { payload } = await jwtVerify(token, createLocalJWKSet(publicJwks(env) as { keys: Array<JWK> }), { algorithms: ["ES256"], issuer: issuer(env), audience: AUD, clockTolerance: 30 })
    return typeof payload.sub === "string" && payload.fr === 1 ? { kind: "free", device: payload.sub } : undefined
  } catch {
    return undefined
  }
}

/** Refusal for a device over its quota or rate, or undefined when the request may proceed. */
export const freeAdmit = async (env: Env, keyId: string, id: string, tokenBound: number): Promise<Response | undefined> => {
  const r = await device(env, keyId).admit(id, tokenBound)
  if (r.ok) return undefined
  if (r.code === "free.unknown_device") return err(401, r.code, "this device is not registered")
  const res = err(429, r.code, r.code === "free.rate" ? "too many requests; wait a moment" : "today's free quota is used up; sign in to continue")
  if (r.retryAfterS) res.headers.set("retry-after", String(r.retryAfterS))
  return res
}

export const freeSettle = async (env: Env, keyId: string, id: string, tokens: number): Promise<void> => device(env, keyId).settle(id, tokens)
