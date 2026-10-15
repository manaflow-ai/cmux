import type { IncludedMode } from "./billing-catalog.ts"

/**
 * UsageMeterDO's billing tables (cx-y79zh S4/S5): what the usage sync sent per subscription period
 * (usage_push), and the billable subscriptions it saw for the team (usage_billable). The DO is the
 * only writer; the sync and the console read through its RPCs.
 */

/** The mode and seats a push was made in (S5 included modes); rows from before them are per team, 1 seat. */
export interface PushInfo {
  readonly mode: IncludedMode
  readonly seats: number
  readonly included_usd: number
  /** The value sent to the meter (micro-dollars): the whole level per team, the level above included x seats per seat. */
  readonly sent_micros: number
  /** The event's timestamp (s): the next push of the period is dated after it. */
  readonly event_ts?: number
}

/** What the sync saw on its last run for a billable subscription, for the console (team.ai_limit.get). */
export interface BillableInfo {
  readonly period_start: number
  readonly mode: IncludedMode
  readonly seats: number
  readonly included_usd: number
}

const addColumns = (sql: SqlStorage, table: string, cols: ReadonlyArray<[string, string]>) => {
  const have = new Set(sql.exec<{ name: string }>(`PRAGMA table_info(${table})`).toArray().map((c) => c.name))
  for (const [name, type] of cols) if (!have.has(name)) sql.exec(`ALTER TABLE ${table} ADD COLUMN ${name} ${type}`)
}

export const ensureBillingTables = (sql: SqlStorage) => {
  // The last level the usage sync sent to the payment service, per subscription and period (cx-y79zh S4).
  sql.exec(`CREATE TABLE IF NOT EXISTS usage_push (subscription TEXT NOT NULL, period_start INTEGER NOT NULL, period_end INTEGER NOT NULL, identifier TEXT NOT NULL, micros INTEGER NOT NULL, pushed_at INTEGER NOT NULL, PRIMARY KEY (subscription, period_start))`)
  // Billable subscriptions the usage sync saw for this team (the included-amount stop, cx-y79zh S5).
  sql.exec(`CREATE TABLE IF NOT EXISTS usage_billable (subscription TEXT PRIMARY KEY, period_end INTEGER NOT NULL, seen_at INTEGER NOT NULL)`)
  // An object made with the first usage_push shape (no period_end) gets the column; 0 = unknown, never a final push (review P2).
  addColumns(sql, "usage_push", [["period_end", "INTEGER NOT NULL DEFAULT 0"], ["mode", "TEXT"], ["seats", "INTEGER NOT NULL DEFAULT 1"], ["included_usd", "REAL"], ["sent_micros", "INTEGER"], ["event_ts", "INTEGER"]])
  addColumns(sql, "usage_billable", [["period_start", "INTEGER"], ["mode", "TEXT"], ["seats", "INTEGER"], ["included_usd", "REAL"]])
  // The operator's included-mode setting for a Team customer (cx-y79zh.1, Lawrence 2026-10-14), every change kept.
  sql.exec(`CREATE TABLE IF NOT EXISTS usage_mode_setting (seq INTEGER PRIMARY KEY AUTOINCREMENT, mode TEXT NOT NULL, set_at INTEGER NOT NULL, actor TEXT NOT NULL, reason TEXT)`)
}

/**
 * The team's included mode for a period that starts at `periodStartMs`: the last setting made at or
 * before that start, so a change applies from the next period start, never inside a running period.
 * New teams (no setting) are per team.
 */
export const teamModeAt = (sql: SqlStorage, periodStartMs: number): IncludedMode =>
  modeOf(sql.exec<{ mode: string }>(`SELECT mode FROM usage_mode_setting WHERE set_at <= ? ORDER BY set_at DESC, seq DESC LIMIT 1`, periodStartMs).toArray()[0]?.mode)

export interface ModeChange {
  readonly mode: IncludedMode
  readonly set_at: number
  readonly actor: string
  readonly reason: string | null
}

/** The setting history, newest first, and the mode the latest setting asks for. */
export const teamModeHistory = (sql: SqlStorage, limit = 20): { readonly requested: IncludedMode; readonly changes: ReadonlyArray<ModeChange> } => {
  const changes = sql.exec<{ mode: string; set_at: number; actor: string; reason: string | null }>(`SELECT mode, set_at, actor, reason FROM usage_mode_setting ORDER BY set_at DESC, seq DESC LIMIT ?`, limit).toArray().map((r) => ({ mode: modeOf(r.mode), set_at: Number(r.set_at), actor: r.actor, reason: r.reason }))
  return { requested: changes[0]?.mode ?? "per_team", changes }
}

