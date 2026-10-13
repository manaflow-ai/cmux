/**
 * The usage billing catalog (cx-y79zh S3, plans/cmux-next/usage-billing.md): one owner for the
 * meter event name, the product id and the metered price per plan. The Worker's usage sync
 * (billing-usage-sync.ts) and the test-mode catalog script (backend/scripts/stripe-usage-catalog.ts)
 * both read it.
 *
 * Pass-through pricing (Lawrence 2026-10-13): one unit = one USD of AI usage at our cost, billed at
 * 1.00 USD above the plan's included amount (a graduated tier). The included amounts are test-mode
 * placeholders; Lawrence sets the real numbers before live (a new lookup key, `-v2`). Team's amount is
 * per team, not per seat (live decision for Lawrence).
 */
export const USAGE_METER_EVENT = "cmux_ai_usage"
export const USAGE_PRODUCT_ID = "cmux_ai_usage"
export const USAGE_PLANS = ["go", "pro", "max", "team"] as const
export type UsagePlan = (typeof USAGE_PLANS)[number]
/**
 * Price sets. `v1`: the test-mode placeholders. `e2e`: 1 USD included for every plan, so an end-to-end
 * run can cross the included tier with a little real usage; the sync uses it only on the development
 * Worker with BILLING_USAGE_PRICE_SET=e2e (billing-usage-sync.ts usagePriceSet).
 */
export const USAGE_PRICE_SETS = { v1: { go: 5, pro: 20, max: 100, team: 20 }, e2e: { go: 1, pro: 1, max: 1, team: 1 } } as const satisfies Record<string, Readonly<Record<UsagePlan, number>>>
export type UsagePriceSet = keyof typeof USAGE_PRICE_SETS
export const USAGE_INCLUDED_USD: Readonly<Record<UsagePlan, number>> = USAGE_PRICE_SETS.v1
export const usageIncludedUsd = (plan: UsagePlan, set: UsagePriceSet = "v1") => USAGE_PRICE_SETS[set][plan]
export const usagePriceLookupKey = (plan: UsagePlan, set: UsagePriceSet = "v1") => `cmux-ai-usage-${plan}-incl${USAGE_PRICE_SETS[set][plan]}-${set}`
export const isUsagePlan = (v: unknown): v is UsagePlan => typeof v === "string" && (USAGE_PLANS as ReadonlyArray<string>).includes(v)
