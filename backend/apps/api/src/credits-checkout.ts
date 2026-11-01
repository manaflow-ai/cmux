import type { Env } from "./env.ts"
import { stripeFetch, stripeKeyMode } from "./billing-usage-sync.ts"
import { hmacHex, timingSafeEqual } from "./ingress/verify.ts"

/**
 * Credit top-ups through the existing billing (the API Worker's payment service client, the one the
 * usage sync uses, billing-usage-sync.ts): a one-time Checkout payment whose paid amount becomes
 * credits on the team's UsageMeterDO, once per Checkout session (`topup:<session id>`).
 *
 * Grants happen on two paths that share `grantPaidSession`: the payment service's webhook
 * (credits-routes.ts, signed) and the return page after payment (it reads the session back from the
 * payment service, so a top-up lands even where no webhook is configured). Either path may run
 * first; the second counts nothing.
 *
 * Test mode only in this phase: a live key is refused before any call (live products, prices and
 * charges are Lawrence's decision). Key: STRIPE_CREDITS_KEY, else STRIPE_USAGE_KEY.
 */
export const CREDITS_KIND = "cmux_credits"
/** The product line on the payment page (no vendor names). */
export const CREDITS_PRODUCT_NAME = "cmux Cloud credits"
const LINK_TTL_MS = 7 * 24 * 3600_000
const TEAM = /^team_[0-9a-f]{20}$/

export const creditsKey = (env: Env): { ok: true; key: string } | { ok: false; reason: string } => {
  const key = env.STRIPE_CREDITS_KEY || env.STRIPE_USAGE_KEY
  const mode = stripeKeyMode(key)
  // A test-mode payment (the public test card) must never buy real model spend on production.
  if (mode === "test" && env.ENVIRONMENT === "production") return { ok: false, reason: "test_key_on_production" }
  if (mode === "test") return { ok: true, key: key! }
  return { ok: false, reason: mode === "live" ? "live_key_refused" : mode === "none" ? "no_key" : "invalid_key" }
}

/** The top-up range (paid-plans-DESIGN.md §6.2): CREDITS_TOPUP_MIN_USD and CREDITS_TOPUP_MAX_USD, defaults 5 and 2,500. */
export const topupRange = (env: Env): { min: number; max: number } => {
  const min = Number(env.CREDITS_TOPUP_MIN_USD ?? 5)
  const max = Number(env.CREDITS_TOPUP_MAX_USD ?? 2500)
  return Number.isFinite(min) && Number.isFinite(max) && min >= 1 && max >= min && max <= 100_000 ? { min, max } : { min: 5, max: 2500 }
}

/** Any amount in the range with at most two decimals (whole cents). */
export const validTopup = (env: Env, usd: unknown): usd is number => {
  if (typeof usd !== "number" || !Number.isFinite(usd)) return false
  const { min, max } = topupRange(env)
  return usd >= min && usd <= max && Math.abs(Math.round(usd * 100) - usd * 100) < 1e-6
}

/** CHIEF_CREDITS_TOPUP_USD: the amounts a person may pick (whole USD), default 10, 20, 50, 100. */
export const topupAmounts = (env: Env): ReadonlyArray<number> => {
  const list = (env.CHIEF_CREDITS_TOPUP_USD ?? "10,20,50,100").split(",").map((v) => Number(v.trim())).filter((n) => Number.isInteger(n) && n >= 1 && n <= 10_000)
  return list.length > 0 ? list : [10, 20, 50, 100]
}

const b64url = (s: string) => btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const unb64url = (s: string) => atob(s.replace(/-/g, "+").replace(/_/g, "/"))

/**
 * A top-up link for a team (the brain's out-of-credits notice, the balance read): signed with
 * BILLING_LEVELS_KEY so nobody can make payment pages for a team id they guessed. Anyone who has the
 * link can pay into that team, which is the point of sharing it. Null without a key.
 */
export const topupLink = async (env: Env, origin: string, team: string, now = Date.now()): Promise<string | null> => {
  const key = env.BILLING_LEVELS_KEY
  if (!key || key.length < 32 || !TEAM.test(team)) return null
  const payload = b64url(JSON.stringify({ t: team, e: now + LINK_TTL_MS }))
  return `${origin.replace(/\/$/, "")}/v1/credits/checkout/${payload}.${await hmacHex(key, `credits-link:${payload}`)}`
}

/** The team a signed link names, or null (bad signature, expired, malformed). */
export const teamOfLink = async (env: Env, token: string, now = Date.now()): Promise<string | null> => {
  const key = env.BILLING_LEVELS_KEY
  const [payload, sig] = token.split(".")
  if (!key || key.length < 32 || !payload || !sig) return null
  if (!timingSafeEqual(sig, await hmacHex(key, `credits-link:${payload}`))) return null
  try {
    const v = JSON.parse(unb64url(payload)) as { t?: unknown; e?: unknown }
    return typeof v.t === "string" && TEAM.test(v.t) && typeof v.e === "number" && v.e > now ? v.t : null
  } catch {
    return null
  }
}

/**
 * A Checkout session for `usd` of credits for `team`. `once` (a link click) repeats its idempotency
 * key for ten minutes, so clicking the same link again reuses the payment page instead of making
 * new ones; an explicit request (`once` undefined) always gets a new page.
 */