/** Records an operator's setting (a no-op when the latest setting already asks for `mode`). */
export const setTeamMode = (sql: SqlStorage, mode: IncludedMode, actor: string, reason: string | null, now: number): { readonly before: IncludedMode; readonly changed: boolean } => {
  const before = teamModeHistory(sql, 1).requested
  const hasAny = sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM usage_mode_setting`).one().n > 0
  if (before === mode && hasAny) return { before, changed: false }
  sql.exec(`INSERT INTO usage_mode_setting (mode, set_at, actor, reason) VALUES (?, ?, ?, ?)`, mode, now, actor, reason)
  return { before, changed: true }
}

/** How far back a billable subscription's seats count for the stop of a per-seat team (its current or previous period). */
export const SEATS_MEMORY_MS = 35 * 24 * 3600_000
/**
 * The seats of the team's latest billable subscription whose period ended at most SEATS_MEMORY_MS ago, for the
 * stop of a per-seat team; 1 when none (review P3: a lapsed subscription's peak seats do not count for ever).
 */
export const lastSeenSeats = (sql: SqlStorage, now: number): number =>
  Math.max(1, Number(sql.exec<{ seats: number | null }>(`SELECT seats FROM usage_billable WHERE period_end * 1000 > ? ORDER BY seen_at DESC LIMIT 1`, now - SEATS_MEMORY_MS).toArray()[0]?.seats ?? 1))

const modeOf = (v: unknown): IncludedMode => (v === "per_seat" ? "per_seat" : "per_team")

export const markBillable = (sql: SqlStorage, subscription: string, periodEnd: number, now: number, info?: BillableInfo) =>
  sql.exec(
    `INSERT INTO usage_billable (subscription, period_end, seen_at, period_start, mode, seats, included_usd) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (subscription) DO UPDATE SET period_end = excluded.period_end, seen_at = excluded.seen_at, period_start = excluded.period_start, mode = excluded.mode, seats = excluded.seats, included_usd = excluded.included_usd`,
    subscription, periodEnd, now, info?.period_start ?? null, info?.mode ?? null, info?.seats ?? null, info?.included_usd ?? null
  )

/** The freshest billable mark that is still in force (BILLABLE_GRACE_MS, usage-user.ts), with what the sync saw. */
export const currentBillable = (sql: SqlStorage, now: number, graceMs: number): ({ subscription: string; period_end: number } & Partial<BillableInfo>) | null => {
  const row = sql.exec<{ subscription: string; period_end: number; period_start: number | null; mode: string | null; seats: number | null; included_usd: number | null }>(
    `SELECT subscription, period_end, period_start, mode, seats, included_usd FROM usage_billable WHERE period_end * 1000 + ? > ? AND seen_at > ? ORDER BY seen_at DESC LIMIT 1`,
    graceMs, now, now - graceMs
  ).toArray()[0]
  if (!row) return null
  return {
    subscription: row.subscription,
    period_end: Number(row.period_end),
    ...(row.period_start !== null ? { period_start: Number(row.period_start) } : {}),
    ...(row.mode !== null ? { mode: modeOf(row.mode) } : {}),
    ...(row.seats !== null ? { seats: Number(row.seats) } : {}),
    ...(row.included_usd !== null ? { included_usd: Number(row.included_usd) } : {})
  }
}

export const pushState = (sql: SqlStorage, subscription: string, periodStart: number): { identifier: string; mode: IncludedMode; seats: number; event_ts: number | null } | null => {
  const row = sql.exec<{ identifier: string; mode: string | null; seats: number; event_ts: number | null }>(`SELECT identifier, mode, seats, event_ts FROM usage_push WHERE subscription = ? AND period_start = ?`, subscription, periodStart).toArray()[0]
  return row ? { identifier: row.identifier, mode: modeOf(row.mode), seats: Math.max(1, Number(row.seats ?? 1)), event_ts: row.event_ts === null ? null : Number(row.event_ts) } : null
}

export const recordPush = (sql: SqlStorage, subscription: string, periodStart: number, periodEnd: number, identifier: string, micros: number, now: number, info?: PushInfo) =>
  sql.exec(
    `INSERT INTO usage_push (subscription, period_start, period_end, identifier, micros, pushed_at, mode, seats, included_usd, sent_micros, event_ts) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (subscription, period_start) DO UPDATE SET period_end = excluded.period_end, identifier = excluded.identifier, micros = excluded.micros, pushed_at = excluded.pushed_at, mode = excluded.mode, seats = excluded.seats, included_usd = excluded.included_usd, sent_micros = excluded.sent_micros, event_ts = excluded.event_ts`,
    subscription, periodStart, periodEnd, identifier, micros, now, info?.mode ?? "per_team", info?.seats ?? 1, info?.included_usd ?? null, info?.sent_micros ?? micros, info?.event_ts ?? null
  )

/** The latest period before `beforeStart` that the sync sent for this subscription, with its mode and seats (its final push after renewal). */
export const previousPush = (sql: SqlStorage, subscription: string, beforeStart: number): { period_start: number; period_end: number; mode: IncludedMode; seats: number; included_usd: number | null } | null => {
  const row = sql.exec<{ period_start: number; period_end: number; mode: string | null; seats: number; included_usd: number | null }>(
    `SELECT period_start, period_end, mode, seats, included_usd FROM usage_push WHERE subscription = ? AND period_start < ? AND period_end > 0 ORDER BY period_start DESC LIMIT 1`,
    subscription, beforeStart
  ).toArray()[0]
  return row ? { period_start: Number(row.period_start), period_end: Number(row.period_end), mode: modeOf(row.mode), seats: Math.max(1, Number(row.seats ?? 1)), included_usd: row.included_usd === null ? null : Number(row.included_usd) } : null
}
