import { Effect } from "effect"
import { makeCredits } from "./credits.ts"
import { AUTORELOAD_KIND, savedCard } from "./credits-autoreload.ts"
import { createCheckout, creditsKey, grantPaidSession, grantSessionById, teamOfLink, topupAmounts, topupLink, topupRange, validTopup, verifyWebhook } from "./credits-checkout.ts"
import { personalTeamIdFor } from "./domains/user.ts"
import type { Env } from "./env.ts"
import { callerOf, type Fail } from "./home-attachments.ts"
import { readRawBody } from "./ingress/verify.ts"

/**
 * Prepaid credits over HTTP (credits.ts, credits-checkout.ts). The team is the caller's current team
 * (its personal team unless the request names a shared one), as every Home route resolves it.
 *
 *   GET  /v1/credits                          a member: {team, balance_usd, held_usd, available_usd,
 *                                             chiefs: [{chief, spent_usd, calls, last_at}] (30 days),
 *                                             entries: newest 20, topup: {link, amounts_usd} | null}
 *   POST /v1/credits/topup {"usd": 37.5}      a member: {url} of a payment page for any amount in the range
 *   GET|PUT /v1/credits/auto-reload           a member: the auto-reload settings (credits-autoreload.ts)
 *   GET  /v1/credits/checkout/<signed link>?usd=<n>   anyone with the link: 303 to the payment page
 *   GET  /v1/credits/checkout/done?session_id=...     the return page; grants a paid session once
 *   GET  /v1/credits/checkout/cancelled               the cancel page
 *   POST /v1/hooks/stripe/credits             the payment service's signed webhook (STRIPE_CREDITS_WEBHOOK_SECRET)
 *
 * User-facing text says "Cloud credits" and "billing", never a vendor name.
 */
export const CREDITS_PATH = /^\/v1\/credits(?:\/(topup|auto-reload|checkout\/done|checkout\/cancelled|checkout\/([A-Za-z0-9_-]{8,400}\.[0-9a-f]{64})))?$/
export const CREDITS_WEBHOOK_PATH = "/v1/hooks/stripe/credits"