export const createCheckout = async (env: Env, key: string, origin: string, team: string, usd: number, by: string, once?: string, now = Date.now()): Promise<{ id: string; url: string }> => {
  const cents = Math.round(usd * 100)
  const base = origin.replace(/\/$/, "")
  const meta = { app: "cmux", kind: CREDITS_KIND, team, by }
  // One payment-service customer per team: reuse the one the team's first paid top-up made.
  const meter = env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(team))
  const customer = await meter.creditCustomer(team, stripeKeyMode(key) === "live" ? "live" : "test")
  const form: Record<string, string> = {
    mode: "payment",
    ...(customer ? { customer } : { customer_creation: "always" }),
    // One tap next time (paid-plan.md §5) and auto-reload (paid-plans-DESIGN.md §6.3): the card is saved on the
    // team's customer for off-session use, and a later top-up
    // shows it (cards saved this way are "limited" redisplay, which Checkout hides unless asked).
    "payment_intent_data[setup_future_usage]": "off_session",
    ...(customer ? { "saved_payment_method_options[allow_redisplay_filters][0]": "always", "saved_payment_method_options[allow_redisplay_filters][1]": "limited", "saved_payment_method_options[allow_redisplay_filters][2]": "unspecified" } : {}),
    "line_items[0][quantity]": "1",
    "line_items[0][price_data][currency]": "usd",
    "line_items[0][price_data][unit_amount]": String(cents),
    ...(env.CHIEF_CREDITS_PRODUCT ? { "line_items[0][price_data][product]": env.CHIEF_CREDITS_PRODUCT } : { "line_items[0][price_data][product_data][name]": CREDITS_PRODUCT_NAME }),
    success_url: `${base}/v1/credits/checkout/done?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${base}/v1/credits/checkout/cancelled`,
    client_reference_id: team,
    ...Object.fromEntries(Object.entries(meta).flatMap(([k, v]) => [[`metadata[${k}]`, v], [`payment_intent_data[metadata][${k}]`, v]]))
  }
  const s = (await stripeFetch(key, "POST", "/v1/checkout/sessions", form, once ? `cmux-credits:${team}:${cents}:${customer ?? "new"}:${once.slice(-32)}:${Math.floor(now / 600_000)}` : `cmux-credits:${crypto.randomUUID()}`)) as { id: string; url: string }
  return { id: s.id, url: s.url }
}

type Session = { id?: string; livemode?: boolean; customer?: string | { id: string } | null; payment_status?: string; status?: string; currency?: string; amount_subtotal?: number; amount_total?: number; metadata?: Record<string, string> | null; mode?: string }

export type GrantResult = { ok: true; team: string; added: boolean; usd: number; balance_usd: number } | { ok: false; reason: string }

/** A paid credits session becomes credits once (`topup:<session id>`). Anything else grants nothing. */
export const grantPaidSession = async (env: Env, s: Session): Promise<GrantResult> => {
  const m = s.metadata ?? {}
  if (!s.id || m.app !== "cmux" || m.kind !== CREDITS_KIND || !m.team || !TEAM.test(m.team) || s.mode !== "payment") return { ok: false, reason: "not_a_credits_session" }
  if (s.payment_status !== "paid") return { ok: false, reason: "not_paid" }
  // The amount paid, and only when nothing changed it (a discount or tax would make the two differ).
  if (s.currency !== "usd" || typeof s.amount_total !== "number" || s.amount_total <= 0 || s.amount_total !== s.amount_subtotal) return { ok: false, reason: "bad_amount" }
  const micros = s.amount_total * 10_000
  const meter = env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(m.team))
  const r = await meter.creditAdd(m.team, `topup:${s.id}`, "topup", micros, m.by ?? "checkout", null)
  // The team's customer (made by its first top-up) is kept for its next top-ups and the billing database.
  const customer = typeof s.customer === "string" ? s.customer : s.customer?.id
  if (customer && /^cus_[A-Za-z0-9]{1,200}$/.test(customer)) await meter.setCreditCustomer(m.team, s.livemode ? "live" : "test", customer)
  if (r.added) console.log(JSON.stringify({ msg: "credits.topup", team: m.team, session: s.id, usd: micros / 1_000_000, balance_usd: r.balance_micros / 1_000_000 }))
  return { ok: true, team: m.team, added: r.added, usd: micros / 1_000_000, balance_usd: r.balance_micros / 1_000_000 }
}

/** The return page's path: read the session back from the payment service, then grant. */
export const grantSessionById = async (env: Env, key: string, id: string): Promise<GrantResult> => {
  if (!/^cs_(test|live)_[A-Za-z0-9]{1,200}$/.test(id)) return { ok: false, reason: "bad_session" }
  const s = (await stripeFetch(key, "GET", `/v1/checkout/sessions/${id}`)) as Session
  return grantPaidSession(env, s)
}

/**
 * The webhook signature (`Stripe-Signature: t=<s>,v1=<hex>`): HMAC-SHA256 of `<t>.<raw body>` with
 * the endpoint secret, within five minutes of now.
 */
export const verifyWebhook = async (secret: string, header: string | null, body: string, now = Date.now()): Promise<boolean> => {
  if (!header) return false
  const parts = header.split(",").map((p) => p.split("=") as [string, string])
  const t = Number(parts.find(([k]) => k === "t")?.[1])
  if (!Number.isFinite(t) || Math.abs(now / 1000 - t) > 300) return false
  const expected = await hmacHex(secret, `${t}.${body}`)
  return parts.some(([k, v]) => k === "v1" && typeof v === "string" && timingSafeEqual(v, expected))
}
