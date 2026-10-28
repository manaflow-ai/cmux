import { Effect } from "effect"
import { makeCredits } from "./credits.ts"
import { creditsKey, topupAmounts, topupRange } from "./credits-checkout.ts"
import { personalTeamIdFor } from "./domains/user.ts"
import type { Env } from "./env.ts"
import { callerOf } from "./home-attachments.ts"
import { planLink, PRICING_URL, UPSELL_PLANS } from "./plan-checkout.ts"
import { teamUsageLine } from "./team-ai-usage.ts"

/**
 * GET /v1/billing/summary: the console's billing page (plans/cmux-next/paid-plans-DESIGN.md §3).
 * One read for the caller's current team: the plan (TeamDO's plan copy), this period's AI usage
 * against the included amount, the prepaid credits balance, the plans above the current one with a
 * signed test-mode checkout link, and where the subscription is managed (cmux.com, whose Stripe
 * portal holds card, invoices and cancel). Test mode only: no link is made without a test key.
 */
export const BILLING_SUMMARY_PATH = "/v1/billing/summary"

/** Where a person changes or cancels the subscription and reads invoices. */
export const MANAGE_URL = "https://cmux.com/dashboard/billing"

/** Display names of every plan id the Worker can see (web billing's ids). */
const PLAN_NAMES: Readonly<Record<string, string>> = { go: "cmux Go", pro: "cmux Pro", max: "cmux Max", team: "cmux Team", founders: "cmux Founders" }
/** Upgrade order: a plan offers only the upsell plans after it. */
const RANK: Readonly<Record<string, number>> = { go: 1, pro: 2, founders: 2, max: 3, team: 3 }

const NO_STORE = { "cache-control": "no-store" }
const fail = (status: number, code: string, message: string, extra?: Record<string, unknown>) =>
  Response.json({ ok: false, error: { code, message, ...extra } }, { status, headers: NO_STORE })

/** The paid plan id (null: free), or undefined when the plan service did not answer. */
const planOf = async (env: Env, team: string, user: string, stackUser: string | undefined): Promise<string | null | undefined> => {
  const personal = team === personalTeamIdFor(user)
  const stack = personal ? (stackUser ?? (await env.USER_DO.get(env.USER_DO.idFromName(user)).stackUserOf(user)) ?? undefined) : undefined
  if (personal && !stack) return null
  const answer = await env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).inferencePlan(team, user, stack).catch(() => ({ ok: false as const }))
  if (!answer.ok) return undefined
  return answer.paid ? (answer.plan ?? null) : null
}

export const handleBillingSummary = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "GET") return fail(405, "method_not_allowed", "GET")
  const caller = await callerOf(request, env, "read")
  if ("status" in caller) return fail(caller.status, caller.code, caller.message, caller.extra)
  const user = caller.user
  const team = caller.principal.team ?? personalTeamIdFor(user)
  const origin = env.CLOUD_API_ORIGIN || new URL(request.url).origin
  const testMode = creditsKey(env).ok

  const plan = await planOf(env, team, user, caller.principal.stack_user_id)
  const known = plan !== undefined
  const id = plan ?? null
  const [usage, credits] = await Promise.all([
    id ? teamUsageLine(env, team, id).catch(() => null) : Promise.resolve(null),
    Effect.runPromise(makeCredits(env).balance(team).pipe(Effect.orElseSucceed(() => null)))
  ])
  const rank = id ? (RANK[id] ?? 0) : 0
  const upgrade = await Promise.all(
    Object.entries(UPSELL_PLANS)
      .filter(([plan]) => (RANK[plan] ?? 0) > rank)
      .map(async ([plan, p]) => ({ id: plan, name: p.name, usd: p.usd, checkout_url: testMode ? await planLink(env, origin, team, plan) : null }))
  )
  return Response.json(
    {
      ok: true,
      value: {
        team,
        personal: team === personalTeamIdFor(user),
        plan: { id, name: id ? (PLAN_NAMES[id] ?? id) : "Free", paid: id !== null, ...(known ? {} : { unavailable: true }) },
        usage: usage && {
          included_usd: usage.included_usd,
          spent_usd: usage.spent_usd,
          period_start: usage.period_start,
          period_end: usage.period_end,
          billed: usage.billed,
          stopped: usage.stopped
        },
        credits: credits && {
          available_usd: credits.available_usd,
          balance_usd: credits.balance_usd,
          held_usd: credits.held_usd,
          entries: credits.entries.slice(0, 10).map((e) => ({ kind: e.kind, usd: e.usd, at: e.at })),
          topup_amounts_usd: testMode ? topupAmounts(env) : [],
          topup_min_usd: topupRange(env).min,
          topup_max_usd: topupRange(env).max
        },
        upgrade,
        manage_url: MANAGE_URL,
        pricing_url: PRICING_URL,
        test_mode: testMode
      }
    },
    { headers: NO_STORE }
  )
}
