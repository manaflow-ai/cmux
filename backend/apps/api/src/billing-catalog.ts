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
export const USAGE_INCLUDED_USD: Readonly<Record<UsagePlan, number>> = { go: 5, pro: 20, max: 100, team: 20 }
export const usagePriceLookupKey = (plan: UsagePlan) => `cmux-ai-usage-${plan}-incl${USAGE_INCLUDED_USD[plan]}-v1`
export const isUsagePlan = (v: unknown): v is UsagePlan => typeof v === "string" && (USAGE_PLANS as ReadonlyArray<string>).includes(v)
