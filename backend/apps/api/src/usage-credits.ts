/**
 * Prepaid credits of a team (hosted Cloud Chief, Lawrence 2026-10-15: "people must load credits to
 * use it"), kept by the team's UsageMeterDO (the personal team for a person). Money is integer
 * micro-dollars at the price the team pays (provider cost x margin, credits.ts).
 *
 * - `credit_entry` is the ledger: one row per top-up, grant, charge, expiry or correction, keyed so
 *   that a repeat of the same event counts once (`topup:<checkout session>`, `grant:<key>`,
 *   `charge:<request id>`). `credit_state.balance` is the sum, written in the same transaction.
 * - A model call reserves its maximum price first (`credit_hold`). It is refused when the balance
 *   minus the open holds is below that maximum, or is not above zero. Settle replaces the hold
 *   with the real price; a hold never settled is charged in full after CREDIT_HOLD_TTL_MS (the
 *   DO's alarm), and a late settle writes the difference as a correction.
 * - Separate from the usage bill (usage_ledger model.spend_usd): a prepaid charge is never a
 *   billable fact, so the same call is never paid twice.
 */
export const CREDIT_HOLD_TTL_MS = 3600_000
/** Charge rows older than this are pruned; top-ups, grants and the balance stay. */
export const CREDIT_CHARGE_RETENTION_MS = 400 * 24 * 3600_000

export type CreditEntryKind = "topup" | "grant" | "charge" | "expired" | "correction"

export type CreditReserve =
  | { readonly ok: true; readonly held_micros: number; readonly replayed: boolean }
  | { readonly ok: false; readonly code: "credits.insufficient"; readonly balance_micros: number; readonly available_micros: number; readonly needed_micros: number }
  | { readonly ok: false; readonly code: "credits.settled" }

export interface CreditBalance {
  readonly balance_micros: number
  readonly held_micros: number
  readonly available_micros: number
  /** Price charged per chief in the window (newest first by spend). */
  readonly chiefs: ReadonlyArray<{ readonly chief: string; readonly micros: number; readonly calls: number; readonly last_at: number }>
  readonly entries: ReadonlyArray<{ readonly key: string; readonly kind: CreditEntryKind; readonly micros: number; readonly chief: string | null; readonly at: number; readonly reason: string | null }>
}

export const ensureCreditTables = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS credit_entry (key TEXT PRIMARY KEY, kind TEXT NOT NULL, micros INTEGER NOT NULL, cost_micros INTEGER, chief TEXT, conversation TEXT, actor TEXT, reason TEXT, corrects TEXT, at INTEGER NOT NULL)`)
  sql.exec(`CREATE INDEX IF NOT EXISTS credit_entry_at ON credit_entry (at)`)
  sql.exec(`CREATE INDEX IF NOT EXISTS credit_entry_chief ON credit_entry (chief, at)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS credit_hold (id TEXT PRIMARY KEY, micros INTEGER NOT NULL, chief TEXT, conversation TEXT, at INTEGER NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS credit_state (id INTEGER PRIMARY KEY CHECK (id = 1), balance INTEGER NOT NULL)`)
  // The conversations told "out of credits" since the balance was last positive (one notice each).
  sql.exec(`CREATE TABLE IF NOT EXISTS credit_notice (conversation TEXT PRIMARY KEY, at INTEGER NOT NULL)`)
}

const balanceOf = (sql: SqlStorage) => Number(sql.exec<{ b: number }>(`SELECT balance AS b FROM credit_state WHERE id = 1`).toArray()[0]?.b ?? 0)
const heldOf = (sql: SqlStorage) => Number(sql.exec<{ m: number | null }>(`SELECT SUM(micros) AS m FROM credit_hold`).toArray()[0]?.m ?? 0)

type Entry = { key: string; kind: CreditEntryKind; micros: number; cost?: number | null; chief?: string | null; conversation?: string | null; actor?: string | null; reason?: string | null; corrects?: string | null }

/** One ledger row and the balance, in the caller's transaction. False for a key already written (nothing counted). */
const writeEntry = (sql: SqlStorage, e: Entry, now: number): boolean => {
  const inserted = sql.exec(
    `INSERT OR IGNORE INTO credit_entry (key, kind, micros, cost_micros, chief, conversation, actor, reason, corrects, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    e.key, e.kind, e.micros, e.cost ?? null, e.chief ?? null, e.conversation ?? null, e.actor ?? null, e.reason ?? null, e.corrects ?? null, now
  ).rowsWritten
  if (inserted === 0) return false
  sql.exec(`INSERT INTO credit_state (id, balance) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET balance = balance + excluded.balance`, e.micros)
  // Money came in: every conversation may be told again when it runs out next time.
  if (e.micros > 0 && balanceOf(sql) > 0) sql.exec(`DELETE FROM credit_notice`)
  return true
}

