import type { Meter } from "@cmux/protocol"
import { billedLevelMicros, DEFAULT_TEAM_CAP_UNPAID_MAX_POOLS, defaultTeamCapPools, overageModelMarkup, TEAM_CAP_NEAR_PERCENT, type UsagePriceSet } from "./billing-catalog.ts"
import { BILLABLE_METERS, BILLABLE_METERS_SQL, utcMonth } from "./domains/usage.ts"
import { currentBillable, hasPaidInvoice, periodMarkupBp } from "./usage-billing-store.ts"

/**
 * The team spending cap (Leo 2026-11-09, cmuxterm-hq plans/team-plan/margins.md "Decided" and section 4), shared by
 * UsageMeterDO.teamCap (the read cmux-platform codes against) and the model router's reservation (usage-user.ts
 * reserveUser), so both answer from the same numbers.
 *
 * Constant cost per call: the billing period's settled spend comes from `usage_period_spend`, one row per billing
 * period holding its model and machine-time micros. Every billable fact adds to the row whose period holds its
 * recorded time, in the fact's own transaction (UsageMeterDO.record, usage-user.ts writeCallFact: settles, expired
 * reservations, late corrections). A period's row is seeded once, by one range sum over its facts, the first time it
 * is read (the sync's first mark of the period, or the first cap read); after that no call sums facts. Without a
 * billable mark the cap reads the UTC month's counters (usage_month), which are already running totals.
 */

/** UsageMeterDO.teamCap: the team spending cap state (cmux-platform refuses machine starts and pauses machines at `at_cap`). */
export interface TeamCap {
  readonly state: "under" | "near" | "at_cap"
  readonly spent_usd: number
  /** null: no cap set (state `under`). */
  readonly cap_usd: number | null
  /** The end of the period `spent_usd` counts (ms): the billing period's, else the next UTC month start. */
  readonly period_end: number
  /**
   * true: the admin's cap is above what the account may set before its first paid renewal invoice, so `cap_usd` is held
   * at that limit (billing-catalog.ts teamCapUnpaidMaxPools x the pool) until the invoice is paid.
   */
  readonly raise_locked?: boolean
}

/** How long a period's spend row is kept after its end (the previous period's row, for a late read). */
const PERIOD_ROW_KEEP_S = 70 * 86_400

