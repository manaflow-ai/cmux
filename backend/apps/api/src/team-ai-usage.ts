import { INFERENCE_PERSONAL_PLAN_IDS, INFERENCE_TEAM_PLAN_IDS } from "@cmux/protocol"
import type { Env } from "./env.ts"
import { usageIncludedUsd } from "./billing-catalog.ts"
import { usagePriceSet } from "./billing-usage-sync.ts"
import { includedPlanOf } from "./inference/included-stop.ts"
import { nextMonthStart } from "./usage-user.ts"

/**
 * team.ai_limit.get's team line (cx-y79zh S5, the console usage view), for billing.manage readers:
 * the team's AI usage this period against its included amount, and whether the included-amount stop
 * applies. A billable team (the usage sync saw a usage item) reads its billing period and the amount
 * the sync bills against (x seats per seat); any other team reads the UTC month and its plan's amount.
 */
export interface TeamUsageLine {
  /** Usage above the included amount is billed at cost (a billable subscription). */
  readonly billed: boolean
  /** The included amount for this period, or null when the plan is not known yet. */
  readonly included_usd: number | null
  readonly per_seat: boolean
  readonly seats: number
  /** -1 when the meter did not answer. */
  readonly spent_usd: number
  readonly period_start: number | null
  readonly period_end: number
  /** The included-amount stop applies to this team now (on, and not billable). */
  readonly stop_applies: boolean
  /** The stop applies and the team reached its included amount: AI calls are refused until the reset. */
  readonly stopped: boolean
}

const monthStart = (now: number) => {
  const d = new Date(now)
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1)
}

export const teamUsageLine = async (env: Env, team: string, plan: string | null): Promise<TeamUsageLine> => {
  const now = Date.now()
  const usage = await env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(team)).teamUsage(team).catch(() => null)
  const b = usage?.billable ?? null
  if (b) return { billed: true, included_usd: b.included_usd, per_seat: b.mode === "per_seat", seats: b.seats, spent_usd: b.spent_usd, period_start: b.period_start === null ? null : b.period_start * 1000, period_end: b.period_end * 1000, stop_applies: false, stopped: false }
  // As the stop counts it (included-stop.ts): a paid plan the catalog does not know has 0 included; an unpaid
  // plan or no plan copy has none to show (its calls stop at the plan gate, never at the included amount).
  const usagePlan = includedPlanOf(plan)
  const paid = plan !== null && (INFERENCE_PERSONAL_PLAN_IDS.has(plan) || INFERENCE_TEAM_PLAN_IDS.has(plan))
  const perSeat = usage?.unbilled.mode === "per_seat"
  const seats = perSeat ? usage!.unbilled.seats : 1
  const included = usagePlan ? usageIncludedUsd(usagePlan, usagePriceSet(env)) * seats : paid ? 0 : null
  const spent = usage ? usage.month_spent_usd : -1
  const stopApplies = env.USAGE_HARD_STOP_UNBILLED === "1"
  return { billed: false, included_usd: included, per_seat: perSeat, seats, spent_usd: spent, period_start: monthStart(now), period_end: nextMonthStart(now), stop_applies: stopApplies, stopped: stopApplies && included !== null && spent >= 0 && spent >= included }
}
