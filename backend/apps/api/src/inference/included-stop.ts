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

/** The included amount (micro-dollars) that applies to this caller, or undefined when the stop is off. */
export const includedMicrosFor = (env: Env, caller: { readonly plan?: string | null }): number | undefined => {
  if (env.USAGE_HARD_STOP_UNBILLED !== "1") return undefined
  const plan = includedPlanOf(caller.plan)
  // A paid plan this catalog does not know has no included amount: no AI until it is billable.
  return Math.round((plan ? usageIncludedUsd(plan, usagePriceSet(env)) : 0) * 1_000_000)
}

/** The 402 of the included-amount stop: Cloud-service copy, the amounts and the reset time. */
export const includedReached = (spentUsd: number, includedUsd: number) =>
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