export const ensurePeriodSpendTable = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS usage_period_spend (period_start INTEGER PRIMARY KEY, period_end INTEGER NOT NULL, models_micros INTEGER NOT NULL, machine_micros INTEGER NOT NULL)`)
}

/** One billable fact of `micros`, recorded at `at` (ms): added to the period row that holds it, if one exists (O(1): at most a few rows). */
export const addPeriodSpend = (sql: SqlStorage, meter: Meter, micros: number, at: number) => {
  if (!BILLABLE_METERS.includes(meter) || micros === 0) return
  const col = meter === "model.spend_usd" ? "models_micros" : "machine_micros"
  sql.exec(`UPDATE usage_period_spend SET ${col} = ${col} + ? WHERE period_start * 1000 <= ? AND period_end * 1000 > ?`, Math.round(micros), at, at)
}

/** The period's settled spend split (micros), seeded once by a range sum over its facts; old rows leave then. */
export const periodSpend = (sql: SqlStorage, periodStart: number, periodEnd: number, now: number): { models: number; machines: number } => {
  const row = sql.exec<{ models_micros: number; machine_micros: number; period_end: number }>(`SELECT models_micros, machine_micros, period_end FROM usage_period_spend WHERE period_start = ?`, periodStart).toArray()[0]
  if (row && Number(row.period_end) === periodEnd) return { models: Number(row.models_micros), machines: Number(row.machine_micros) }
  const sum = sql.exec<{ models: number | null; machines: number | null }>(
    `SELECT SUM(CASE WHEN meter = 'model.spend_usd' THEN CAST(ROUND(quantity * 1000000) AS INTEGER) ELSE 0 END) AS models, SUM(CASE WHEN meter = 'model.spend_usd' THEN 0 ELSE CAST(ROUND(quantity * 1000000) AS INTEGER) END) AS machines FROM usage_ledger WHERE meter IN ${BILLABLE_METERS_SQL} AND recorded_at >= ? AND recorded_at < ?`,
    periodStart * 1000, periodEnd * 1000
  ).toArray()[0]
  const models = Number(sum?.models ?? 0)
  const machines = Number(sum?.machines ?? 0)
  sql.exec(`INSERT OR REPLACE INTO usage_period_spend (period_start, period_end, models_micros, machine_micros) VALUES (?, ?, ?, ?)`, periodStart, periodEnd, models, machines)
  sql.exec(`DELETE FROM usage_period_spend WHERE period_end < ?`, Math.floor(now / 1000) - PERIOD_ROW_KEEP_S)
  return { models, machines }
}

const nextMonthStartMs = (now: number) => {
  const d = new Date(now)
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1)
}

/**
 * The cap state. `spent`: the billing period's (the fresh billable mark's period, else the UTC month) settled model
 * spend plus open model calls at their reserved maximum (those reserved in the period), plus `extraMicros` (a call
 * asking to reserve), at billed prices: the model overage above the pool x the period's pinned markup
 * (usage-billing-store.ts periodMarkupBp, billing-catalog.ts billedLevelMicros); at cost without a billable mark (no
 * overage is billed then); plus Cloud machine time at list when `machineTime`. `cap`: the admin's cap (usage.cap.set),
 * else under `set` v2 for any account the sync marked with a pool (a personal plan per team, a Team per seat), twice
 * the pool; else none. The raise lock (v2, with a pool): until the account's first paid renewal invoice, the cap counts
 * up to `unpaidMaxPools` x the pool, whatever the admin set (`raise_locked`).
 */
export const teamCapState = (sql: SqlStorage, now: number, graceMs: number, machineTime: boolean, set: UsagePriceSet, adminCapUsd: number | null, extraMicros = 0, unpaidMaxPools = DEFAULT_TEAM_CAP_UNPAID_MAX_POOLS): TeamCap & { readonly spent_micros: number; readonly cap_micros: number | null } => {
  const mark = currentBillable(sql, now, graceMs)
  const inPeriod = mark?.period_start !== undefined
  const fromMs = inPeriod ? mark!.period_start! * 1000 : Date.parse(`${utcMonth(now)}-01T00:00:00Z`)
  const period_end = inPeriod ? mark!.period_end * 1000 : nextMonthStartMs(now)
  let settled: { models: number; machines: number }
  if (inPeriod) settled = periodSpend(sql, mark!.period_start!, mark!.period_end, now)
  else {
    const rows = sql.exec<{ meter: string; m: number }>(`SELECT meter, usd_micros AS m FROM usage_month WHERE month = ? AND meter IN ${BILLABLE_METERS_SQL}`, utcMonth(now)).toArray()
    settled = { models: Number(rows.find((r) => r.meter === "model.spend_usd")?.m ?? 0), machines: rows.filter((r) => r.meter !== "model.spend_usd").reduce((n, r) => n + Number(r.m), 0) }
  }
  const open = Number(sql.exec<{ m: number | null }>(`SELECT SUM(micros) AS m FROM user_reservation WHERE at >= ?`, fromMs).toArray()[0]?.m ?? 0)
  const models = settled.models + Math.round(open) + Math.round(extraMicros)
  const machines = machineTime ? settled.machines : 0
  const seats = mark?.mode === "per_seat" ? Math.max(1, mark.seats ?? 1) : 1
  const pool = inPeriod && mark?.included_usd !== undefined ? Math.round(mark.included_usd * 1_000_000) * seats : null
  const bp = pool === null ? 10_000 : periodMarkupBp(sql, mark!.period_start!, Math.round(overageModelMarkup(set) * 10_000))
  const spent = pool === null ? models + machines : billedLevelMicros(models, machines, pool, bp / 10_000)
  const pools = defaultTeamCapPools(set)
  const pooled = pools !== null && pool !== null && pool > 0
  const asked = adminCapUsd !== null ? adminCapUsd : pooled ? (pools * pool) / 1_000_000 : null
  // The raise lock: one indexed row read, only for a capped account with a pool under v2.
  const lockUsd = asked !== null && pooled && !hasPaidInvoice(sql) ? (Math.max(pools, unpaidMaxPools) * pool) / 1_000_000 : null
  const raise_locked = lockUsd !== null && asked! > lockUsd
  const cap_usd = raise_locked ? lockUsd : asked
  if (cap_usd === null) return { state: "under", spent_usd: spent / 1_000_000, cap_usd: null, period_end, spent_micros: spent, cap_micros: null }
  const capMicros = Math.round(cap_usd * 1_000_000)
  const state = spent >= capMicros ? "at_cap" : spent * 100 >= capMicros * TEAM_CAP_NEAR_PERCENT ? "near" : "under"
  return { state, spent_usd: spent / 1_000_000, cap_usd, period_end, spent_micros: spent, cap_micros: capMicros, ...(raise_locked ? { raise_locked } : {}) }
}
