import { stripeFetch } from "./billing-usage-sync.ts"
import { creditsKey } from "./credits-checkout.ts"
import type { Env } from "./env.ts"

/**
 * Credits auto-reload (plans/cmux-next/paid-plans-DESIGN.md §6.3): when a team's available credit falls
 * below its threshold, charge the team's saved card off-session for the reload amount, at most the
 * monthly cap of reloads per UTC month, one reload in flight at a time. The settings and the run
 * ledger live in the team's UsageMeterDO (SQLite); this module holds the tables, the decision and
 * the charge. Test mode only (creditsKey refuses live keys and test keys on production).
 */
export const AUTORELOAD_KIND = "cmux_credits_autoreload"
/** A reload still running after this long is taken as lost (its webhook still grants it once). */
const IN_FLIGHT_MS = 10 * 60_000

export interface AutoReloadSettings {
  readonly enabled: boolean
  readonly threshold_micros: number
  readonly amount_micros: number
  readonly monthly_cap_micros: number
}

/** The reload to make (micros), or null: on, below the threshold, inside the month's cap, none in flight. */
export const autoReloadDecision = (s: AutoReloadSettings, availableMicros: number, monthReloadedMicros: number, inFlight: boolean): number | null =>
  s.enabled && !inFlight && availableMicros < s.threshold_micros && monthReloadedMicros + s.amount_micros <= s.monthly_cap_micros ? s.amount_micros : null

export const monthOf = (now: number) => new Date(now).toISOString().slice(0, 7)

export const ensureAutoReloadTables = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS credit_autoreload (id INTEGER PRIMARY KEY CHECK (id = 1), enabled INTEGER NOT NULL, threshold_micros INTEGER NOT NULL, amount_micros INTEGER NOT NULL, monthly_cap_micros INTEGER NOT NULL, updated_at INTEGER NOT NULL, updated_by TEXT NOT NULL, last_error TEXT, last_error_at INTEGER)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS credit_autoreload_run (key TEXT PRIMARY KEY, month TEXT NOT NULL, micros INTEGER NOT NULL, status TEXT NOT NULL, intent TEXT, at INTEGER NOT NULL)`)
}

type Row = { enabled: number; threshold_micros: number; amount_micros: number; monthly_cap_micros: number; last_error: string | null; last_error_at: number | null }

export const readAutoReload = (sql: SqlStorage): (AutoReloadSettings & { last_error: string | null; last_error_at: number | null }) | null => {
  ensureAutoReloadTables(sql)
  const r = sql.exec<Row>(`SELECT enabled, threshold_micros, amount_micros, monthly_cap_micros, last_error, last_error_at FROM credit_autoreload WHERE id = 1`).toArray()[0]
  return r ? { enabled: r.enabled === 1, threshold_micros: r.threshold_micros, amount_micros: r.amount_micros, monthly_cap_micros: r.monthly_cap_micros, last_error: r.last_error, last_error_at: r.last_error_at } : null
}

export const writeAutoReload = (sql: SqlStorage, s: AutoReloadSettings, by: string, now: number) => {
  ensureAutoReloadTables(sql)
  // A new setting clears the last error (the person saw it and changed something, e.g. the card).
  sql.exec(
    `INSERT INTO credit_autoreload (id, enabled, threshold_micros, amount_micros, monthly_cap_micros, updated_at, updated_by, last_error, last_error_at) VALUES (1, ?, ?, ?, ?, ?, ?, NULL, NULL)
     ON CONFLICT (id) DO UPDATE SET enabled = excluded.enabled, threshold_micros = excluded.threshold_micros, amount_micros = excluded.amount_micros, monthly_cap_micros = excluded.monthly_cap_micros, updated_at = excluded.updated_at, updated_by = excluded.updated_by, last_error = NULL, last_error_at = NULL`,
    s.enabled ? 1 : 0, s.threshold_micros, s.amount_micros, s.monthly_cap_micros, now, by
  )
}

/** Turns auto-reload off with the reason (a refused card is never retried on every call). */
export const failAutoReload = (sql: SqlStorage, reason: string, now: number) => {
  ensureAutoReloadTables(sql)
  sql.exec(`UPDATE credit_autoreload SET enabled = 0, last_error = ?, last_error_at = ? WHERE id = 1`, reason.slice(0, 300), now)
}

/** Reloads this month: succeeded and still pending (a pending one counts against the cap until it settles). */
export const monthReloaded = (sql: SqlStorage, now: number): { micros: number; inFlight: boolean; count: number } => {
  ensureAutoReloadTables(sql)
  const rows = sql.exec<{ micros: number; status: string; at: number }>(`SELECT micros, status, at FROM credit_autoreload_run WHERE month = ?`, monthOf(now)).toArray()
  const live = rows.filter((r) => r.status === "succeeded" || (r.status === "pending" && now - r.at < IN_FLIGHT_MS))
  return { micros: live.reduce((a, r) => a + r.micros, 0), inFlight: rows.some((r) => r.status === "pending" && now - r.at < IN_FLIGHT_MS), count: rows.length }
}

export const startRun = (sql: SqlStorage, key: string, micros: number, now: number) =>
  sql.exec(`INSERT INTO credit_autoreload_run (key, month, micros, status, intent, at) VALUES (?, ?, ?, 'pending', NULL, ?)`, key, monthOf(now), micros, now)

export const endRun = (sql: SqlStorage, key: string, status: "succeeded" | "failed", intent: string | null) =>
  sql.exec(`UPDATE credit_autoreload_run SET status = ?, intent = ? WHERE key = ?`, status, intent, key)

/** The team's first saved card on its payment customer, or null. */
export const savedCard = async (key: string, customer: string): Promise<string | null> => {
  const r = (await stripeFetch(key, "GET", `/v1/customers/${encodeURIComponent(customer)}/payment_methods?type=card&limit=1`)) as { data?: Array<{ id?: string }> }
  const id = r.data?.[0]?.id
  return typeof id === "string" && /^pm_[A-Za-z0-9_]{1,200}$/.test(id) ? id : null
}

export type ChargeResult = { ok: true; intent: string } | { ok: false; reason: string }

/** One off-session charge of `micros` on the team's saved card (Stripe PaymentIntent, confirmed now). */
export const chargeSavedCard = async (env: Env, team: string, customer: string, micros: number, runKey: string): Promise<ChargeResult> => {
  const key = creditsKey(env)
  if (!key.ok) return { ok: false, reason: `billing unavailable (${key.reason})` }
  try {
    const card = await savedCard(key.key, customer)
    if (!card) return { ok: false, reason: "no saved card" }
    const meta = { app: "cmux", kind: AUTORELOAD_KIND, team, run: runKey }
    const pi = (await stripeFetch(
      key.key,
      "POST",
      "/v1/payment_intents",
      { amount: String(Math.round(micros / 10_000)), currency: "usd", customer, payment_method: card, off_session: "true", confirm: "true", description: "cmux credits auto-reload", ...Object.fromEntries(Object.entries(meta).map(([k, v]) => [`metadata[${k}]`, v])) },
      `cmux-autoreload:${runKey}`
    )) as { id?: string; status?: string }
    if (pi.status !== "succeeded" || !pi.id) return { ok: false, reason: `payment ${pi.status ?? "not confirmed"}` }
    return { ok: true, intent: pi.id }
  } catch (e) {
    const err = e as { stripeMessage?: string; message?: string }
    return { ok: false, reason: err.stripeMessage || err.message || String(e) }
  }
}
