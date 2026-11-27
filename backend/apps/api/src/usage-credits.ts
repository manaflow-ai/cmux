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

/** `opening`: the mirror's first run records the balance the ledger rows do not explain (rows pruned before it started); it never moves the balance. */
export type CreditEntryKind = "topup" | "grant" | "charge" | "expired" | "correction" | "opening"

export type CreditReserve =
  | { readonly ok: true; readonly held_micros: number; readonly replayed: boolean }
  | { readonly ok: false; readonly code: "credits.insufficient"; readonly balance_micros: number; readonly available_micros: number; readonly needed_micros: number }
  | { readonly ok: false; readonly code: "credits.settled" }
  | { readonly ok: false; readonly code: "credits.rate_limited"; readonly calls: number; readonly limit: number; readonly window_s: number; readonly retry_after_s: number }

/**
 * Paid model calls one chief may start per window (holds plus charges), counted in this ledger so
 * an object restart cannot reset it. The guard after the 2026-10-28 staging drain (looping
 * compactors at up to 365 calls a minute per chief). Over a cap the hold is refused (fails closed).
 */
export interface ChiefCallCap {
  readonly perMinute: number
  readonly perHour: number
}

export interface CreditBalance {
  readonly balance_micros: number
  readonly held_micros: number
  readonly available_micros: number
  /** Price charged per chief in the window (newest first by spend). */
  readonly chiefs: ReadonlyArray<{ readonly chief: string; readonly micros: number; readonly calls: number; readonly last_at: number }>
  readonly entries: ReadonlyArray<{ readonly key: string; readonly kind: CreditEntryKind; readonly micros: number; readonly chief: string | null; readonly at: number; readonly reason: string | null }>
}

export const ensureCreditTables = (storage: DurableObjectStorage) => {
  const sql = storage.sql
  sql.exec(`CREATE TABLE IF NOT EXISTS credit_entry (key TEXT PRIMARY KEY, kind TEXT NOT NULL, micros INTEGER NOT NULL, cost_micros INTEGER, chief TEXT, conversation TEXT, actor TEXT, reason TEXT, corrects TEXT, at INTEGER NOT NULL)`)
  sql.exec(`CREATE INDEX IF NOT EXISTS credit_entry_at ON credit_entry (at)`)
  sql.exec(`CREATE INDEX IF NOT EXISTS credit_entry_chief ON credit_entry (chief, at)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS credit_hold (id TEXT PRIMARY KEY, micros INTEGER NOT NULL, chief TEXT, conversation TEXT, at INTEGER NOT NULL)`)
  sql.exec(`CREATE INDEX IF NOT EXISTS credit_hold_chief ON credit_hold (chief, at)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS credit_state (id INTEGER PRIMARY KEY CHECK (id = 1), balance INTEGER NOT NULL)`)
  // The conversations told "out of credits" since the balance was last positive (one notice each).
  sql.exec(`CREATE TABLE IF NOT EXISTS credit_notice (conversation TEXT PRIMARY KEY, at INTEGER NOT NULL)`)
  // The payment-service customer of this team, per key mode (test, live): one customer per team.
  sql.exec(`CREATE TABLE IF NOT EXISTS credit_customer (mode TEXT PRIMARY KEY, customer TEXT NOT NULL, at INTEGER NOT NULL)`)
  // The mirror to the billing database (credits-mirror.ts): what it has, when it may try again.
  sql.exec(`CREATE TABLE IF NOT EXISTS credit_mirror (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL, failures INTEGER NOT NULL, next_at INTEGER NOT NULL)`)
  // Mirror columns (objects from before the mirror get them): an entry's team-local sequence and
  // whether the mirror has it; the state's version (every entry, hold or customer change) and last seq.
  // Each block is one transaction (a half-applied block would leave the object broken for good).
  const entryCols = new Set(sql.exec<{ name: string }>(`PRAGMA table_info(credit_entry)`).toArray().map((c) => c.name))
  if (!entryCols.has("seq")) {
    storage.transactionSync(() => {
      sql.exec(`ALTER TABLE credit_entry ADD COLUMN seq INTEGER`)
      sql.exec(`ALTER TABLE credit_entry ADD COLUMN mirrored INTEGER NOT NULL DEFAULT 0`)
      sql.exec(`UPDATE credit_entry SET seq = (SELECT n FROM (SELECT rowid AS r, ROW_NUMBER() OVER (ORDER BY rowid) AS n FROM credit_entry) WHERE r = credit_entry.rowid)`)
    })
  }
  sql.exec(`CREATE INDEX IF NOT EXISTS credit_entry_unmirrored ON credit_entry (mirrored, seq)`)
  const stateCols = new Set(sql.exec<{ name: string }>(`PRAGMA table_info(credit_state)`).toArray().map((c) => c.name))
  if (!stateCols.has("version")) {
    storage.transactionSync(() => {
      sql.exec(`ALTER TABLE credit_state ADD COLUMN version INTEGER NOT NULL DEFAULT 0`)
      sql.exec(`ALTER TABLE credit_state ADD COLUMN last_seq INTEGER NOT NULL DEFAULT 0`)
      sql.exec(`ALTER TABLE credit_state ADD COLUMN changed_at INTEGER NOT NULL DEFAULT 0`)
      sql.exec(`UPDATE credit_state SET last_seq = (SELECT COALESCE(MAX(seq), 0) FROM credit_entry), version = (SELECT COUNT(*) FROM credit_entry)`)
    })
  }
  if (!stateCols.has("dirty_since")) sql.exec(`ALTER TABLE credit_state ADD COLUMN dirty_since INTEGER`)
  const mirrorCols = new Set(sql.exec<{ name: string }>(`PRAGMA table_info(credit_mirror)`).toArray().map((c) => c.name))
  if (!mirrorCols.has("opened")) sql.exec(`ALTER TABLE credit_mirror ADD COLUMN opened INTEGER NOT NULL DEFAULT 0`)
}