const NO_STORE = { "cache-control": "no-store" }
const fail = (f: Fail) => Response.json({ ok: false, error: { code: f.code, message: f.message, ...f.extra } }, { status: f.status, headers: NO_STORE })
const ok = (value: unknown) => Response.json({ ok: true, value }, { headers: NO_STORE })
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)
const page = (title: string, body: string, status = 200) =>
  new Response(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${esc(title)}</title><body style="font:16px -apple-system,system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1rem"><h1 style="font-size:1.4rem">${esc(title)}</h1><p>${esc(body)}</p></body>`, {
    status,
    headers: { "content-type": "text/html; charset=utf-8", ...NO_STORE }
  })

const unavailable = (reason: string) => {
  console.warn(JSON.stringify({ msg: "credits.billing_unavailable", reason }))
  return { status: 503, code: "billing.unavailable", message: "Billing is not available on this deployment yet" }
}

const callerTeam = async (request: Request, env: Env) => {
  const caller = await callerOf(request, env, "read")
  if ("status" in caller) return caller
  return { team: caller.principal.team ?? personalTeamIdFor(caller.user), user: caller.user }
}

export const handleCredits = async (request: Request, env: Env, sub: string | undefined, link: string | undefined): Promise<Response> => {
  const url = new URL(request.url)
  if (sub === undefined) {
    if (request.method !== "GET") return fail({ status: 405, code: "method_not_allowed", message: "GET" })
    const who = await callerTeam(request, env)
    if ("status" in who) return fail(who)
    const balance = await Effect.runPromise(makeCredits(env).balance(who.team).pipe(Effect.orElseSucceed(() => null)))
    if (!balance) return fail({ status: 503, code: "owner.unreachable", message: "the balance could not be read; retry", extra: { retryable: true } })
    const topup = creditsKey(env).ok ? { link: await topupLink(env, url.origin, who.team), amounts_usd: topupAmounts(env), min_usd: topupRange(env).min, max_usd: topupRange(env).max } : null
    return ok({ ...balance, topup })
  }
  if (sub === "topup") {
    if (request.method !== "POST") return fail({ status: 405, code: "method_not_allowed", message: "POST" })
    const who = await callerTeam(request, env)
    if ("status" in who) return fail(who)
    const body = (await request.json().catch(() => null)) as { usd?: unknown } | null
    const range = topupRange(env)
    if (!body || !validTopup(env, body.usd)) return fail({ status: 400, code: "validation.invalid", message: `usd: an amount from ${range.min} to ${range.max} USD, whole cents` })
    const key = creditsKey(env)
    if (!key.ok) return fail(unavailable(key.reason))
    const s = await createCheckout(env, key.key, url.origin, who.team, body.usd, who.user).catch((e: unknown) => (console.error(JSON.stringify({ msg: "credits.checkout_failed", error: String(e).slice(0, 200) })), null))
    if (!s) return fail({ status: 502, code: "billing.unavailable", message: "The billing service did not answer; retry", extra: { retryable: true } })
    return ok({ url: s.url, team: who.team, usd: body.usd })
  }
  if (sub === "auto-reload") return handleAutoReload(request, env)
  if (request.method !== "GET") return page("Not found", "This page does not exist.", 405)
  if (sub === "checkout/cancelled") return page("No payment made", "Nothing was charged. You can close this page.")
  const key = creditsKey(env)
  if (!key.ok) return (unavailable(key.reason), page("Billing unavailable", "Cloud credits cannot be bought on this deployment yet.", 503))
  if (sub === "checkout/done") {
    const r = await grantSessionById(env, key.key, url.searchParams.get("session_id") ?? "").catch((e: unknown) => ({ ok: false as const, reason: String(e).slice(0, 120) }))
    if (!r.ok) {
      console.warn(JSON.stringify({ msg: "credits.return_not_granted", reason: r.reason }))
      return page("Payment not confirmed yet", r.reason === "not_paid" ? "Your payment is still processing. Credits appear when it completes." : "We could not confirm this payment. If you were charged, credits appear shortly.", r.reason === "not_paid" ? 202 : 400)
    }
    return page("Credits added", `${r.usd.toFixed(2)} USD of Cloud credits are on your team. Balance: ${r.balance_usd.toFixed(2)} USD. You can close this page.`)
  }
  // A signed link from a notice or the balance read.
  const team = link ? await teamOfLink(env, link) : null
  if (!team) return page("Link expired", "This top-up link is no longer valid. Ask your Chief again for a new one.", 404)
  const amounts = topupAmounts(env)
  const usd = url.searchParams.has("usd") ? Number(url.searchParams.get("usd")) : (amounts.includes(20) ? 20 : amounts[0]!)
  if (!validTopup(env, usd)) return page("Pick an amount", `Choose an amount from ${topupRange(env).min} to ${topupRange(env).max} USD.`, 400)
  const s = await createCheckout(env, key.key, url.origin, team, usd, "link", link).catch((e: unknown) => (console.error(JSON.stringify({ msg: "credits.checkout_failed", error: String(e).slice(0, 200) })), null))
  if (!s) return page("Billing unavailable", "The billing service did not answer. Try the link again in a minute.", 502)
  return Response.redirect(s.url, 303)
}

/** checkout.session.completed and .async_payment_succeeded of a credits session grant it; other events are acknowledged. */
export const handleCreditsWebhook = async (request: Request, env: Env): Promise<Response> => {
  const secret = env.STRIPE_CREDITS_WEBHOOK_SECRET
  if (!secret) return Response.json({ error: "not found" }, { status: 404 })
  if (request.method !== "POST") return Response.json({ error: "method not allowed" }, { status: 405 })
  const raw = await readRawBody(request, 256 * 1024)
  if (!raw.ok) return Response.json({ error: raw.message }, { status: raw.status })
  if (!(await verifyWebhook(secret, request.headers.get("stripe-signature"), raw.text))) return Response.json({ error: "bad signature" }, { status: 400 })
  const event = JSON.parse(raw.text) as { type?: string; livemode?: boolean; data?: { object?: Record<string, unknown> } }
  if (event.livemode === true) {
    console.warn(JSON.stringify({ msg: "credits.webhook_live_refused" }))
    return Response.json({ received: true, granted: false })
  }
  // An auto-reload charge whose answer the DO never saw grants here, once (the same key as the DO's grant).
  if (event.type === "payment_intent.succeeded") {
    const pi = (event.data?.object ?? {}) as { id?: string; amount_received?: number; currency?: string; metadata?: Record<string, string> }
    const m = pi.metadata ?? {}
    if (m.app !== "cmux" || m.kind !== AUTORELOAD_KIND || !m.team || !/^team_[0-9a-f]{20}$/.test(m.team) || !pi.id || pi.currency !== "usd" || !(Number(pi.amount_received) > 0)) return Response.json({ received: true })
    const r = await env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(m.team)).creditAdd(m.team, `autoreload:${pi.id}`, "topup", Number(pi.amount_received) * 10_000, "auto-reload", null)
    return Response.json({ received: true, granted: r.added })
  }
  if (event.type !== "checkout.session.completed" && event.type !== "checkout.session.async_payment_succeeded") return Response.json({ received: true })
  const r = await grantPaidSession(env, (event.data?.object ?? {}) as Parameters<typeof grantPaidSession>[1])
  return Response.json({ received: true, granted: r.ok && r.added })
}

const toMicros = (usd: number) => Math.round(usd * 1_000_000)
const isUsd = (v: unknown, min: number, max: number): v is number => typeof v === "number" && Number.isFinite(v) && v >= min && v <= max && Math.abs(Math.round(v * 100) - v * 100) < 1e-6

/** GET|PUT /v1/credits/auto-reload (paid-plans-DESIGN.md §6.3). */
const handleAutoReload = async (request: Request, env: Env): Promise<Response> => {
  const who = await callerTeam(request, env)
  if ("status" in who) return fail(who)
  const meter = env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(who.team))
  const answer = async () => {
    const s = await meter.autoReloadGet(who.team)
    return ok({
      team: who.team,
      enabled: s?.enabled ?? false,
      threshold_usd: s ? s.threshold_micros / 1_000_000 : null,
      amount_usd: s ? s.amount_micros / 1_000_000 : null,
      monthly_cap_usd: s ? s.monthly_cap_micros / 1_000_000 : null,
      month_reloaded_usd: s ? s.month_reloaded_micros / 1_000_000 : 0,
      last_error: s?.last_error ?? null,
      last_error_at: s?.last_error_at ?? null
    })
  }
  if (request.method === "GET") return answer()
  if (request.method !== "PUT") return fail({ status: 405, code: "method_not_allowed", message: "GET, PUT" })
  const body = (await request.json().catch(() => null)) as { enabled?: unknown; threshold_usd?: unknown; amount_usd?: unknown; monthly_cap_usd?: unknown } | null
  const range = topupRange(env)
  if (!body || typeof body.enabled !== "boolean") return fail({ status: 400, code: "validation.invalid", message: "enabled: true or false" })
  if (!isUsd(body.threshold_usd, 0, range.max)) return fail({ status: 400, code: "validation.invalid", message: `threshold_usd: 0 to ${range.max} USD` })
  if (!validTopup(env, body.amount_usd)) return fail({ status: 400, code: "validation.invalid", message: `amount_usd: ${range.min} to ${range.max} USD, whole cents` })
  if (!isUsd(body.monthly_cap_usd, body.amount_usd, range.max * 20)) return fail({ status: 400, code: "validation.invalid", message: `monthly_cap_usd: at least amount_usd, at most ${range.max * 20} USD` })
  if (body.enabled) {
    const key = creditsKey(env)
    if (!key.ok) return fail(unavailable(key.reason))
    const customer = await meter.creditCustomer(who.team, "test")
    const card = customer ? await savedCard(key.key, customer).catch(() => null) : null
    if (!card) return fail({ status: 409, code: "credits.no_saved_card", message: "Add credits once with a card first; auto-reload charges that saved card", extra: { topup_path: "/v1/credits/topup" } })
  }
  await meter.autoReloadSet(who.team, { enabled: body.enabled, threshold_micros: toMicros(body.threshold_usd), amount_micros: toMicros(body.amount_usd), monthly_cap_micros: toMicros(body.monthly_cap_usd) }, who.user)
  return answer()
}
