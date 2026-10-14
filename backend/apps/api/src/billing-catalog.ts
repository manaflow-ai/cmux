/**
 * The usage billing catalog (cx-y79zh S3, plans/cmux-next/usage-billing.md): one owner for the
 * meter event names, the product id and the metered price per plan. The Worker's usage sync
 * (billing-usage-sync.ts) and the test-mode catalog script (backend/scripts/stripe-usage-catalog.ts)
 * both read it.
 *
 * Pass-through pricing (Lawrence 2026-10-13): one unit = one USD of AI usage at our cost, billed at
 * 1.00 USD above the plan's included amount. Included amounts (Lawrence 2026-10-14): Go 5, Pro 20,
 * Max 100, Team 20 USD per month.
 *
 * Two included modes (Lawrence 2026-10-14):
 * - per_team: one amount for the subscription. A graduated price (first N units at 0, then 1.00 USD)
 *   on the meter USAGE_METER_EVENT; the sync sends the period's whole level.
 * - per_seat: the amount times the plan item's seats (the most seen in the period). A flat price
 *   (1.00 USD per unit) on the meter USAGE_METER_EVENT_ABOVE; the sync subtracts N x seats and sends
 *   only the level above it.
 * Go, Pro and Max are per team. A Team customer's mode is an operator setting per team
 * (POST /v1/internal/billing/team-mode, billing-team-mode.ts); new teams are per team, and a change
 * applies from the next period start (usage-billing-store.ts teamModeAt). The two modes use two
 * meters so that a meter value always means one thing.
 */
export const USAGE_METER_EVENT = "cmux_ai_usage"
/** The per-seat meter: the period's level above the included amount, already subtracted by the sync. */
export const USAGE_METER_EVENT_ABOVE = "cmux_ai_usage_above_included"
export const USAGE_PRODUCT_ID = "cmux_ai_usage"
export const USAGE_PLANS = ["go", "pro", "max", "team"] as const
export type UsagePlan = (typeof USAGE_PLANS)[number]
export type IncludedMode = "per_team" | "per_seat"
export const INCLUDED_MODES: ReadonlyArray<IncludedMode> = ["per_team", "per_seat"]
/**
 * Price sets: the included USD per plan. `v1`: the production values (test mode until the live step).
 * `e2e`: 1 USD included (Max 0.5 USD per seat), so an end-to-end run can cross the included amount with a
 * little real usage; the sync uses it only on the development Worker with BILLING_USAGE_PRICE_SET=e2e
 * (billing-usage-sync.ts usagePriceSet).
 */
/**
 * Price sets: the included USD per plan. `v1`: the production values (test mode until the live step).
 * `e2e`: small amounts so that an end-to-end run can cross the included amount with a little real
 * usage (Team 0.5 per seat; a graduated price needs a whole-dollar tier, so the e2e Team plan has the
 * per-seat price only); the sync uses it only on the development Worker with BILLING_USAGE_PRICE_SET=e2e
 * (billing-usage-sync.ts usagePriceSet).
 */
export const USAGE_PRICE_SETS = { v1: { go: 5, pro: 20, max: 100, team: 20 }, e2e: { go: 1, pro: 1, max: 1, team: 0.5 } } as const satisfies Record<string, Readonly<Record<UsagePlan, number>>>
export type UsagePriceSet = keyof typeof USAGE_PRICE_SETS
export const USAGE_PRICE_SET_NAMES = Object.keys(USAGE_PRICE_SETS) as ReadonlyArray<UsagePriceSet>
/** Plans whose included mode is the team's operator setting; every other plan is per team. */
export const USAGE_TEAM_MODE_PLANS: ReadonlySet<UsagePlan> = new Set(["team"])
/** The modes a plan can bill in (the catalog makes one usage price per mode). */
export const usageModesOf = (plan: UsagePlan): ReadonlyArray<IncludedMode> => (USAGE_TEAM_MODE_PLANS.has(plan) ? INCLUDED_MODES : ["per_team"])
export const USAGE_INCLUDED_USD: Readonly<Record<UsagePlan, number>> = USAGE_PRICE_SETS.v1
export const usageIncludedUsd = (plan: UsagePlan, set: UsagePriceSet = "v1") => USAGE_PRICE_SETS[set][plan]
export const usageMeterEvent = (mode: IncludedMode) => (mode === "per_seat" ? USAGE_METER_EVENT_ABOVE : USAGE_METER_EVENT)
/** per_team: `cmux-ai-usage-<plan>-incl<N>-<set>` (graduated); per_seat: `cmux-ai-usage-<plan>-seat<N>-<set>` (flat). */
export const usagePriceLookupKey = (plan: UsagePlan, set: UsagePriceSet = "v1", mode: IncludedMode = "per_team") =>
  `cmux-ai-usage-${plan}-${mode === "per_seat" ? "seat" : "incl"}${USAGE_PRICE_SETS[set][plan]}-${set}`
/**
 * The level the sync sends (micro-dollars): the whole level per team; per seat, the level above
 * N x seats (never below 0). `seats` is at least 1.
 */
export const usageMeterValueMicros = (mode: IncludedMode, levelMicros: number, includedUsd: number, seats: number) =>
  mode === "per_seat" ? Math.max(0, levelMicros - Math.round(includedUsd * 1_000_000) * Math.max(1, Math.floor(seats))) : levelMicros
export const isUsagePlan = (v: unknown): v is UsagePlan => typeof v === "string" && (USAGE_PLANS as ReadonlyArray<string>).includes(v)
export const isIncludedMode = (v: unknown): v is IncludedMode => v === "per_team" || v === "per_seat"