/** Longest entry key the billing database takes (credit_ledger.entry_key is 255; a key may get ":late"). */
export const MAX_CREDIT_ID = 200

/** Every change the mirror must carry (an entry, a hold, a customer) moves the state's version. */
const touch = (sql: SqlStorage, now: number) =>
  sql.exec(`INSERT INTO credit_state (id, balance, version, last_seq, changed_at, dirty_since) VALUES (1, 0, 1, 0, ?, ?) ON CONFLICT (id) DO UPDATE SET version = version + 1, changed_at = excluded.changed_at, dirty_since = COALESCE(dirty_since, excluded.dirty_since)`, now, now)

const balanceOf = (sql: SqlStorage) => Number(sql.exec<{ b: number }>(`SELECT balance AS b FROM credit_state WHERE id = 1`).toArray()[0]?.b ?? 0)
const heldOf = (sql: SqlStorage) => Number(sql.exec<{ m: number | null }>(`SELECT SUM(micros) AS m FROM credit_hold`).toArray()[0]?.m ?? 0)

type Entry = { key: string; kind: CreditEntryKind; micros: number; cost?: number | null; chief?: string | null; conversation?: string | null; actor?: string | null; reason?: string | null; corrects?: string | null }

/** One ledger row and the balance, in the caller's transaction. False for a key already written (nothing counted). */
const writeEntry = (sql: SqlStorage, e: Entry, now: number): boolean => {
  const inserted = sql.exec(
    `INSERT OR IGNORE INTO credit_entry (key, kind, micros, cost_micros, chief, conversation, actor, reason, corrects, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    // Text sized to the billing database's columns (actor 128, reason 256), so the mirror never refuses a row.
    e.key, e.kind, e.micros, e.cost ?? null, e.chief ?? null, e.conversation ?? null, e.actor?.slice(0, 128) ?? null, e.reason?.slice(0, 256) ?? null, e.corrects ?? null, now
  ).rowsWritten
  if (inserted === 0) return false
  touch(sql, now)
  sql.exec(`UPDATE credit_state SET balance = balance + ?, last_seq = last_seq + 1 WHERE id = 1`, e.micros)
  sql.exec(`UPDATE credit_entry SET seq = (SELECT last_seq FROM credit_state WHERE id = 1) WHERE key = ?`, e.key)
  // Money came in: every conversation may be told again when it runs out next time.
  if (e.micros > 0 && balanceOf(sql) > 0) sql.exec(`DELETE FROM credit_notice`)
  return true
}

/** Money in (a paid top-up or an operator grant). `key` makes it count once. */
export const creditAdd = (storage: DurableObjectStorage, key: string, kind: "topup" | "grant", micros: number, actor: string, reason: string | null, now: number): { added: boolean; balance_micros: number } => {
  checkId(key)
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
/** Ids the billing database takes (ascii columns): printable ASCII, no spaces. */
const ASCII_ID = /^[\x21-\x7e]+$/
const checkId = (id: string, max = MAX_CREDIT_ID) => {
  if (id.length === 0 || id.length > max || !ASCII_ID.test(id)) throw new Error(`credit id must be 1-${max} printable ASCII characters`)
}
const checkRef = (v: string | null) => {
  if (v !== null) checkId(v, 64)
}

/** The chief's calls started since `since` (open holds and charges; a released hold never reached a provider) and the oldest one's time. */
const chiefCalls = (sql: SqlStorage, chief: string, since: number): { n: number; oldest: number } => {
  const e = sql.exec<{ n: number; t: number | null }>(`SELECT COUNT(*) AS n, MIN(at) AS t FROM credit_entry WHERE chief = ? AND at >= ? AND kind IN ('charge', 'expired')`, chief, since).one()
  const h = sql.exec<{ n: number; t: number | null }>(`SELECT COUNT(*) AS n, MIN(at) AS t FROM credit_hold WHERE chief = ? AND at >= ?`, chief, since).one()
  const times = [e.t, h.t].filter((t): t is number => t !== null).map(Number)
  return { n: Number(e.n) + Number(h.n), oldest: times.length > 0 ? Math.min(...times) : since }
}

/** The first window of `cap` this chief is over, or null. */
const overCap = (sql: SqlStorage, chief: string, cap: ChiefCallCap, now: number): Extract<CreditReserve, { code: "credits.rate_limited" }> | null => {
  for (const [limit, windowMs] of [[cap.perMinute, 60_000], [cap.perHour, 3600_000]] as const) {
    if (!(limit > 0)) continue
    const c = chiefCalls(sql, chief, now - windowMs)
    if (c.n >= limit) return { ok: false, code: "credits.rate_limited", calls: c.n, limit, window_s: windowMs / 1000, retry_after_s: Math.max(1, Math.ceil((c.oldest + windowMs - now) / 1000)) }
  }
  return null
}

export const creditReserve = (storage: DurableObjectStorage, id: string, maxMicros: number, chief: string | null, conversation: string | null, now: number, cap?: ChiefCallCap): CreditReserve => {
  checkId(id)
  checkRef(chief)
  checkRef(conversation)
  const sql = storage.sql
  const max = Math.max(0, Math.ceil(maxMicros))
  return storage.transactionSync((): CreditReserve => {
    const open = sql.exec<{ micros: number }>(`SELECT micros FROM credit_hold WHERE id = ?`, id).toArray()[0]
    if (open) return { ok: true, held_micros: Number(open.micros), replayed: true }
    if (sql.exec(`SELECT 1 FROM credit_entry WHERE key = ?`, `charge:${id}`).toArray().length > 0) return { ok: false, code: "credits.settled" }
    const limited = chief !== null && cap ? overCap(sql, chief, cap, now) : null
    if (limited) return limited
    const balance = balanceOf(sql)
    const available = balance - heldOf(sql)
    if (available <= 0 || available < max) return { ok: false, code: "credits.insufficient", balance_micros: balance, available_micros: available, needed_micros: max }
    sql.exec(`INSERT INTO credit_hold (id, micros, chief, conversation, at) VALUES (?, ?, ?, ?, ?)`, id, max, chief, conversation, now)
    touch(sql, now)
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
  checkId(id)
  checkRef(chief)
  checkRef(conversation)
  const sql = storage.sql
  const price = Math.max(0, Math.round(priceMicros))
  return storage.transactionSync(() => {
    const hold = sql.exec<{ chief: string | null; conversation: string | null }>(`SELECT chief, conversation FROM credit_hold WHERE id = ?`, id).toArray()[0]
    if (hold) [sql.exec(`DELETE FROM credit_hold WHERE id = ?`, id), touch(sql, now)]
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
export const creditRelease = (storage: DurableObjectStorage, id: string, now: number): boolean =>
  storage.transactionSync(() => {
    const gone = storage.sql.exec(`DELETE FROM credit_hold WHERE id = ?`, id).rowsWritten > 0
    if (gone) touch(storage.sql, now)
    return gone
  })

/** Alarm work: holds past their TTL are charged in full (kind `expired`); old charge rows are pruned. */
/** `mirrored`: the billing database mirror is on here, so a charge row leaves only after it was mirrored. */
export const expireCreditHolds = (storage: DurableObjectStorage, now: number, mirrored: boolean) => {
  const sql = storage.sql
  storage.transactionSync(() => {
    const stale = sql.exec<{ id: string; micros: number; chief: string | null; conversation: string | null }>(`SELECT id, micros, chief, conversation FROM credit_hold WHERE at <= ?`, now - CREDIT_HOLD_TTL_MS).toArray()
    for (const h of stale) writeEntry(sql, { key: `charge:${h.id}`, kind: "expired", micros: -Number(h.micros), chief: h.chief, conversation: h.conversation, reason: "not settled within an hour" }, now)
    if (sql.exec(`DELETE FROM credit_hold WHERE at <= ?`, now - CREDIT_HOLD_TTL_MS).rowsWritten > 0) touch(sql, now)
    // Only rows the billing database already has leave the hot copy.
    sql.exec(`DELETE FROM credit_entry WHERE kind IN ('charge', 'expired', 'correction') AND (mirrored = 1 OR ? = 0) AND at < ?`, mirrored ? 1 : 0, now - CREDIT_CHARGE_RETENTION_MS)
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

/** The team's payment-service customer for a key mode, or null. */
export const creditCustomer = (sql: SqlStorage, mode: "test" | "live"): string | null => sql.exec<{ customer: string }>(`SELECT customer FROM credit_customer WHERE mode = ?`, mode).toArray()[0]?.customer ?? null

/** Records the team's customer for a mode (first one wins: one customer per team). */
export const setCreditCustomer = (storage: DurableObjectStorage, mode: "test" | "live", customer: string, now: number): string =>
  storage.transactionSync(() => {
    const known = creditCustomer(storage.sql, mode)
    if (known) return known
    storage.sql.exec(`INSERT INTO credit_customer (mode, customer, at) VALUES (?, ?, ?)`, mode, customer, now)
    touch(storage.sql, now)
    return customer
  })