/** Money in (a paid top-up or an operator grant). `key` makes it count once. */
export const creditAdd = (storage: DurableObjectStorage, key: string, kind: "topup" | "grant", micros: number, actor: string, reason: string | null, now: number): { added: boolean; balance_micros: number } => {
  const sql = storage.sql
  return storage.transactionSync(() => {
    const added = writeEntry(sql, { key, kind, micros: Math.round(micros), actor, reason }, now)
    return { added, balance_micros: balanceOf(sql) }
  })
}

/**
 * Reserve `maxMicros` for request `id` before the model call. The same id again returns its open
 * hold (a retried RPC or a recovered request); an id already charged is refused with
 * `credits.settled` (the caller's next attempt needs a new id).
 */
export const creditReserve = (storage: DurableObjectStorage, id: string, maxMicros: number, chief: string | null, conversation: string | null, now: number): CreditReserve => {
  const sql = storage.sql
  const max = Math.max(0, Math.ceil(maxMicros))
  return storage.transactionSync((): CreditReserve => {
    const open = sql.exec<{ micros: number }>(`SELECT micros FROM credit_hold WHERE id = ?`, id).toArray()[0]
    if (open) return { ok: true, held_micros: Number(open.micros), replayed: true }
    if (sql.exec(`SELECT 1 FROM credit_entry WHERE key = ?`, `charge:${id}`).toArray().length > 0) return { ok: false, code: "credits.settled" }
    const balance = balanceOf(sql)
    const available = balance - heldOf(sql)
    if (available <= 0 || available < max) return { ok: false, code: "credits.insufficient", balance_micros: balance, available_micros: available, needed_micros: max }
    sql.exec(`INSERT INTO credit_hold (id, micros, chief, conversation, at) VALUES (?, ?, ?, ?, ?)`, id, max, chief, conversation, now)
    return { ok: true, held_micros: max, replayed: false }
  })
}

/**
 * The call ended: its hold becomes one charge of `priceMicros` (cost x margin; `costMicros` is
 * kept for audit). Without a hold the call is still charged once (a call that never reserved, for
 * example background work); after the alarm already charged the hold in full, the difference is a
 * correction `charge:<id>:late`. Returns the balance after.
 */
export const creditSettle = (storage: DurableObjectStorage, id: string, priceMicros: number, costMicros: number, chief: string | null, conversation: string | null, now: number): { charged: boolean; balance_micros: number } => {
  const sql = storage.sql
  const price = Math.max(0, Math.round(priceMicros))
  return storage.transactionSync(() => {
    const hold = sql.exec<{ chief: string | null; conversation: string | null }>(`SELECT chief, conversation FROM credit_hold WHERE id = ?`, id).toArray()[0]
    if (hold) sql.exec(`DELETE FROM credit_hold WHERE id = ?`, id)
    const expired = sql.exec<{ micros: number; chief: string | null; conversation: string | null }>(`SELECT micros, chief, conversation FROM credit_entry WHERE key = ? AND kind = 'expired'`, `charge:${id}`).toArray()[0]
    let charged = false
    if (expired) {
      const delta = -price - Number(expired.micros)
      if (delta !== 0) charged = writeEntry(sql, { key: `charge:${id}:late`, kind: "correction", micros: delta, cost: Math.round(costMicros), chief: expired.chief, conversation: expired.conversation, corrects: `charge:${id}` }, now)
    } else {
      charged = writeEntry(sql, { key: `charge:${id}`, kind: "charge", micros: -price, cost: Math.round(costMicros), chief: hold?.chief ?? chief, conversation: hold?.conversation ?? conversation }, now)
    }
    return { charged, balance_micros: balanceOf(sql) }
  })
}

