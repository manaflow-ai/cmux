import type { Env } from "../env.ts"
import { freshTimestamp, hmacHex, readRawBody, sha256Hex, timingSafeEqual } from "./verify.ts"

/**
 * Generic signed webhook trigger: `POST /v1/hooks/automation/<team>/<trigger>`.
 *
 * Scheme (Stripe-style): headers `x-cmux-timestamp: <unix seconds>`,
 * `x-cmux-signature: v1=<hex HMAC-SHA256(secret, "<timestamp>.<raw body>")>`
 * (several `v1=` values allowed, comma separated) and optional
 * `x-cmux-delivery: <sender id>` as a label. Dedupe uses the signed content
 * (timestamp and body) only, so an unsigned header cannot turn a replay into
 * a new delivery.
 *
 * The per-trigger secret is derived, never stored: HMAC(K, "<team>:<trigger>")
 * with K = HKDF-SHA256 of the API signing key, domain-separated per
 * environment. So the Worker verifies before any Durable Object call, and a
 * new trigger id is a new secret.
 */

export const MAX_AUTOMATION_HOOK_BYTES = 256 * 1024
const TEAM = /^team_[a-z0-9]{20}$/
const TRIGGER = /^trg_[a-z0-9]{20}$/
const DELIVERY = /^[A-Za-z0-9_.:-]{1,100}$/

const b64uDecode = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(s.length / 4) * 4, "=")), (c) => c.charCodeAt(0))

const keys = new Map<string, Promise<Uint8Array>>()
const webhookKey = (env: Env): Promise<Uint8Array> => {
  // Keyed by the key material itself, so a rotated signing key derives fresh secrets in a warm isolate.
  const cacheKey = `${env.ENVIRONMENT}:${env.JWT_PRIVATE_JWK}`
  let k = keys.get(cacheKey)
  if (!k) {
    k = (async () => {
      const d = (JSON.parse(env.JWT_PRIVATE_JWK) as { d?: string }).d
      if (!d) throw new Error("JWT_PRIVATE_JWK has no private part")
      const ikm = await crypto.subtle.importKey("raw", b64uDecode(d), "HKDF", false, ["deriveBits"])
      const bits = await crypto.subtle.deriveBits(
        { name: "HKDF", hash: "SHA-256", salt: new TextEncoder().encode("cmux-webhook-trigger-v1"), info: new TextEncoder().encode(env.ENVIRONMENT) },
        ikm,
        256
      )
      return new Uint8Array(bits)
    })()
    keys.set(cacheKey, k)
  }
  return k
}

export const automationHookSecret = async (env: Env, team: string, trigger: string) => `whsec_${await hmacHex(await webhookKey(env), `${team}:${trigger}`)}`

export const automationHookPath = (team: string, trigger: string) => `/v1/hooks/automation/${team}/${trigger}`

export interface DeliverResult {
  readonly status: "accepted" | "duplicate" | "unknown" | "disabled" | "skipped" | "rate_limited"
  readonly run?: string
}

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })

export const handleAutomationHook = async (request: Request, env: Env, team: string, trigger: string): Promise<Response> => {
  if (request.method !== "POST") return json(405, { ok: false, code: "method.not_allowed" })
  if (!TEAM.test(team) || !TRIGGER.test(trigger)) return json(404, { ok: false, code: "selector.not_found" })
  const body = await readRawBody(request, MAX_AUTOMATION_HOOK_BYTES)
  if (!body.ok) return json(body.status, { ok: false, code: "validation.invalid", message: body.message })

  const ts = request.headers.get("x-cmux-timestamp")
  if (!freshTimestamp(ts, Date.now())) return json(401, { ok: false, code: "auth.unauthenticated", message: "missing or stale x-cmux-timestamp" })
  const sigs = (request.headers.get("x-cmux-signature") ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.startsWith("v1="))
    .map((s) => s.slice(3))
  const expected = await hmacHex(await automationHookSecret(env, team, trigger), `${ts}.${body.text}`)
  // Check every candidate so the time does not depend on which one matched.
  let valid = false
  for (const s of sigs) valid = timingSafeEqual(s, expected) || valid
  if (!valid) return json(401, { ok: false, code: "auth.unauthenticated", message: "bad signature" })

  // Dedupe only on what the signature covers: an unsigned header could be changed to replay a
  // captured request inside the window. x-cmux-delivery is kept as a label in the run input.
  const header = request.headers.get("x-cmux-delivery")
  if (header !== null && !DELIVERY.test(header)) return json(400, { ok: false, code: "validation.invalid", message: "x-cmux-delivery must be 1-100 of [A-Za-z0-9_.:-]" })
  const delivery = `sha256:${(await sha256Hex(`${ts}.${body.text}`)).slice(0, 40)}`

  const contentType = request.headers.get("content-type") ?? ""
  let payload: unknown = body.text
  if (contentType.includes("json") && body.text.length > 0) {
    try {
      payload = JSON.parse(body.text)
    } catch {
      return json(400, { ok: false, code: "validation.invalid", message: "body is not JSON" })
    }
  }
  const input = { content_type: contentType.slice(0, 100), body: payload, received_at: Date.now(), ...(header ? { delivery_label: header } : {}) }

  const stub = env.SCHEDULER_DO.get(env.SCHEDULER_DO.idFromName(team))
  const r = (await stub.deliverWebhook(team, trigger, delivery, input)) as DeliverResult
  const label = header ? { label: header } : {}
  switch (r.status) {
    case "unknown":
      return json(404, { ok: false, code: "selector.not_found" })
    case "disabled":
      return json(409, { ok: false, code: "automation.disabled", delivery, ...label })
    case "rate_limited":
      // Not remembered as delivered: the sender's retry (same delivery id) starts the run later.
      return new Response(JSON.stringify({ ok: false, code: "rate.limited", delivery, ...label }), { status: 429, headers: { "content-type": "application/json", "retry-after": "1" } })
    default:
      return json(202, { ok: true, delivery, ...label, status: r.status, ...(r.run ? { run: r.run } : {}) })
  }
}
