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
 * (web/services/billing/chiefPricing.ts), so no Stripe Product or Price object is made. Live keys and
 * real prices are Lawrence's decision (the live plan comes from web billing's cmuxPlan).
 *
 * After payment (#25574): the return page and the payment service's webhook (credits-routes.ts) share
 * `grantPlanSession` (only where that webhook is configured, since it is what takes a cancelled plan
 * back). A paid test session becomes the team's test plan grant in TeamDO
 * (inference/plan.ts), which the plan reads honor at once, so the limit lifts without a restart. When
 * the link was made by a Chief, its conversation gets one "[billing]" note (`plan:<session>`) that
 * starts a turn: the Chief says the plan is on and redoes the step that needed it.
 */
export const PLAN_KIND = "cmux_plan"
const LINK_TTL_MS = 7 * 24 * 3600_000
const TEAM = /^team_[0-9a-f]{20}$/
const ID = /^[A-Za-z0-9_-]{1,80}$/

/** The Chief conversation that sent a link, to be told when the plan is on. */
export interface PlanAsker {
  readonly chief: string
  readonly conversation: string
}

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
export const planLink = async (env: Env, origin: string, team: string, plan: string, asker?: PlanAsker, now = Date.now()): Promise<string | null> => {
  const key = env.BILLING_LEVELS_KEY
  if (!key || key.length < 32 || !TEAM.test(team) || !Object.hasOwn(UPSELL_PLANS, plan) || !creditsKey(env).ok) return null
  if (asker && (!ID.test(asker.chief) || !ID.test(asker.conversation))) return null
  const payload = b64url(JSON.stringify({ t: team, p: plan, e: now + LINK_TTL_MS, ...(asker ? { a: asker.chief, c: asker.conversation } : {}) }))
  return `${origin.replace(/\/$/, "")}/v1/billing/plan/${payload}.${await hmacHex(key, `plan-link:${payload}`)}`
}

/** The team, plan and asking Chief a link names, or null (bad signature, expired, malformed). */
export const planOfLink = async (env: Env, token: string, now = Date.now()): Promise<{ team: string; plan: string; asker?: PlanAsker } | null> => {
  const key = env.BILLING_LEVELS_KEY
  const [payload, sig] = token.split(".")
  if (!key || key.length < 32 || !payload || !sig) return null
  if (!timingSafeEqual(sig, await hmacHex(key, `plan-link:${payload}`))) return null
  try {
    const v = JSON.parse(unb64url(payload)) as { t?: unknown; p?: unknown; e?: unknown; a?: unknown; c?: unknown }
    if (!(typeof v.t === "string" && TEAM.test(v.t) && typeof v.p === "string" && Object.hasOwn(UPSELL_PLANS, v.p) && typeof v.e === "number" && v.e > now)) return null
    const asker = typeof v.a === "string" && ID.test(v.a) && typeof v.c === "string" && ID.test(v.c) ? { chief: v.a, conversation: v.c } : undefined
    return { team: v.t, plan: v.p, ...(asker ? { asker } : {}) }
  } catch {
    return null
  }
}

export const PLAN_PATH = /^\/v1\/billing\/plan\/(done|cancelled|[A-Za-z0-9_-]{8,400}\.[0-9a-f]{64})$/

type Session = { id?: string; livemode?: boolean; mode?: string; status?: string; payment_status?: string; currency?: string; amount_total?: number; amount_subtotal?: number; subscription?: string | { id: string } | null; metadata?: Record<string, string> | null }

export type PlanGrant = { ok: true; team: string; plan: string; added: boolean } | { ok: false; reason: string }

/** The note that tells the asking Chief the plan is on (its own words, never the person's). */
export const planGrantedNote = (plan: string): string => {
  const name = UPSELL_PLANS[plan]?.name ?? plan
  return `[billing] ${name} is on for this account now: the person paid on the checkout page you sent (test mode, no real charge). Tell them in one line that ${name} is on, then redo the step that needed it (the one that answered plan.required) yourself, without asking. (A billing notice from cmux, not the person's word now.)`
}

/**
 * A paid test-mode plan session becomes the team's plan grant once (TeamDO.grantTestPlan), and its
 * Chief, when a Chief's link made it, is told. Anything else (a credits session, a live or unpaid
 * session, another amount, production) grants nothing.
 */
export const grantPlanSession = async (env: Env, s: Session): Promise<PlanGrant> => {
  const m = s.metadata ?? {}
  if (!s.id || m.app !== "cmux" || m.kind !== PLAN_KIND || !m.team || !TEAM.test(m.team) || !m.plan || !Object.hasOwn(UPSELL_PLANS, m.plan) || s.mode !== "subscription") return { ok: false, reason: "not_a_plan_session" }
  if (s.livemode !== false || !creditsKey(env).ok) return { ok: false, reason: "not_test_mode" }
  // Only the webhook can take a grant back (customer.subscription.deleted): without it, grant nothing.
  if (!env.STRIPE_CREDITS_WEBHOOK_SECRET) return { ok: false, reason: "no_webhook" }
  if (s.status !== "complete" || s.payment_status !== "paid") return { ok: false, reason: "not_paid" }
  // The plan's price, and only when nothing changed it (a discount or tax would make the two differ).
  const cents = UPSELL_PLANS[m.plan]!.usd * 100
  if (s.currency !== "usd" || s.amount_total !== cents || s.amount_subtotal !== cents) return { ok: false, reason: "bad_amount" }
  const subscription = typeof s.subscription === "string" ? s.subscription : s.subscription?.id
  if (!subscription || !/^sub_[A-Za-z0-9_]{1,200}$/.test(subscription)) return { ok: false, reason: "no_subscription" }
  const team = env.TEAM_DO.get(env.TEAM_DO.idFromName(m.team)) as unknown as { grantTestPlan(plan: string, session: string, subscription: string): Promise<{ added: boolean; revoked: boolean } | { refused: string }> }
  const r = await team.grantTestPlan(m.plan, s.id, subscription)
  if ("refused" in r) return { ok: false, reason: r.refused }
  if (r.revoked) return { ok: false, reason: "revoked" }
  if (r.added) console.log(JSON.stringify({ msg: "plan.test_grant", team: m.team, plan: m.plan, session: s.id }))
  // The brain keys the note by session, so the webhook and the return page tell the Chief once.
  if (m.chief && ID.test(m.chief) && m.conversation && ID.test(m.conversation)) {
    // `${chief}/${conversation}` is brain-do.ts brainName (not imported: brain-do imports this module's users).
    const brain = env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(`${m.chief}/${m.conversation}`)) as unknown as { chiefPlan(n: PlanNotice): Promise<{ ok: boolean }> }
    await brain.chiefPlan({ session: s.id, team: m.team, plan: m.plan, chief: m.chief, conversation: m.conversation }).catch((e: unknown) => console.warn(JSON.stringify({ msg: "plan.chief_note_failed", error: String(e).slice(0, 160) })))
  }
  return { ok: true, team: m.team, plan: m.plan, added: r.added }
}

