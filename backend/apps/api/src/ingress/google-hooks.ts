import { createLocalJWKSet, createRemoteJWKSet, jwtVerify, type JWK, type JWTVerifyGetKey } from "jose"
import type { Env } from "../env.ts"
import { gmailAlias } from "../integrations/gmail-push.ts"
import { readRawBody } from "./verify.ts"

/**
 * Google push receivers (integrations-plan.md G2, G3), unauthenticated public
 * routes. Each refuses before any Durable Object call when its credential is
 * missing or wrong; failures (and only failures) count against a per-IP rate
 * limit, because every real push comes from shared Google address ranges.
 *
 * - `POST /v1/hooks/google/pubsub`: Gmail `users.watch` notifications through
 *   a Pub/Sub push subscription. The Bearer token is a Google-signed OIDC JWT
 *   (RS256, Google JWKS) whose audience and service-account email must match
 *   this deployment's subscription.
 * - `POST /v1/hooks/google/calendar`: Calendar channel notifications. The
 *   channel id selects the connection through an alias; the ConnectionDO
 *   compares the channel token (the Worker never holds it).
 */

const GOOGLE_JWKS = "https://www.googleapis.com/oauth2/v3/certs"
const ISSUERS = ["https://accounts.google.com", "accounts.google.com"]
const SKEW_SECONDS = 300

export const calendarAlias = (channel: string) => `gcal:channel:${channel}`

const text = (status: number, body = "") => new Response(body, { status })

let googleKeys: JWTVerifyGetKey | undefined
const keys = (env: Env): JWTVerifyGetKey => {
  if (env.ENVIRONMENT === "test" && env.GOOGLE_PUBSUB_TEST_JWKS) return createLocalJWKSet(JSON.parse(env.GOOGLE_PUBSUB_TEST_JWKS) as { keys: Array<JWK> })
  // jose refetches on an unknown kid (rotation), at most once per cooldown.
  googleKeys ??= createRemoteJWKSet(new URL(GOOGLE_JWKS), { cacheMaxAge: 60 * 60_000, cooldownDuration: 30_000 })
  return googleKeys
}

/** A refused request: counted per IP; past the limit the answer is 429. */
const refuse = async (env: Env, request: Request, status: 400 | 401): Promise<Response> => {
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown"
  const limited = env.GOOGLE_HOOK_FAIL_LIMIT ? !(await env.GOOGLE_HOOK_FAIL_LIMIT.limit({ key: `google-hook:${ip}` })).success : false
  return text(limited ? 429 : status)
}

export const verifyPubsubToken = async (env: Env, authorization: string | null): Promise<boolean> => {
  const token = authorization?.match(/^Bearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/)?.[1]
  if (!token) return false
  try {
    const { payload } = await jwtVerify(token, keys(env), { algorithms: ["RS256"], issuer: ISSUERS, audience: env.GOOGLE_PUBSUB_AUDIENCE!, clockTolerance: SKEW_SECONDS, requiredClaims: ["exp", "iat"] })
    return payload.email === env.GOOGLE_PUBSUB_SERVICE_ACCOUNT && payload.email_verified === true
  } catch {
    return false
  }
}

const decodeNotification = (body: string): { address: string; historyId: string; messageId: string } | undefined => {
  try {
    const b = JSON.parse(body) as { message?: { data?: unknown; messageId?: unknown; message_id?: unknown } }
    const data = b.message?.data
    if (typeof data !== "string" || data.length > 4096) return undefined
    const inner = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(data), (c) => c.charCodeAt(0)))) as { emailAddress?: unknown; historyId?: unknown }
    const address = inner.emailAddress
    const historyId = typeof inner.historyId === "number" || typeof inner.historyId === "string" ? String(inner.historyId) : ""
    if (typeof address !== "string" || address.length > 254 || !address.includes("@") || !/^[0-9]{1,20}$/.test(historyId)) return undefined
    const id = b.message?.messageId ?? b.message?.message_id
    return { address, historyId, messageId: typeof id === "string" ? id.slice(0, 64) : "" }
  } catch {
    return undefined
  }
}

export const handleGooglePubsub = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "POST") return text(405)
  if (!env.GOOGLE_PUBSUB_AUDIENCE || !env.GOOGLE_PUBSUB_SERVICE_ACCOUNT) return text(503)
  // No DO call, and no body read, before the token is verified.
  if (!(await verifyPubsubToken(env, request.headers.get("authorization")))) return refuse(env, request, 401)
  // After a valid token every answer is 204: a nack makes Pub/Sub redeliver for a day, and the
  // ConnectionDO's 15-minute fallback catches up on anything a failed pull missed.
  const raw = await readRawBody(request, 64 * 1024)
  const n = raw.ok ? decodeNotification(raw.text) : undefined
  if (!n) {
    console.error(JSON.stringify({ msg: "google pubsub: undecodable notification" }))
    return text(204)
  }
  // An unknown address answers 204 too: Pub/Sub must not retry a notification nobody wants.
  const links = await env.ACCOUNT_INDEX_DO.get(env.ACCOUNT_INDEX_DO.idFromName(gmailAlias(n.address))).list()
  const results = await Promise.allSettled(
    links.map(({ team, connection }) => env.CONNECTION_DO.get(env.CONNECTION_DO.idFromName(team)).googlePush(team, { kind: "gmail", connection, historyId: n.historyId, messageId: n.messageId }))
  )
  const failed = results.filter((r) => r.status === "rejected").length
  if (failed) console.error(JSON.stringify({ msg: "google pubsub: push handling failed", message: n.messageId, failed, links: links.length }))
  return text(204)
}

/**
 * Not routed until slice G2: an unknown channel must be refused before any
 * DO call, which needs a self-authenticating channel id (security review).
 */
export const handleGoogleCalendar = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "POST") return text(405)
  const channel = request.headers.get("x-goog-channel-id") ?? ""
  if (!/^cmuxch_[A-Za-z0-9_-]{22}$/.test(channel)) return refuse(env, request, 400)
  const token = request.headers.get("x-goog-channel-token") ?? ""
  const state = request.headers.get("x-goog-resource-state") ?? ""
  const number = request.headers.get("x-goog-message-number") ?? ""
  if (token.length > 256 || !/^[a-z_]{1,20}$/.test(state) || !/^[0-9]{0,20}$/.test(number)) return refuse(env, request, 400)
  const link = (await env.ACCOUNT_INDEX_DO.get(env.ACCOUNT_INDEX_DO.idFromName(calendarAlias(channel))).list())[0]
  if (link) {
    const stub = env.CONNECTION_DO.get(env.CONNECTION_DO.idFromName(link.team))
    await stub.googlePush(link.team, { kind: "calendar", connection: link.connection, channel, token, state, number })
  }
  // 200 for an unknown channel and a wrong token too, so a probe learns nothing.
  return text(200)
}
