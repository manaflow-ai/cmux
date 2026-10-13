import type { Env } from "../env.ts"
import { isUsagePlan, usageIncludedUsd, type UsagePlan } from "../billing-catalog.ts"
import { nextMonthStart } from "../usage-user.ts"
import { usagePriceSet } from "../billing-usage-sync.ts"

/**
 * The included-amount stop (cx-y79zh S5, plans/cmux-next/usage-billing.md; Lawrence 2026-10-13:
 * "Founders and Apple buyers: hard stop at the included amount, no card path"). A team that the usage
 * sync has not seen on a billable subscription (a usage item on an active monthly plan) cannot be billed
 * for usage above its plan's included amount, so its AI spend stops there each UTC month. This covers
 * Founders, App Store purchases, operator grants and any plan before its usage item exists. A billable
 * team goes on to its member and team limits as before.
 *
 * Switched by USAGE_HARD_STOP_UNBILLED=1 (development first; production is a live step for Lawrence).
 */

/** The usage plan whose included amount applies: Founders is a Pro grant. */
export const includedPlanOf = (plan: string | null | undefined): UsagePlan | null => {
  const id = plan?.trim().toLowerCase()
  if (id === "founders") return "pro"
  return isUsagePlan(id) ? id : null
}

const err402 = (spentUsd: number, includedUsd: number) =>
  Response.json(
    {
      error: {
        code: "usage.included_reached",
        message: "You used the AI amount included in your plan for this month. It resets at the start of next month.",
        type: "insufficient_quota",
        details: { included_usd: includedUsd, spent_usd: spentUsd, resets_at: nextMonthStart(Date.now()) }
      }
    },
    { status: 402 }
  )

type Meter = { includedAdmit(entity: string, includedMicros: number, maxMicros: number): Promise<{ ok: true } | { ok: false; spent_micros: number }> }

export const includedStop = async (env: Env, meter: unknown, caller: { readonly team: string; readonly plan?: string | null }, maxMicros: number): Promise<Response | null> => {
  if (env.USAGE_HARD_STOP_UNBILLED !== "1") return null
  const plan = includedPlanOf(caller.plan)
  // A paid plan this catalog does not know has no included amount: no AI above zero until it is billable.
  const includedUsd = plan ? usageIncludedUsd(plan, usagePriceSet(env)) : 0
  const r = await (meter as Meter).includedAdmit(caller.team, Math.round(includedUsd * 1_000_000), maxMicros)
  return r.ok ? null : err402(Math.round(r.spent_micros) / 1_000_000, includedUsd)
}
