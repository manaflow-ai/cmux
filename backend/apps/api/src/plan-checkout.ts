import { stripeFetch } from "./billing-usage-sync.ts"
import { creditsKey } from "./credits-checkout.ts"
import type { Env } from "./env.ts"
import { hmacHex, timingSafeEqual } from "./ingress/verify.ts"

/**
 * The Chief's upsell link (plans/cmux-next/chief-automations-DESIGN.md): when a request needs a paid
 * plan, the Chief sends one signed link; opening it makes a Stripe Checkout page for that plan and team.
 *
 * TEST MODE ONLY. The key is the credits key (creditsKey refuses a live key and a test key on
 * production), and the price is inline `price_data` from the cmux-next pricing proposal
 * (web/services/billing/chiefPricing.ts), so no Stripe Product or Price object is made. Live keys,
 * real prices and the plan grant after payment are Lawrence's decision; a paid test session grants
 * nothing yet (the live plan comes from web billing's cmuxPlan).
 */
export const PLAN_KIND = "cmux_plan"
const LINK_TTL_MS = 7 * 24 * 3600_000
const TEAM = /^team_[0-9a-f]{20}$/

/** The plans a Chief may offer, with the proposal's monthly price (USD). Team needs seats and an admin: cmux.com. */
export const UPSELL_PLANS: Readonly<Record<string, { readonly name: string; readonly usd: number }>> = {
  pro: { name: "cmux Pro", usd: 50 },
  max: { name: "cmux Max", usd: 200 }
}

/** Where a person can read the plans when no checkout link can be made. */
export const PRICING_URL = "https://cmux.com/pricing"

const b64url = (s: string) => btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const unb64url = (s: string) => atob(s.replace(/-/g, "+").replace(/_/g, "/"))

/** A signed checkout link for `plan` on `team`, or null (no signing key, no test key, bad input). */
export const planLink = async (env: Env, origin: string, team: string, plan: string, now = Date.now()): Promise<string | null> => {
  const key = env.BILLING_LEVELS_KEY
  if (!key || key.length < 32 || !TEAM.test(team) || !Object.hasOwn(UPSELL_PLANS, plan) || !creditsKey(env).ok) return null
  const payload = b64url(JSON.stringify({ t: team, p: plan, e: now + LINK_TTL_MS }))
  return `${origin.replace(/\/$/, "")}/v1/billing/plan/${payload}.${await hmacHex(key, `plan-link:${payload}`)}`
}

/** The team and plan a link names, or null (bad signature, expired, malformed). */
export const planOfLink = async (env: Env, token: string, now = Date.now()): Promise<{ team: string; plan: string } | null> => {
  const key = env.BILLING_LEVELS_KEY
  const [payload, sig] = token.split(".")
  if (!key || key.length < 32 || !payload || !sig) return null
  if (!timingSafeEqual(sig, await hmacHex(key, `plan-link:${payload}`))) return null
  try {
    const v = JSON.parse(unb64url(payload)) as { t?: unknown; p?: unknown; e?: unknown }
    return typeof v.t === "string" && TEAM.test(v.t) && typeof v.p === "string" && Object.hasOwn(UPSELL_PLANS, v.p) && typeof v.e === "number" && v.e > now ? { team: v.t, plan: v.p } : null
  } catch {
    return null
  }
}

export const PLAN_PATH = /^\/v1\/billing\/plan\/(done|cancelled|[A-Za-z0-9_-]{8,400}\.[0-9a-f]{64})$/

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)
const page = (title: string, body: string, status = 200) =>
  new Response(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${esc(title)}</title><body style="font:16px -apple-system,system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1rem"><h1 style="font-size:1.4rem">${esc(title)}</h1><p>${esc(body)}</p></body>`, {
    status,
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" }
  })

/** GET /v1/billing/plan/<link>: 303 to a Stripe Checkout page (subscription, test mode); done and cancelled pages. */
export const handlePlanCheckout = async (request: Request, env: Env, sub: string): Promise<Response> => {
  if (request.method !== "GET") return page("Not found", "This page does not exist.", 405)
  if (sub === "cancelled") return page("No payment made", "Nothing was charged. You can close this page.")
  if (sub === "done") return page("Thank you", "Stripe has your test payment. This is a test-mode page: no real plan was bought. You can close this page.")
  const key = creditsKey(env)
  if (!key.ok) return page("Billing unavailable", `Plans cannot be bought on this deployment yet. See ${PRICING_URL}.`, 503)
  const link = await planOfLink(env, sub)
  if (!link) return page("Link expired", "This plan link is no longer valid. Ask your Chief again for a new one.", 404)
  const plan = UPSELL_PLANS[link.plan]!
  const base = new URL(request.url).origin
  const meta = { app: "cmux", kind: PLAN_KIND, team: link.team, plan: link.plan }
  const form: Record<string, string> = {
    mode: "subscription",
    "line_items[0][quantity]": "1",
    "line_items[0][price_data][currency]": "usd",
    "line_items[0][price_data][unit_amount]": String(plan.usd * 100),
    "line_items[0][price_data][recurring][interval]": "month",
    "line_items[0][price_data][product_data][name]": plan.name,
    success_url: `${base}/v1/billing/plan/done`,
    cancel_url: `${base}/v1/billing/plan/cancelled`,
    client_reference_id: link.team,
    ...Object.fromEntries(Object.entries(meta).flatMap(([k, v]) => [[`metadata[${k}]`, v], [`subscription_data[metadata][${k}]`, v]]))
  }
  // A repeated click within ten minutes reuses the same page.
  const s = (await stripeFetch(key.key, "POST", "/v1/checkout/sessions", form, `cmux-plan:${link.team}:${link.plan}:${sub.slice(-32)}:${Math.floor(Date.now() / 600_000)}`).catch((e: unknown) => {
    console.error(JSON.stringify({ msg: "plan.checkout_failed", error: String(e).slice(0, 200) }))
    return null
  })) as { url?: string } | null
  if (!s?.url) return page("Billing unavailable", "The billing service did not answer. Try the link again in a minute.", 502)
  return Response.redirect(s.url, 303)
}
