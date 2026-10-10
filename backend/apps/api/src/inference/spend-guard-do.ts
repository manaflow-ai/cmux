import { DurableObject } from "cloudflare:workers"
import type { Env } from "../env.ts"
import { BUDGET_LINES, type BudgetLine, type ProviderId } from "./catalog.ts"

/**
 * SpendGuardDO (one instance, name "global"): the model router's money brake and provider health
 * (plans/cmux-next/model-router.md, cx-dna4.2).
 *
 * - Every budget line (one per provider, plus "free") has a hard USD cap per UTC day from the
 *   Worker's vars. A missing cap is 0: that line refuses everything (fail closed).
 * - A request reserves its projected MAXIMUM cost before the upstream call, on its provider's line
 *   and (free tier) on the free line. It is refused when settled + open reservations + this
 *   maximum would pass the cap, so no single request can push a line past its cap even when the
 *   provider account itself has no limit.
 * - Settle replaces the reservation with the actual cost. A reservation that is never settled is
 *   charged at its full amount after one hour (the alarm).
 * - Alerts: one log line per line and UTC day at 50, 80 and 100 % (Axiom reads Worker logs).
 * - Health: consecutive failures put a provider in a short cooldown (15 s doubling to 5 min);
 *   time to first byte is an EWMA. A cooled provider is tried only when no other one is left.
 */

const MICROS = 1_000_000
const RESERVATION_TTL_MS = 3600_000
const ALERT_PCTS = [50, 80, 100] as const

export const utcDay = (ms: number) => new Date(ms).toISOString().slice(0, 10)

/** Daily cap in USD for a budget line, from the Worker vars; missing or invalid = 0. */
export const capUsd = (env: Env, line: BudgetLine): number => {
  const raw = line === "free" ? env.INFERENCE_FREE_DAILY_CAP_USD : (env[`INFERENCE_DAILY_CAP_USD_${line.toUpperCase().replace("-", "_")}` as keyof Env] as string | undefined) ?? env.INFERENCE_DAILY_CAP_USD
  const n = Number(raw)
  return Number.isFinite(n) && n > 0 ? n : 0
}

export type PlanResult =
  | { readonly ok: true; readonly provider: ProviderId; readonly reservedMicros: number }
  | { readonly ok: false; readonly code: "budget.exhausted" | "provider.unavailable"; readonly line?: BudgetLine }

export interface LineStatus {
  readonly line: BudgetLine
  readonly capUsd: number
  readonly spentUsd: number
  readonly reservedUsd: number
}

export interface ProviderHealth {
  readonly provider: string
  readonly ttfbMs: number | null
  readonly failures: number
  readonly cooldownUntil: number
  readonly ok: number
  readonly errors: number
}