/** The call never reached a provider: the hold goes, nothing is charged. */
export const creditRelease = (storage: DurableObjectStorage, id: string): boolean => storage.sql.exec(`DELETE FROM credit_hold WHERE id = ?`, id).rowsWritten > 0

/** Alarm work: holds past their TTL are charged in full (kind `expired`); old charge rows are pruned. */
export const expireCreditHolds = (storage: DurableObjectStorage, now: number) => {
  const sql = storage.sql
  storage.transactionSync(() => {
    const stale = sql.exec<{ id: string; micros: number; chief: string | null; conversation: string | null }>(`SELECT id, micros, chief, conversation FROM credit_hold WHERE at < ?`, now - CREDIT_HOLD_TTL_MS).toArray()
    for (const h of stale) writeEntry(sql, { key: `charge:${h.id}`, kind: "expired", micros: -Number(h.micros), chief: h.chief, conversation: h.conversation, reason: "not settled within an hour" }, now)
    sql.exec(`DELETE FROM credit_hold WHERE at < ?`, now - CREDIT_HOLD_TTL_MS)
    sql.exec(`DELETE FROM credit_entry WHERE kind IN ('charge', 'expired', 'correction') AND at < ?`, now - CREDIT_CHARGE_RETENTION_MS)
  })
}

export const nextCreditWake = (sql: SqlStorage): number | null => {
  const at = sql.exec<{ at: number | null }>(`SELECT MIN(at) AS at FROM credit_hold`).toArray()[0]?.at
  return at === null || at === undefined ? null : Number(at) + CREDIT_HOLD_TTL_MS
}

/** True once per conversation while the team has no credits (the brain's one "out of credits" notice). */
export const creditNoticeOnce = (sql: SqlStorage, conversation: string, now: number): boolean => sql.exec(`INSERT OR IGNORE INTO credit_notice (conversation, at) VALUES (?, ?)`, conversation, now).rowsWritten > 0

/** The balance read: balance, open holds, spend per chief since `since`, and the newest entries. */
export const creditBalance = (sql: SqlStorage, since: number, limit: number): CreditBalance => {
  const balance = balanceOf(sql)
  const held = heldOf(sql)
  const chiefs = sql
    .exec<{ chief: string; micros: number; calls: number; last_at: number }>(
      `SELECT chief, -SUM(micros) AS micros, SUM(CASE WHEN kind = 'correction' THEN 0 ELSE 1 END) AS calls, MAX(at) AS last_at FROM credit_entry WHERE chief IS NOT NULL AND kind IN ('charge', 'expired', 'correction') AND at >= ? GROUP BY chief ORDER BY micros DESC LIMIT 100`,
      since
    )
    .toArray()
    .map((r) => ({ chief: r.chief, micros: Number(r.micros), calls: Number(r.calls), last_at: Number(r.last_at) }))
  const entries = sql
    .exec<{ key: string; kind: CreditEntryKind; micros: number; chief: string | null; at: number; reason: string | null }>(`SELECT key, kind, micros, chief, at, reason FROM credit_entry ORDER BY at DESC, key DESC LIMIT ?`, limit)
    .toArray()
    .map((r) => ({ key: r.key, kind: r.kind, micros: Number(r.micros), chief: r.chief, at: Number(r.at), reason: r.reason }))
  return { balance_micros: balance, held_micros: held, available_micros: balance - held, chiefs, entries }
}
