import { canonicalJson, type Domain, type ReduceResult } from "@cmux/ownership"
import { meterUnit, UsageCapSet, type Meter, type UsageStopReason, type UsageSummary } from "@cmux/protocol"
import { admit, decodeParams, reject, requirePersonalTeamAdmin } from "./common.ts"
import { personalTeamIdFor } from "./user.ts"

/**
 * UsageMeterDO's reducer and its pure cost math (automations-billing.md 5,
 * decisions A18, A21). The committed state is small: the team and its own cap.
 * The ledger and monthly counters are side tables of the DO (append-only,
 * idempotent by key); they are inputs to billing, not entity state, like the
 * SchedulerDO's run inputs.
 */

export interface UsageState {
  readonly owner: string | null
  /** The team's own monthly cap (USD); null = the deployment ceiling. */
  readonly team_cap_usd: number | null
}

/**
 * Cost estimate per unit in USD, used for the hard cap (A18: prices to customers
 * come later from dogfood cost data). These are Cloudflare's overage rates
 * (automations-billing.md section 3) and pass-through for model spend; they make
 * the cap bound our cost, not a customer price.
 */
export const COST_USD_PER_UNIT: Readonly<Record<Meter, number>> = {
  "automation.steps": 0.8 / 100_000,
  "automation.cpu_ms": 0.02 / 1_000_000,
  "automation.invocations": 0.3 / 1_000_000,
  "automation.dynamic_workers": 0.002,
  // Subrequests are not billed by Cloudflare; egress is metered for limits and reports.
  "egress.requests": 0,
  "model.spend_usd": 1
}

export const METERS = Object.keys(COST_USD_PER_UNIT) as ReadonlyArray<Meter>

/** UTC month of an instant, YYYY-MM. */
export const utcMonth = (ms: number) => new Date(ms).toISOString().slice(0, 7)

/** The deployment ceiling from its var; missing or invalid = 0, which stops every metered run. */
export const ceilingUsd = (raw: string | undefined): number => {
  const n = raw === undefined ? Number.NaN : Number(raw)
  return Number.isFinite(n) && n >= 0 ? n : 0
}

export const effectiveCap = (state: UsageState, ceiling: number) => (state.team_cap_usd === null ? ceiling : Math.min(state.team_cap_usd, ceiling))

/** Meters whose quantity is money: recorded as USD, summed as integer micro-dollars. */
export const MONEY_METERS: ReadonlySet<Meter> = new Set(["model.spend_usd"])

/**
 * Money is never summed as floats. Count meters (steps, CPU ms, invocations, workers,
 * requests) keep exact integer quantities and are priced once per month at summary time,
 * so sub-micro unit prices (one CPU ms is 0.02 micro-dollars) never round away. Money
 * meters accumulate integer micro-dollars per record.
 */
export const recordMicros = (meter: Meter, quantity: number) => (MONEY_METERS.has(meter) ? Math.round(quantity * 1_000_000) : 0)
const priceMicros = (meter: Meter, c: MeterCounter) => (MONEY_METERS.has(meter) ? c.usd_micros : Math.round(c.quantity * COST_USD_PER_UNIT[meter] * 1_000_000))

export interface MeterCounter {
  readonly quantity: number
  readonly usd_micros: number
}

const usd = (micros: number) => micros / 1_000_000

/** Summary of one month's counters against the cap in force (the cap compares integer micro-dollars). */
export const summarize = (state: UsageState, month: string, counters: ReadonlyMap<Meter, MeterCounter>, ceiling: number): UsageSummary => {
  const meters = METERS.map((meter) => {
    const c = counters.get(meter) ?? { quantity: 0, usd_micros: 0 }
    const micros = priceMicros(meter, c)
    return { meter, unit: meterUnit[meter], quantity: c.quantity, usd: usd(micros), micros }
  })
  const totalMicros = meters.reduce((n, m) => n + m.micros, 0)
  const cap = effectiveCap(state, ceiling)
  const stopped: UsageStopReason | null = ceiling <= 0 ? "cap.not_configured" : totalMicros >= Math.round(cap * 1_000_000) ? "cap.reached" : null
  const total = usd(totalMicros)
  return { owner: state.owner, month, meters: meters.map(({ micros: _m, ...line }) => line), total_usd: total, cap_usd: cap, ceiling_usd: ceiling, team_cap_usd: state.team_cap_usd, stopped }
}

export const usageDomain: Domain<UsageState> = {
  initial: () => ({ owner: null, team_cap_usd: null }),

  authorize: (state, op, _params, principal) => {
    if (!principal.team) return { code: "auth.forbidden", message: "needs a team" }
    if (state.owner && state.owner !== principal.team) return { code: "auth.forbidden", message: "not this team's usage" }
    return admit("cloud:UsageMeterDO", op, principal, (p) => (p.grant_classes ? { op_classes: p.grant_classes, revoked_at: null, expires_at: null } : undefined), Date.now())
  },

  reduce: (state, op, params, ctx): ReduceResult<UsageState> => {
    switch (op) {
      case "usage.cap.set": {
        const d = decodeParams<typeof UsageCapSet.params.Type>(UsageCapSet, params)
        if (!d.ok) return d
        const notAdmin = requirePersonalTeamAdmin(ctx.principal, personalTeamIdFor)
        if (notAdmin) return { ok: false, ...notAdmin }
        const next: UsageState = { owner: state.owner ?? ctx.principal.team ?? null, team_cap_usd: d.value.cap_usd }
        if (canonicalJson(next) === canonicalJson(state)) return { ok: true, state, value: next, changed: false }
        return { ok: true, state: next, value: next }
      }
      default:
        return reject("validation.invalid", `unknown op ${op}`)
    }
  }
}