export class SpendGuardDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    const sql = ctx.storage.sql
    sql.exec(`CREATE TABLE IF NOT EXISTS spend (day TEXT NOT NULL, line TEXT NOT NULL, micros INTEGER NOT NULL, PRIMARY KEY (day, line))`)
    sql.exec(`CREATE TABLE IF NOT EXISTS reservation (id TEXT NOT NULL, line TEXT NOT NULL, day TEXT NOT NULL, micros INTEGER NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (id, line))`)
    sql.exec(`CREATE TABLE IF NOT EXISTS alert (day TEXT NOT NULL, line TEXT NOT NULL, pct INTEGER NOT NULL, PRIMARY KEY (day, line, pct))`)
    sql.exec(`CREATE TABLE IF NOT EXISTS health (provider TEXT PRIMARY KEY, ttfb REAL, failures INTEGER NOT NULL, cooldown_until INTEGER NOT NULL, ok INTEGER NOT NULL, errors INTEGER NOT NULL)`)
  }

  private used(day: string, line: BudgetLine): number {
    const sql = this.ctx.storage.sql
    const spent = Number(sql.exec<{ m: number | null }>(`SELECT micros AS m FROM spend WHERE day = ? AND line = ?`, day, line).toArray()[0]?.m ?? 0)
    const open = Number(sql.exec<{ m: number | null }>(`SELECT SUM(micros) AS m FROM reservation WHERE day = ? AND line = ?`, day, line).toArray()[0]?.m ?? 0)
    return spent + open
  }

  private cooled(provider: string, now: number): boolean {
    const row = this.ctx.storage.sql.exec<{ c: number }>(`SELECT cooldown_until AS c FROM health WHERE provider = ?`, provider).toArray()[0]
    return row !== undefined && Number(row.c) > now
  }

  /**
   * Picks the first candidate whose line (and the free line, when `free`) can take `maxMicros`
   * today, healthy providers first, and reserves it under `id`. One transaction: two concurrent
   * requests cannot both take the last budget.
   */
  async plan(id: string, candidates: ReadonlyArray<ProviderId>, maxMicros: number, free: boolean, now = Date.now()): Promise<PlanResult> {
    if (candidates.length === 0) return { ok: false, code: "provider.unavailable" }
    const day = utcDay(now)
    const fits = (line: BudgetLine) => this.used(day, line) + maxMicros <= Math.round(capUsd(this.env, line) * MICROS)
    if (free && !fits("free")) return { ok: false, code: "budget.exhausted", line: "free" }
    const ordered = [...candidates.filter((p) => !this.cooled(p, now)), ...candidates.filter((p) => this.cooled(p, now))]
    let exhausted: BudgetLine | undefined
    for (const provider of ordered) {
      if (!fits(provider)) {
        exhausted ??= provider
        continue
      }
      this.ctx.storage.transactionSync(() => {
        for (const line of free ? [provider, "free"] : [provider]) {
          this.ctx.storage.sql.exec(`INSERT OR REPLACE INTO reservation (id, line, day, micros, at) VALUES (?, ?, ?, ?, ?)`, id, line, day, maxMicros, now)
        }
      })
      await this.armAlarm(now)
      return { ok: true, provider, reservedMicros: maxMicros }
    }
    return { ok: false, code: "budget.exhausted", ...(exhausted ? { line: exhausted } : {}) }
  }

  /** A failed attempt before the first byte: drops its reservation and counts the failure. */
  async fail(id: string, provider: ProviderId, now = Date.now()): Promise<void> {
    this.ctx.storage.sql.exec(`DELETE FROM reservation WHERE id = ?`, id)
    this.report(provider, false, null, now)
  }

  /**
   * The request ended: its reservation becomes `actualMicros` of spend on the same lines. With no
   * reservation (already charged by the alarm) nothing changes. `ttfbMs` = null when the upstream
   * failed after the first byte (counts as an error, no latency sample).
   */
  async settle(id: string, provider: ProviderId, actualMicros: number, ttfbMs: number | null, now = Date.now()): Promise<void> {
    const rows = this.ctx.storage.sql.exec<{ line: string; day: string }>(`SELECT line, day FROM reservation WHERE id = ?`, id).toArray()
    this.ctx.storage.transactionSync(() => {
      for (const r of rows) this.addSpend(r.day, r.line as BudgetLine, Math.max(0, Math.round(actualMicros)))
      this.ctx.storage.sql.exec(`DELETE FROM reservation WHERE id = ?`, id)
    })
    for (const r of rows) this.alerts(r.day, r.line as BudgetLine)
    this.report(provider, ttfbMs !== null, ttfbMs, now)
  }

  async status(now = Date.now()): Promise<{ day: string; lines: ReadonlyArray<LineStatus>; health: ReadonlyArray<ProviderHealth> }> {
    const day = utcDay(now)
    const sql = this.ctx.storage.sql
    const lines = BUDGET_LINES.map((line) => {
      const spent = Number(sql.exec<{ m: number | null }>(`SELECT micros AS m FROM spend WHERE day = ? AND line = ?`, day, line).toArray()[0]?.m ?? 0)
      return { line, capUsd: capUsd(this.env, line), spentUsd: spent / MICROS, reservedUsd: (this.used(day, line) - spent) / MICROS }
    })
    const health = sql.exec<{ provider: string; ttfb: number | null; failures: number; cooldown_until: number; ok: number; errors: number }>(`SELECT * FROM health`).toArray().map((h) => ({
      provider: h.provider,
      ttfbMs: h.ttfb === null ? null : Math.round(Number(h.ttfb)),
      failures: Number(h.failures),
      cooldownUntil: Number(h.cooldown_until),
      ok: Number(h.ok),
      errors: Number(h.errors)
    }))
    return { day, lines, health }
  }

  private addSpend(day: string, line: BudgetLine, micros: number) {
    this.ctx.storage.sql.exec(`INSERT INTO spend (day, line, micros) VALUES (?, ?, ?) ON CONFLICT (day, line) DO UPDATE SET micros = micros + excluded.micros`, day, line, micros)
  }

  private alerts(day: string, line: BudgetLine) {
    const cap = capUsd(this.env, line) * MICROS
    if (cap <= 0) return
    const spent = Number(this.ctx.storage.sql.exec<{ m: number | null }>(`SELECT micros AS m FROM spend WHERE day = ? AND line = ?`, day, line).toArray()[0]?.m ?? 0)
    for (const pct of ALERT_PCTS) {
      if (spent < (cap * pct) / 100) continue
      const fresh = this.ctx.storage.sql.exec(`INSERT OR IGNORE INTO alert (day, line, pct) VALUES (?, ?, ?)`, day, line, pct).rowsWritten > 0
      if (fresh) console.warn(JSON.stringify({ msg: "inference.budget.alert", environment: this.env.ENVIRONMENT, day, line, pct, spent_usd: spent / MICROS, cap_usd: cap / MICROS }))
    }
  }

  private report(provider: ProviderId, ok: boolean, ttfbMs: number | null, now: number) {
    const sql = this.ctx.storage.sql
    const row = sql.exec<{ ttfb: number | null; failures: number }>(`SELECT ttfb, failures FROM health WHERE provider = ?`, provider).toArray()[0]
    const failures = ok ? 0 : Number(row?.failures ?? 0) + 1
    const cooldown = ok ? 0 : now + Math.min(300_000, 15_000 * 2 ** Math.min(failures - 1, 5))
    const prev = row?.ttfb === null || row?.ttfb === undefined ? null : Number(row.ttfb)
    const ttfb = ttfbMs === null ? prev : prev === null ? ttfbMs : prev * 0.8 + ttfbMs * 0.2
    sql.exec(
      `INSERT INTO health (provider, ttfb, failures, cooldown_until, ok, errors) VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT (provider) DO UPDATE SET ttfb = excluded.ttfb, failures = excluded.failures, cooldown_until = excluded.cooldown_until, ok = ok + excluded.ok, errors = errors + excluded.errors`,
      provider, ttfb, failures, cooldown, ok ? 1 : 0, ok ? 0 : 1
    )
  }

  private async armAlarm(now: number) {
    if ((await this.ctx.storage.getAlarm()) === null) await this.ctx.storage.setAlarm(now + RESERVATION_TTL_MS)
  }

  /** Reservations older than their TTL are charged in full (a lost settle never frees budget). */
  override async alarm(): Promise<void> {
    const now = Date.now()
    const sql = this.ctx.storage.sql
    const stale = sql.exec<{ id: string; line: string; day: string; micros: number }>(`SELECT id, line, day, micros FROM reservation WHERE at < ?`, now - RESERVATION_TTL_MS).toArray()
    this.ctx.storage.transactionSync(() => {
      for (const r of stale) this.addSpend(r.day, r.line as BudgetLine, Number(r.micros))
      sql.exec(`DELETE FROM reservation WHERE at < ?`, now - RESERVATION_TTL_MS)
      sql.exec(`DELETE FROM spend WHERE day < ?`, utcDay(now - 40 * 86_400_000))
      sql.exec(`DELETE FROM alert WHERE day < ?`, utcDay(now - 40 * 86_400_000))
    })
    for (const r of stale) this.alerts(r.day, r.line as BudgetLine)
    if (stale.length) console.warn(JSON.stringify({ msg: "inference.reservation.expired", count: stale.length }))
    const next = sql.exec<{ at: number | null }>(`SELECT MIN(at) AS at FROM reservation`).toArray()[0]?.at
    if (next !== null && next !== undefined) await this.ctx.storage.setAlarm(Number(next) + RESERVATION_TTL_MS)
  }
}
