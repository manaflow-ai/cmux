import { COST_USD_PER_UNIT, MONEY_METERS } from "./domains/usage.ts"
import type { Meter } from "@cmux/protocol"

/**
 * The per-user monthly AI spending counter (cx-ds09i, Lawrence 2026-10-12), kept by the team's
 * UsageMeterDO: each member's own cost to us (provider cost of model router calls, and metered
 * automation runs at COST_USD_PER_UNIT) per UTC month, against the team's per-user limit
 * (TeamDO team.ai_limit.set; default INFERENCE_USER_MONTHLY_DEFAULT_USD, 200).
 *
 * A model router call reserves its maximum cost before the upstream call (one transaction: two
 * calls at once cannot both take the last of the limit), then settles with the real cost; a
 * refused global plan releases the reservation at once; a reservation that is never settled is
 * charged in full after RESERVATION_TTL_MS (the DO's alarm).
 */
export const USER_RESERVATION_TTL_MS = 3600_000
/** Rows of months before the previous one are dropped (the limit is per month). */
const KEEP_MONTHS = 2

export const ensureUserTables = (sql: SqlStorage) => {
  // usd_micros is REAL here: automation meters price below one micro-dollar per unit.
  sql.exec(`CREATE TABLE IF NOT EXISTS user_month (month TEXT NOT NULL, user TEXT NOT NULL, usd_micros REAL NOT NULL, PRIMARY KEY (month, user))`)
  sql.exec(`CREATE TABLE IF NOT EXISTS user_reservation (id TEXT PRIMARY KEY, user TEXT NOT NULL, month TEXT NOT NULL, micros REAL NOT NULL, at INTEGER NOT NULL)`)
}

export const userSpentMicros = (sql: SqlStorage, month: string, user: string): { spent: number; open: number } => {
  const spent = Number(sql.exec<{ m: number | null }>(`SELECT usd_micros AS m FROM user_month WHERE month = ? AND user = ?`, month, user).toArray()[0]?.m ?? 0)
  const open = Number(sql.exec<{ m: number | null }>(`SELECT SUM(micros) AS m FROM user_reservation WHERE month = ? AND user = ?`, month, user).toArray()[0]?.m ?? 0)
  return { spent, open }
}

export const addUserSpend = (sql: SqlStorage, month: string, user: string, micros: number) => {
  if (!(micros > 0)) return
  sql.exec(`INSERT INTO user_month (month, user, usd_micros) VALUES (?, ?, ?) ON CONFLICT (month, user) DO UPDATE SET usd_micros = usd_micros + excluded.usd_micros`, month, user, micros)
}

/** The cost of one usage record to us, in micro-dollars (money meters are USD, count meters at their unit cost). */
export const recordCostMicros = (meter: Meter, quantity: number) => (MONEY_METERS.has(meter) ? quantity * 1_000_000 : quantity * COST_USD_PER_UNIT[meter] * 1_000_000)

export type UserReserve = { readonly ok: true } | { readonly ok: false; readonly spent_usd: number; readonly limit_usd: number }

export const reserveUser = (storage: DurableObjectStorage, month: string, user: string, id: string, maxMicros: number, limitMicros: number, now: number): UserReserve => {
  const sql = storage.sql
  return storage.transactionSync(() => {
    const { spent, open } = userSpentMicros(sql, month, user)
    if (spent + open + maxMicros > limitMicros) return { ok: false as const, spent_usd: Math.round(spent) / 1_000_000, limit_usd: limitMicros / 1_000_000 }
    sql.exec(`INSERT OR REPLACE INTO user_reservation (id, user, month, micros, at) VALUES (?, ?, ?, ?, ?)`, id, user, month, maxMicros, now)
    return { ok: true as const }
  })
}

/** The reservation becomes `actualMicros` of spend in its month; an unknown id (already expired and charged) changes nothing. */
export const settleUser = (storage: DurableObjectStorage, id: string, actualMicros: number | null) => {
  const sql = storage.sql
  storage.transactionSync(() => {
    const row = sql.exec<{ user: string; month: string }>(`SELECT user, month FROM user_reservation WHERE id = ?`, id).toArray()[0]
    if (!row) return
    if (actualMicros !== null) addUserSpend(sql, row.month, row.user, Math.max(0, actualMicros))
    sql.exec(`DELETE FROM user_reservation WHERE id = ?`, id)
  })
}

/** Alarm work: reservations past their TTL are charged in full; old months are dropped. */
export const expireUserReservations = (storage: DurableObjectStorage, now: number, currentMonth: string) => {
  const sql = storage.sql
  storage.transactionSync(() => {
    const stale = sql.exec<{ user: string; month: string; micros: number }>(`SELECT user, month, micros FROM user_reservation WHERE at < ?`, now - USER_RESERVATION_TTL_MS).toArray()
    for (const r of stale) addUserSpend(sql, r.month, r.user, Number(r.micros))
    sql.exec(`DELETE FROM user_reservation WHERE at < ?`, now - USER_RESERVATION_TTL_MS)
    const [y, m] = currentMonth.split("-").map(Number) as [number, number]
    const oldest = new Date(Date.UTC(y, m - KEEP_MONTHS, 1)).toISOString().slice(0, 7)
    sql.exec(`DELETE FROM user_month WHERE month < ?`, oldest)
  })
}

export const nextUserWake = (sql: SqlStorage): number | null => {
  const at = sql.exec<{ at: number | null }>(`SELECT MIN(at) AS at FROM user_reservation`).toArray()[0]?.at
  return at === null || at === undefined ? null : Number(at) + USER_RESERVATION_TTL_MS
}

/** Start of the next UTC month (ms): when a member's limit resets. */
export const nextMonthStart = (now: number) => {
  const d = new Date(now)
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1)
}
