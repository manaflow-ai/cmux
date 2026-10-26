import { Effect } from "effect"
import { makeCredits } from "./credits.ts"
import { createCheckout, creditsKey, grantPaidSession, grantSessionById, teamOfLink, topupAmounts, topupLink, verifyWebhook } from "./credits-checkout.ts"
import { personalTeamIdFor } from "./domains/user.ts"
import type { Env } from "./env.ts"
import { callerOf, type Fail } from "./home-attachments.ts"
import { readRawBody } from "./ingress/verify.ts"
import { grantPlanSession, PLAN_KIND, revokePlanSubscription } from "./plan-checkout.ts"

/**
 * Prepaid credits over HTTP (credits.ts, credits-checkout.ts). The team is the caller's current team
 * (its personal team unless the request names a shared one), as every Home route resolves it.
 *
 *   GET  /v1/credits                          a member: {team, balance_usd, held_usd, available_usd,
 *                                             chiefs: [{chief, spent_usd, calls, last_at}] (30 days),
 *                                             entries: newest 20, topup: {link, amounts_usd} | null}
 *   POST /v1/credits/topup {"usd": 20}        a member: {url} of a payment page for that amount
 *   GET  /v1/credits/checkout/<signed link>?usd=<n>   anyone with the link: 303 to the payment page
 *   GET  /v1/credits/checkout/done?session_id=...     the return page; grants a paid session once
 *   GET  /v1/credits/checkout/cancelled               the cancel page
 *   POST /v1/hooks/stripe/credits             the payment service's signed webhook (STRIPE_CREDITS_WEBHOOK_SECRET);
 *                                             it also grants a Chief's test plan checkout (plan-checkout.ts)
 *
 * User-facing text says "Cloud credits" and "billing", never a vendor name.
 */
export const CREDITS_PATH = /^\/v1\/credits(?:\/(topup|checkout\/done|checkout\/cancelled|checkout\/([A-Za-z0-9_-]{8,400}\.[0-9a-f]{64})))?$/
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
    const topup = creditsKey(env).ok ? { link: await topupLink(env, url.origin, who.team), amounts_usd: topupAmounts(env) } : null
    return ok({ ...balance, topup })
  }
  if (sub === "topup") {
    if (request.method !== "POST") return fail({ status: 405, code: "method_not_allowed", message: "POST" })
    const who = await callerTeam(request, env)
    if ("status" in who) return fail(who)
    const body = (await request.json().catch(() => null)) as { usd?: unknown } | null
    const amounts = topupAmounts(env)
    if (!body || typeof body.usd !== "number" || !amounts.includes(body.usd)) return fail({ status: 400, code: "validation.invalid", message: `usd: one of ${amounts.join(", ")}` })
    const key = creditsKey(env)
    if (!key.ok) return fail(unavailable(key.reason))
    const s = await createCheckout(env, key.key, url.origin, who.team, body.usd, who.user).catch((e: unknown) => (console.error(JSON.stringify({ msg: "credits.checkout_failed", error: String(e).slice(0, 200) })), null))
    if (!s) return fail({ status: 502, code: "billing.unavailable", message: "The billing service did not answer; retry", extra: { retryable: true } })
    return ok({ url: s.url, team: who.team, usd: body.usd })
  }
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
  if (!amounts.includes(usd)) return page("Pick an amount", `Choose one of ${amounts.join(", ")} USD.`, 400)
  const s = await createCheckout(env, key.key, url.origin, team, usd, "link", link).catch((e: unknown) => (console.error(JSON.stringify({ msg: "credits.checkout_failed", error: String(e).slice(0, 200) })), null))
  if (!s) return page("Billing unavailable", "The billing service did not answer. Try the link again in a minute.", 502)
  return Response.redirect(s.url, 303)
}

/**
 * checkout.session.completed and .async_payment_succeeded of a credits session grant it, of a plan
 * session (a Chief's upsell link) turn the test plan on; customer.subscription.deleted of a plan
 * subscription turns it off. Other events are acknowledged.
 */
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
  const object = event.data?.object ?? {}
  const kind = (object.metadata as Record<string, string> | null | undefined)?.kind
  if (event.type === "customer.subscription.deleted" && kind === PLAN_KIND) return Response.json({ received: true, revoked: await revokePlanSubscription(env, object as Parameters<typeof revokePlanSubscription>[1]) })
  if (event.type !== "checkout.session.completed" && event.type !== "checkout.session.async_payment_succeeded") return Response.json({ received: true })
  if (kind === PLAN_KIND) {
    const p = await grantPlanSession(env, object as Parameters<typeof grantPlanSession>[1])
    return Response.json({ received: true, granted: p.ok && p.added })
  }
  const r = await grantPaidSession(env, object as Parameters<typeof grantPaidSession>[1])
  return Response.json({ received: true, granted: r.ok && r.added })
}
