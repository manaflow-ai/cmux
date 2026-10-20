import { dt } from "./projection-mysql.ts"

/**
 * The credits mirror (hq-1f, Lawrence 2026-10-15: the billing source of truth is the PlanetScale
 * Vitess database cmux-next-vitess; the team's UsageMeterDO keeps the hot copy and mirrors to it).
 *
 * Outbox style, from the DO's alarm only, never on a request: every credit_entry row the database
 * does not have yet (`mirrored = 0`, in seq order, at most MIRROR_BATCH per run) goes in with
 * INSERT IGNORE on (team_id, entry_key), so a repeat after a lost answer writes nothing twice; the
 * team's balance and open holds go in as one row guarded by the DO's state version (an older
 * snapshot never overwrites a newer one); the team's payment-service customer per key mode goes in
 * once. Only after the database accepted all of it are the rows marked mirrored. A failure keeps
 * everything as it is and the next try waits (MIRROR_RETRY_MS doubling, at most MIRROR_RETRY_MAX_MS).
 *
 * Tables: backend/db/schema-mysql (credit_ledger, credit_balance, team_billing_customer), migration
 * backend/db/drizzle-mysql/0001_credits.sql. On only where CREDITS_MIRROR is "mysql" and the PS_MYSQL
 * binding exists (development until the staging and production schema steps).
 */
export const MIRROR_BATCH = 500
/** A change waits this long so that one run carries a burst of calls. */
export const MIRROR_DEBOUNCE_MS = 2_000
export const MIRROR_RETRY_MS = 5_000
export const MIRROR_RETRY_MAX_MS = 10 * 60_000
/** A busy team still mirrors at least this often (the debounce never waits longer than this from the first change). */
export const MIRROR_MAX_DELAY_MS = 10_000
/** One run's whole budget (connect excluded): a hung query fails the run instead of holding the alarm. */
export const MIRROR_DEADLINE_MS = 15_000

export interface MirrorClient {
  query(sql: string, values?: Array<unknown>): Promise<unknown>
}

type EntryRow = { key: string; kind: string; micros: number; cost_micros: number | null; chief: string | null; conversation: string | null; actor: string | null; reason: string | null; corrects: string | null; at: number; seq: number }

const LEDGER_COLUMNS = "team_id, entry_key, kind, micros, cost_micros, chief, conversation, actor, reason, corrects, at, seq"

/** The statements one run sends, in order (exported for the MySQL and Vitess tests). */
export const mirrorStatements = (
  team: string,
  entries: ReadonlyArray<EntryRow>,
  state: { balance: number; held: number; version: number; last_seq: number; changed_at: number } | null,
  customers: ReadonlyArray<{ mode: string; customer: string; at: number }>
): Array<[string, Array<unknown>]> => {
  const out: Array<[string, Array<unknown>]> = []
  if (entries.length > 0) {
    out.push([
      // Not INSERT IGNORE: that would also swallow a too-long value or a (team_id, seq) conflict (a DO
      // whose storage was reset) and the rows would be marked mirrored anyway. A repeat of the same key
      // (a lost answer) is the only no-op; a seq taken by another key sets NULL into a NOT NULL column,
      // which strict mode refuses, so the run fails loudly and nothing is marked.
      `INSERT INTO credit_ledger (${LEDGER_COLUMNS}) VALUES ${entries.map(() => "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)").join(", ")} ON DUPLICATE KEY UPDATE \`entry_key\` = IF(\`entry_key\` = VALUES(\`entry_key\`), \`entry_key\`, NULL)`,
      entries.flatMap((e) => [team, e.key, e.kind, Number(e.micros), e.cost_micros === null ? null : Number(e.cost_micros), e.chief, e.conversation, e.actor, e.reason, e.corrects, dt(Number(e.at)), Number(e.seq)])
    ])
  }
  // MySQL assigns left to right: `version` goes last, so every condition sees the stored version.
  const newer = "`version` <= VALUES(`version`)"
  if (state) out.push([
    `INSERT INTO credit_balance (team_id, balance_micros, held_micros, last_seq, changed_at, version) VALUES (?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE ` +
      ["balance_micros", "held_micros", "last_seq", "changed_at"].map((c) => `\`${c}\` = IF(${newer}, VALUES(\`${c}\`), \`${c}\`)`).join(", ") +
      ", `updated_at` = CURRENT_TIMESTAMP(3), `version` = GREATEST(`version`, VALUES(`version`))",
    [team, state.balance, state.held, state.last_seq, dt(state.changed_at || Date.now()), state.version]
  ])
  for (const c of customers) out.push([`INSERT IGNORE INTO team_billing_customer (team_id, mode, customer_id, created_at) VALUES (?, ?, ?, ?)`, [team, c.mode, c.customer, dt(c.at)]])
  return out
}