/** What a granted plan tells the Chief that sent its link (ChiefBrainDO.chiefPlan). */
export interface PlanNotice {
  readonly session: string
  readonly team: string
  readonly plan: string
  readonly chief: string
  readonly conversation: string
}

/** customer.subscription.deleted of a plan subscription: its team's test grant goes. */
export const revokePlanSubscription = async (env: Env, sub: { id?: string; metadata?: Record<string, string> | null }): Promise<boolean> => {
  const m = sub.metadata ?? {}
  if (!sub.id || m.app !== "cmux" || m.kind !== PLAN_KIND || !m.team || !TEAM.test(m.team)) return false
  const team = env.TEAM_DO.get(env.TEAM_DO.idFromName(m.team)) as unknown as { revokeTestPlan(subscription: string): Promise<boolean> }
  return team.revokeTestPlan(sub.id)
}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)
const page = (title: string, body: string, status = 200) =>
  new Response(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${esc(title)}</title><body style="font:16px -apple-system,system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1rem"><h1 style="font-size:1.4rem">${esc(title)}</h1><p>${esc(body)}</p></body>`, {
    status,
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" }
  })

/** GET /v1/billing/plan/<link>: 303 to a Stripe Checkout page (subscription, test mode); done and cancelled pages. User-facing text names no vendor. */
export const handlePlanCheckout = async (request: Request, env: Env, sub: string): Promise<Response> => {
  if (request.method !== "GET") return page("Not found", "This page does not exist.", 405)
  if (sub === "cancelled") return page("No payment made", "Nothing was charged. You can close this page.")
  const key = creditsKey(env)
  if (!key.ok) return page("Billing unavailable", `Plans cannot be bought on this deployment yet. See ${PRICING_URL}.`, 503)
  if (sub === "done") {
    const id = new URL(request.url).searchParams.get("session_id") ?? ""
    const r: PlanGrant = /^cs_test_[A-Za-z0-9]{1,200}$/.test(id)
      ? await stripeFetch(key.key, "GET", `/v1/checkout/sessions/${id}`)
          .then((s) => grantPlanSession(env, s as Session))
          .catch((e: unknown) => ({ ok: false as const, reason: String(e).slice(0, 120) }))
      : { ok: false, reason: "bad_session" }
    if (!r.ok) {
      console.warn(JSON.stringify({ msg: "plan.return_not_granted", reason: r.reason }))
      if (r.reason === "revoked") return page("Plan cancelled", "This plan was cancelled after this payment. Ask your Chief for a new link to start it again.", 410)
      return page("Payment not confirmed yet", r.reason === "not_paid" ? "Your payment is still processing. The plan turns on when it completes." : "We could not confirm this payment. If you paid, the plan turns on shortly.", r.reason === "not_paid" ? 202 : 400)
    }
    return page(`${UPSELL_PLANS[r.plan]!.name} is on`, "This is a test-mode checkout: no real charge was made. Your Chief picks up where it stopped. You can close this page.")
  }
  const link = await planOfLink(env, sub)
  if (!link) return page("Link expired", "This plan link is no longer valid. Ask your Chief again for a new one.", 404)
  const plan = UPSELL_PLANS[link.plan]!
  const base = new URL(request.url).origin
  const meta = { app: "cmux", kind: PLAN_KIND, team: link.team, plan: link.plan, ...(link.asker ? { chief: link.asker.chief, conversation: link.asker.conversation } : {}) }
  const form: Record<string, string> = {
    mode: "subscription",
    "line_items[0][quantity]": "1",
    "line_items[0][price_data][currency]": "usd",
    "line_items[0][price_data][unit_amount]": String(plan.usd * 100),
    "line_items[0][price_data][recurring][interval]": "month",
    "line_items[0][price_data][product_data][name]": plan.name,
    success_url: `${base}/v1/billing/plan/done?session_id={CHECKOUT_SESSION_ID}`,
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
