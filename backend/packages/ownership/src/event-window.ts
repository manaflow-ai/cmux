import type { Tables } from "./schema.ts"
import type { SqlStore } from "./sql.ts"

/**
 * Event window per owner (DO audit F-3): events go when they are older than `retentionMs`, past
 * the newest `maxEvents`, or past `maxBytes` stored, whichever keeps the fewest, but the newest
 * `floor` always stay (a resume replays at most 1,000 events). Bytes are kept as a running total
 * in meta (`event_bytes`), so no prune scans the log.
 */
export interface EventWindow {
  readonly retentionMs: number
  readonly maxEvents: number
  readonly maxBytes: number
  readonly floor: number
}

/** The default: 30 days, no count cap, at most 256 MB, never fewer than the newest 1,000. */
export const DEFAULT_EVENT_WINDOW: EventWindow = { retentionMs: 30 * 24 * 3600_000, maxEvents: Number.MAX_SAFE_INTEGER, maxBytes: 256 * 1024 * 1024, floor: 1_000 }

const SIZE = `length(params) + length(actor) + coalesce(length(effects), 0)`

/** Stored bytes of the event log (computed once for a log written before the total existed). */
export const eventBytes = (sql: SqlStore, t: Tables): number => {
  const v = sql.exec<{ value: string }>(`SELECT value FROM ${t.meta} WHERE key = 'event_bytes'`)[0]?.value
  if (v !== undefined) return Number(v)
  const total = Number(sql.exec<{ b: number | null }>(`SELECT SUM(${SIZE}) AS b FROM ${t.events}`)[0]?.b ?? 0)
  sql.exec(`INSERT INTO ${t.meta} (key, value) VALUES ('event_bytes', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value`, String(total))
  return total
}

/** Adds one committed event's bytes (inside the commit transaction). */
export const addEventBytes = (sql: SqlStore, t: Tables, bytes: number): void => {
  const total = eventBytes(sql, t) + bytes
  sql.exec(`UPDATE ${t.meta} SET value = ? WHERE key = 'event_bytes'`, String(total))
}

const oldestSeq = (sql: SqlStore, t: Tables): number | null => {
  const s = sql.exec<{ s: number | null }>(`SELECT MIN(seq) AS s FROM ${t.events}`)[0]?.s
  return s === null || s === undefined ? null : Number(s)
}

/** True when the log is past its count or byte cap (the alarm prunes now). */
export const windowOver = (sql: SqlStore, t: Tables, seq: number, w: EventWindow): boolean => {
  const oldest = oldestSeq(sql, t)
  if (oldest === null || seq - oldest + 1 <= w.floor) return false
  return seq - oldest + 1 > w.maxEvents || eventBytes(sql, t) > w.maxBytes
}

/**
 * Deletes one bounded batch of the oldest events past the count or byte cap (never one of the
 * newest `floor`). Returns how many went; the caller repeats while it is above zero.
 */
export const pruneWindow = (sql: SqlStore, t: Tables, seq: number, w: EventWindow, limit = 1000): number =>
  sql.transaction(() => {
    const oldest = oldestSeq(sql, t)
    const floorSeq = seq - w.floor
    if (oldest === null || oldest > floorSeq) return 0
    const byCount = seq - w.maxEvents
    let over = eventBytes(sql, t) - w.maxBytes
    const rows = sql.exec<{ seq: number; b: number }>(`SELECT seq, ${SIZE} AS b FROM ${t.events} WHERE seq <= ? ORDER BY seq LIMIT ?`, floorSeq, limit)
    let upto = 0
    let freed = 0
    for (const r of rows) {
      if (Number(r.seq) > byCount && over <= 0) break
      upto = Number(r.seq)
      freed += Number(r.b)
      over -= Number(r.b)
    }
    if (upto === 0) return 0
    sql.exec(`DELETE FROM ${t.events} WHERE seq <= ?`, upto)
    sql.exec(`UPDATE ${t.meta} SET value = ? WHERE key = 'event_bytes'`, String(Math.max(0, eventBytes(sql, t) - freed)))
    return upto - oldest + 1
  })

/** When the oldest event outside the newest `keepLast` passes the retention, or null. */
export const nextPruneAt = (sql: SqlStore, t: Tables, seq: number, retentionMs: number, keepLast: number): number | null => {
  const floor = seq - keepLast
  if (floor <= 0) return null
  const r = sql.exec<{ at: number | null }>(`SELECT MIN(at) AS at FROM ${t.events} WHERE seq <= ?`, floor)[0]
  return r?.at === null || r?.at === undefined ? null : Number(r.at) + retentionMs
}

/**
 * Deletes a contiguous prefix of the log: events before the first one committed at or after
 * `before`, never one of the newest `keepLast` (so a clock step back cannot leave a hole).
 * Bounded per call; keeps the byte total in step.
 */
export const pruneBefore = (sql: SqlStore, t: Tables, seq: number, before: number, keepLast: number, limit = 1000): number => {
  const floor = seq - keepLast
  if (floor <= 0) return 0
  return sql.transaction(() => {
    const firstKept = sql.exec<{ s: number | null }>(`SELECT MIN(seq) AS s FROM ${t.events} WHERE at >= ?`, before)[0]?.s
    const cut = Math.min(firstKept === null || firstKept === undefined ? floor + 1 : Number(firstKept), floor + 1)
    const oldest = oldestSeq(sql, t)
    if (oldest === null || oldest >= cut) return 0
    const upto = Math.min(cut - 1, oldest + limit - 1)
    const freed = Number(sql.exec<{ b: number | null }>(`SELECT SUM(${SIZE}) AS b FROM ${t.events} WHERE seq <= ?`, upto)[0]?.b ?? 0)
    const total = eventBytes(sql, t)
    sql.exec(`DELETE FROM ${t.events} WHERE seq <= ?`, upto)
    sql.exec(`UPDATE ${t.meta} SET value = ? WHERE key = 'event_bytes'`, String(Math.max(0, total - freed)))
    return upto - oldest + 1
  })
}