/** When the mirror should run next (ms), or null when the database has everything. */
export const mirrorDue = (sql: SqlStorage): number | null => {
  const st = sql.exec<{ version: number; changed_at: number; dirty_since: number | null }>(`SELECT version, changed_at, dirty_since FROM credit_state WHERE id = 1`).toArray()[0]
  if (!st) return null
  const m = sql.exec<{ version: number; next_at: number }>(`SELECT version, next_at FROM credit_mirror WHERE id = 1`).toArray()[0]
  const pending = sql.exec(`SELECT 1 FROM credit_entry WHERE mirrored = 0 LIMIT 1`).toArray().length > 0
  if (!pending && Number(st.version) <= Number(m?.version ?? -1)) return null
  // Debounced from the newest change, but never later than MIRROR_MAX_DELAY_MS after the first one.
  const quiet = Number(st.changed_at) + MIRROR_DEBOUNCE_MS
  const cap = st.dirty_since === null ? quiet : Number(st.dirty_since) + MIRROR_MAX_DELAY_MS
  return Math.max(Number(m?.next_at ?? 0), Math.min(quiet, cap))
}

/**
 * Before a team's first mirror run: when its ledger rows do not sum to its balance (charge rows pruned
 * while no mirror ran), one `opening:<seq>` entry records the difference, so the billing database's
 * ledger always sums to the balance. It never moves the balance. Returns the opening micros (0: none).
 */
export const openMirror = (storage: DurableObjectStorage, now: number): number => {
  const sql = storage.sql
  return storage.transactionSync(() => {
    const m = sql.exec<{ opened: number }>(`SELECT opened FROM credit_mirror WHERE id = 1`).toArray()[0]
    if (m && Number(m.opened) === 1) return 0
    const st = sql.exec<{ balance: number }>(`SELECT balance FROM credit_state WHERE id = 1`).toArray()[0]
    const sum = Number(sql.exec<{ s: number | null }>(`SELECT SUM(micros) AS s FROM credit_entry`).toArray()[0]?.s ?? 0)
    const diff = st ? Number(st.balance) - sum : 0
    if (diff !== 0) {
      sql.exec(`UPDATE credit_state SET last_seq = last_seq + 1, version = version + 1, changed_at = ?, dirty_since = COALESCE(dirty_since, ?) WHERE id = 1`, now, now)
      const seq = Number(sql.exec<{ s: number }>(`SELECT last_seq AS s FROM credit_state WHERE id = 1`).one().s)
      sql.exec(`INSERT INTO credit_entry (key, kind, micros, actor, reason, at, seq) VALUES (?, 'opening', ?, 'mirror', 'balance before the mirror started', ?, ?)`, `opening:${seq}`, diff, now, seq)
    }
    sql.exec(`INSERT INTO credit_mirror (id, version, failures, next_at, opened) VALUES (1, -1, 0, 0, 1) ON CONFLICT (id) DO UPDATE SET opened = 1`)
    return diff
  })
}

