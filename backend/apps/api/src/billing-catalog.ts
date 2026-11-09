/**
 * The usage billing catalog (cx-y79zh S3, plans/cmux-next/usage-billing.md): one owner for the
 * meter event names, the product id and the metered price per plan. The Worker's usage sync
 * (billing-usage-sync.ts) and the test-mode catalog script (backend/scripts/stripe-usage-catalog.ts)
 * both read it.
 *
 * Pass-through pricing (Lawrence 2026-10-13): one unit = one USD of AI usage at our cost, billed at
 * 1.00 USD above the plan's included amount. Included amounts (Lawrence 2026-10-14): Go 5, Pro 20,
 * Max 100, Team 20 USD per month (price set v1). Team 25 USD per seat, pooled across the team (Leo
 * 2026-11-09): price set v2, where a Team team with no operator setting is per seat.
 *
 * Two included modes (Lawrence 2026-10-14):
 * - per_team: one amount for the subscription. A graduated price (first N units at 0, then 1.00 USD)
 *   on the meter USAGE_METER_EVENT; the sync sends the period's whole level.
 * - per_seat: the amount times the plan item's seats (the most seen in the period). A flat price
 *   (1.00 USD per unit) on the meter USAGE_METER_EVENT_ABOVE; the sync subtracts N x seats and sends
 *   only the level above it.
 * Go, Pro and Max are per team. A Team customer's mode is an operator setting per team
 * (POST /v1/internal/billing/team-mode, billing-team-mode.ts); a team with no setting gets its price
 * set's default (defaultTeamMode: per team in v1 and e2e, per seat in v2), and a change
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
 * Price sets: the included USD per plan. A change of an included amount is a new set, never an edit.
 * `v1`: the production values (test mode until the live step). `v2`: v1 with Team 25 USD per seat (Leo
 * 2026-11-09); the sync uses it only on development and staging with BILLING_USAGE_PRICE_SET=v2.
 * `e2e`: small amounts so that an end-to-end run can cross the included amount with a little real
 * usage (Team 0.5 per seat; a graduated price needs a whole-dollar tier, so the e2e Team plan has the
 * per-seat price only); the sync uses it only on the development Worker with BILLING_USAGE_PRICE_SET=e2e
 * (billing-usage-sync.ts usagePriceSet).
 */
export const USAGE_PRICE_SETS = { v1: { go: 5, pro: 20, max: 100, team: 20 }, v2: { go: 5, pro: 20, max: 100, team: 25 }, e2e: { go: 1, pro: 1, max: 1, team: 0.5 } } as const satisfies Record<string, Readonly<Record<UsagePlan, number>>>
export type UsagePriceSet = keyof typeof USAGE_PRICE_SETS
export const USAGE_PRICE_SET_NAMES = Object.keys(USAGE_PRICE_SETS) as ReadonlyArray<UsagePriceSet>
/** Plans whose included mode is the team's operator setting; every other plan is per team. */
export const USAGE_TEAM_MODE_PLANS: ReadonlySet<UsagePlan> = new Set(["team"])
/** The modes a plan can bill in (the catalog makes one usage price per mode). */
export const usageModesOf = (plan: UsagePlan): ReadonlyArray<IncludedMode> => (USAGE_TEAM_MODE_PLANS.has(plan) ? INCLUDED_MODES : ["per_team"])
/** A Team team's included mode when the operator set none: per seat in v2 (pooled, Leo 2026-11-09), else per team. */
export const defaultTeamMode = (set: UsagePriceSet): IncludedMode => (set === "v2" ? "per_seat" : "per_team")
/** A plan's included mode when the operator set none: the set's Team default for Team, per team for every other plan (or none). */
export const defaultIncludedMode = (plan: UsagePlan | null, set: UsagePriceSet): IncludedMode => (plan && USAGE_TEAM_MODE_PLANS.has(plan) ? defaultTeamMode(set) : "per_team")
/** Whether the set's included amount pools Cloud machine time with model spend (Leo 2026-11-09: v2 only). */
export const poolsMachineTime = (set: UsagePriceSet): boolean => set === "v2"
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
/**
 * The multiplier on model overage (Leo 2026-11-09, plans/team-plan/margins.md "Decided": "Model overage at the
 * provider's list price plus 10%" -> "sure"): 1.10 under price set v2, 1.0 (pass-through) under v1 (production)
 * and e2e (its end-to-end check compares the meter summary with the level at cost). Included usage stays at cost
 * and machine time stays at list in every set.
 */
export const overageModelMarkup = (set: UsagePriceSet): number => (set === "v2" ? 1.1 : 1)
/** The pricing a set's usage prices name (Stripe metadata price_version, the levels read): pass-through, or the model overage markup in percent. */
export const usagePriceVersion = (set: UsagePriceSet): string => (overageModelMarkup(set) === 1 ? `ai-passthrough-${set}` : `ai-overage-models${Math.round(overageModelMarkup(set) * 100)}-${set}`)
/** The team spending cap an admin did not set (margins.md section 4): this many times the pool, v2 Team (per seat) only; null elsewhere. */
export const defaultTeamCapPools = (set: UsagePriceSet): number | null => (set === "v2" ? 2 : null)
/**
 * Whether the model router refuses at the team spending cap (UsageMeterDO.teamCap, billed prices over the billing
 * period) besides the hard cap (A18, summarize): v2 only, so production's v1 keeps today's check until Leo's go.
 */
export const teamCapApplies = (set: UsagePriceSet): boolean => set === "v2"
/** The team cap state turns `near` at this percent of the cap (margins.md section 4: admins get a notice at 80%). */
export const TEAM_CAP_NEAR_PERCENT = 80

/**
 * The billed level of a period (integer micro-dollars) from its settled facts split by kind, with
 * `includedMicros` the pool (included x seats per seat, the included amount per team):
 *
 *   overage          = max(0, models + machines - included)
 *   overage_models   = overage x models / (models + machines), floored; overage_machines = the rest
 *   billed           = min(total, included) + round(overage_models x markup) + overage_machines
 *
 * So the pool is spent at cost (models) and list (machines) whatever the mix, and only the part above it
 * carries the model markup, split pro rata to the period's shares. Stripe subtracts the pool itself (the
 * per-seat sync subtracts included x seats, the graduated per-team price's first tier is free), so
 * billed - included is exactly the billed overage. With markup 1 (v1, e2e) billed is the level unchanged.
 * A negative share (only corrections) counts as 0 for the split.
 */
export const billedLevelMicros = (modelsMicros: number, machineMicros: number, includedMicros: number, markup: number): number => {
  const total = modelsMicros + machineMicros
  const overage = Math.max(0, total - Math.max(0, Math.round(includedMicros)))
  const bp = Math.round(markup * 10_000)
  if (overage === 0 || bp === 10_000) return total
  const m = BigInt(Math.max(0, Math.round(modelsMicros)))
  const c = BigInt(Math.max(0, Math.round(machineMicros)))
  const shares = m + c
  const overageModels = shares === 0n ? 0n : (BigInt(overage) * m) / shares
  const overageMachines = BigInt(overage) - overageModels
  // Half up, in basis points, on integers (no float money).
  const markedModels = (overageModels * BigInt(bp) + 5_000n) / 10_000n
  return total - overage + Number(markedModels + overageMachines)
}
export const isUsagePlan = (v: unknown): v is UsagePlan => typeof v === "string" && (USAGE_PLANS as ReadonlyArray<string>).includes(v)
export const isIncludedMode = (v: unknown): v is IncludedMode => v === "per_team" || v === "per_seat"
