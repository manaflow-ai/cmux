import type { Env } from "./env.ts"
import { markupPriceVersion, poolsMachineTime } from "./billing-catalog.ts"
import { usagePriceSet } from "./billing-usage-sync.ts"
import { readRawBody, timingSafeEqual } from "./ingress/verify.ts"
import { personalTeamIdFor, stackTeamIdFor, userIdFor } from "./domains/user.ts"

/**
 * The billing levels read (cx-y79zh S2, plans/cmux-next/usage-billing.md section 3): the usage
 * reconcile worker asks for each billed team's period total and sends that level to the payment
 * service. `POST /v1/internal/billing/levels` with `authorization: Bearer <BILLING_LEVELS_KEY>`:
 *
 *   {"items": [{"stack_team": "<id>" | "stack_user": "<id>", "from": <ms>, "to": <ms>}, ...]}
 *
 * A shared team is named by its sign-in service team id, a personal team by its owner's user id;
 * this route maps them to team ids (domains/user.ts), so the mapping has one implementation. The
 * answer per item is the period's level as the usage sync bills it, in integer micro-dollars
 * (UsageMeterDO.billedLevel): `micros` the billed level (under price set v2 the model overage above the
 * pool at list + 10%, Leo 2026-11-09; the sum of the facts at cost under v1 and e2e), `cost_micros` the
 * facts at cost, `included_micros` the pool the sync used (null for a period it never saw), and
 * `meter_micros` what the Stripe meter summary should show (per seat the billed level above the pool).
 * Read only. The route does not exist (404) without the key.
 */
export const BILLING_LEVELS_PATH = "/v1/internal/billing/levels"
/** The pricing of an AI usage level under v1 and e2e: pass-through cost (Lawrence 2026-10-13); v2 names its markup (usagePriceVersion). A price change is a new version. */
export const AI_PRICE_VERSION = "ai-passthrough-v1"
const MAX_ITEMS = 100
const MAX_BODY = 64 * 1024
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const STACK_ID = /^[A-Za-z0-9._:-]{1,128}$/
const normalId = (id: string) => (UUID.test(id) ? id.toLowerCase() : id)

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })

type Item = { readonly team: string; readonly from: number; readonly to: number; readonly stack_team?: string; readonly stack_user?: string }

const parseItem = (env: Env, raw: unknown): Item | string => {
  if (!raw || typeof raw !== "object") return "each item must be an object"
  const r = raw as { stack_team?: unknown; stack_user?: unknown; from?: unknown; to?: unknown }
  if (!Number.isSafeInteger(r.from) || !Number.isSafeInteger(r.to) || (r.from as number) < 0 || (r.to as number) <= (r.from as number)) return "from and to are integer ms with from < to"
  const from = r.from as number
  const to = r.to as number
  if (typeof r.stack_team === "string" && r.stack_user === undefined && STACK_ID.test(r.stack_team)) {
    const id = normalId(r.stack_team)
    return { team: stackTeamIdFor(env.STACK_PROJECT_ID, id), stack_team: id, from, to }
  }
  if (typeof r.stack_user === "string" && r.stack_team === undefined && STACK_ID.test(r.stack_user)) {
    // As auth.ts derives the user id: the token subject exactly as the sign-in service issues it.
    const id = r.stack_user
    return { team: personalTeamIdFor(userIdFor(env.STACK_PROJECT_ID, id)), stack_user: id, from, to }
  }
  return "each item names exactly one of stack_team or stack_user"
}

export const handleBillingLevels = async (request: Request, env: Env): Promise<Response> => {
  const key = env.BILLING_LEVELS_KEY
  if (!key || key.length < 32) return json({ error: "not found" }, 404)
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405)
  const presented = (request.headers.get("authorization") ?? "").replace(/^Bearer /, "")
  if (!timingSafeEqual(presented, key)) return json({ error: "unauthorized" }, 401)
  const raw = await readRawBody(request, MAX_BODY)
  if (!raw.ok) return json({ error: raw.message }, raw.status)
  let body: { items?: unknown }
  try {
    body = JSON.parse(raw.text) as { items?: unknown }
  } catch {
    return json({ error: "body must be JSON" }, 400)
  }
  if (!Array.isArray(body?.items) || body.items.length === 0 || body.items.length > MAX_ITEMS) return json({ error: `items: 1 to ${MAX_ITEMS} entries` }, 400)
  const items: Item[] = []
  for (const raw of body.items) {
    const item = parseItem(env, raw)
    if (typeof item === "string") return json({ error: item }, 400)
    items.push(item)
  }
  const levels = await Promise.all(
    items.map(async (item) => {
      const meter = env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(item.team))
      const l = await meter.billedLevel(item.team, item.from, item.to, poolsMachineTime(usagePriceSet(env)))
      // The period's pinned markup names the version; pass-through keeps the version this read has always named.
      return { ...item, micros: l.micros, cost_micros: l.cost_micros, models_micros: l.models_micros, machine_micros: l.machine_micros, included_micros: l.included_micros, meter_micros: l.meter_micros, markup_bp: l.markup_bp, facts: l.facts, last_at: l.last_at, price_version: l.markup_bp === 10_000 ? AI_PRICE_VERSION : markupPriceVersion(l.markup_bp) }
    })
  ).catch((e: unknown) => {
    console.error(JSON.stringify({ msg: "billing.levels.meter_failed", error: String(e).slice(0, 160) }))
    return null
  })
  if (!levels) return json({ error: "a usage meter is unavailable; retry", retryable: true }, 503)
  return json({ levels, read_at: Date.now() })
}

export const BILLING_SYNC_PATH = "/v1/internal/billing/sync"

/**
 * `POST /v1/internal/billing/sync` (same service key): one usage sync run now, for every billed
 * subscription or `{"subscription": "<id>"}` (an invoice-created trigger, a test). The cron runs the
 * same function every 15 minutes (index.ts). A live payment key is refused before any call.
 */
export const handleBillingSync = async (request: Request, env: Env): Promise<Response> => {
  const key = env.BILLING_LEVELS_KEY
  if (!key || key.length < 32) return json({ error: "not found" }, 404)
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405)
  const presented = (request.headers.get("authorization") ?? "").replace(/^Bearer /, "")
  if (!timingSafeEqual(presented, key)) return json({ error: "unauthorized" }, 401)
  const raw = await readRawBody(request, MAX_BODY)
  if (!raw.ok) return json({ error: raw.message }, raw.status)
  let body: { subscription?: unknown } = {}
  if (raw.text.trim()) {
    try {
      body = JSON.parse(raw.text) as { subscription?: unknown }
    } catch {
      return json({ error: "body must be JSON" }, 400)
    }
    if (!body || typeof body !== "object" || Array.isArray(body)) return json({ error: "body must be a JSON object" }, 400)
  }
  if (body.subscription !== undefined && (typeof body.subscription !== "string" || !/^sub_[A-Za-z0-9]{1,64}$/.test(body.subscription))) return json({ error: "subscription must be a subscription id" }, 400)
  const { syncUsage } = await import("./billing-usage-sync.ts")
  const report = await syncUsage(env, typeof body.subscription === "string" ? { subscription: body.subscription } : undefined).catch((e: unknown) => {
    console.error(JSON.stringify({ msg: "billing.usage_sync.run_failed", error: String(e).slice(0, 200) }))
    return null
  })
  if (!report) return json({ error: "the usage sync failed; retry", retryable: true }, 503)
  return json(report, report.refused && report.refused !== "no_key" ? 409 : 200)
}