/** One mirror run. Throws when the database refused (nothing is marked); the caller records the failure. */
export const mirrorCredits = async (storage: DurableObjectStorage, team: string, client: MirrorClient): Promise<{ entries: number; version: number }> => {
  const sql = storage.sql
  const opening = openMirror(storage, Date.now())
  if (opening !== 0) console.log(JSON.stringify({ msg: "credits.mirror_opening", team, micros: opening }))
  const st = sql.exec<{ balance: number; version: number; last_seq: number; changed_at: number }>(`SELECT balance, version, last_seq, changed_at FROM credit_state WHERE id = 1`).toArray()[0]
  if (!st) return { entries: 0, version: 0 }
  // One snapshot before any await: other calls may run while the database answers.
  const held = Number(sql.exec<{ m: number | null }>(`SELECT SUM(micros) AS m FROM credit_hold`).toArray()[0]?.m ?? 0)
  const entries = sql.exec<EntryRow>(`SELECT key, kind, micros, cost_micros, chief, conversation, actor, reason, corrects, at, seq FROM credit_entry WHERE mirrored = 0 ORDER BY seq LIMIT ?`, MIRROR_BATCH).toArray()
  const customers = sql.exec<{ mode: string; customer: string; at: number }>(`SELECT mode, customer, at FROM credit_customer`).toArray()
  // With a backlog the ledger would trail the balance: send the balance once the backlog is in.
  const backlog = entries.length === MIRROR_BATCH
  const state = backlog ? null : { balance: Number(st.balance), held, version: Number(st.version), last_seq: Number(st.last_seq), changed_at: Number(st.changed_at) }
  for (const [q, values] of mirrorStatements(team, entries, state, customers)) await client.query(q, values)
  // A customer the database already had for this team and mode, and a different one here, is a conflict to look at.
  for (const c of customers) {
    const [rows] = (await client.query(`SELECT customer_id FROM team_billing_customer WHERE team_id = ? AND mode = ?`, [team, c.mode])) as [Array<{ customer_id: string }>]
    if (rows?.[0] && rows[0].customer_id !== c.customer) console.error(JSON.stringify({ msg: "credits.mirror_customer_conflict", team, mode: c.mode }))
  }
  storage.transactionSync(() => {
    for (const e of entries) sql.exec(`UPDATE credit_entry SET mirrored = 1 WHERE key = ?`, e.key)
    if (state) {
      sql.exec(`INSERT INTO credit_mirror (id, version, failures, next_at) VALUES (1, ?, 0, 0) ON CONFLICT (id) DO UPDATE SET version = MAX(version, excluded.version), failures = 0, next_at = 0`, state.version)
      // Nothing changed while the database answered: clean. Otherwise the changes since then start a new window.
      const cur = Number(sql.exec<{ v: number }>(`SELECT version AS v FROM credit_state WHERE id = 1`).one().v)
      sql.exec(`UPDATE credit_state SET dirty_since = ? WHERE id = 1`, cur === state.version ? null : Date.now())
    } else sql.exec(`INSERT INTO credit_mirror (id, version, failures, next_at) VALUES (1, -1, 0, 0) ON CONFLICT (id) DO UPDATE SET failures = 0, next_at = 0`)
  })
  return { entries: entries.length, version: state?.version ?? -1 }
}

/** A failed run: the next try waits MIRROR_RETRY_MS x 2^(failures), at most MIRROR_RETRY_MAX_MS. */
export const mirrorFailed = (sql: SqlStorage, now: number): number => {
  const f = Number(sql.exec<{ failures: number }>(`SELECT failures FROM credit_mirror WHERE id = 1`).toArray()[0]?.failures ?? 0) + 1
  const next = now + Math.min(MIRROR_RETRY_MS * 2 ** (f - 1), MIRROR_RETRY_MAX_MS)
  sql.exec(`INSERT INTO credit_mirror (id, version, failures, next_at) VALUES (1, -1, ?, ?) ON CONFLICT (id) DO UPDATE SET failures = excluded.failures, next_at = excluded.next_at`, f, next)
  return f
}
