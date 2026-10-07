import type { SqlStore } from "./sql.ts"

/**
 * Table names of one engine instance. A prefix lets several streams live in one
 * object (UserDO hosts `user:<id>` with `own_` and `inbox:<id>` with `inbox_`),
 * each with its own sequence, ledger, events, outbox and rows.
 */
export interface Tables {
  readonly meta: string
  readonly state: string
  readonly ledger: string
  readonly events: string
  readonly outbox: string
  readonly rows: string
}

export const tablesFor = (prefix = "own_"): Tables => {
  if (!/^[a-z][a-z0-9_]*_$/.test(prefix)) throw new Error(`invalid table prefix ${prefix}`)
  return {
    meta: `${prefix}meta`,
    state: `${prefix}state`,
    ledger: `${prefix}ledger`,
    events: `${prefix}events`,
    outbox: `${prefix}outbox`,
    rows: `${prefix}rows`
  }
}

export const SCHEMA_VERSION = 2

/** Idempotent: runs on every wake, so objects that wake months later still upgrade. */
export const migrate = (sql: SqlStore, t: Tables): void => {
  sql.exec(`CREATE TABLE IF NOT EXISTS ${t.meta} (key TEXT PRIMARY KEY, value TEXT NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS ${t.state} (id INTEGER PRIMARY KEY CHECK (id = 1), seq INTEGER NOT NULL, json TEXT NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS ${t.ledger} (
     identity TEXT NOT NULL,
     idempotency_key TEXT NOT NULL,
     tx TEXT NOT NULL,
     op TEXT NOT NULL,
     params_hash TEXT NOT NULL,
     ok INTEGER NOT NULL,
     reply TEXT NOT NULL,
     sequence INTEGER NOT NULL,
     revision TEXT NOT NULL,
     actor TEXT NOT NULL,
     origin TEXT NOT NULL,
     created_at INTEGER NOT NULL,
     PRIMARY KEY (identity, idempotency_key))`)
  sql.exec(`CREATE TABLE IF NOT EXISTS ${t.events} (
     seq INTEGER PRIMARY KEY,
     tx TEXT NOT NULL,
     op TEXT NOT NULL,
     params TEXT NOT NULL,
     actor TEXT NOT NULL,
     origin TEXT NOT NULL,
     at INTEGER NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS ${t.outbox} (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     seq INTEGER NOT NULL,
     kind TEXT NOT NULL,
     entity TEXT NOT NULL,
     payload TEXT NOT NULL,
     created_at INTEGER NOT NULL,
     sent_at INTEGER)`)
  // Ledger pruning finds the oldest key without a scan.
  sql.exec(`CREATE INDEX IF NOT EXISTS ${t.ledger}_created ON ${t.ledger} (created_at)`)
  // v2: row-backed domains (one generic table; `n` orders a table, for example a message seq)
  // and event effects (row-mode events carry their head and row writes).
  sql.exec(`CREATE TABLE IF NOT EXISTS ${t.rows} (tbl TEXT NOT NULL, k TEXT NOT NULL, n INTEGER, json TEXT NOT NULL, PRIMARY KEY (tbl, k))`)
  sql.exec(`CREATE INDEX IF NOT EXISTS ${t.rows}_order ON ${t.rows} (tbl, n)`)
  sql.exec(`CREATE INDEX IF NOT EXISTS ${t.events}_at ON ${t.events} (at)`)
  const columns = sql.exec<{ name: string }>(`PRAGMA table_info(${t.events})`).map((c) => c.name)
  if (!columns.includes("effects")) sql.exec(`ALTER TABLE ${t.events} ADD COLUMN effects TEXT`)
  // Target of a DO-to-DO outbox item ({class, name}); null for PlanetScale projections.
  const outboxColumns = sql.exec<{ name: string }>(`PRAGMA table_info(${t.outbox})`).map((c) => c.name)
  if (!outboxColumns.includes("target")) sql.exec(`ALTER TABLE ${t.outbox} ADD COLUMN target TEXT`)
  // Delivery channel: '' for PlanetScale projections, '<class>:<name>' for a target object.
  // Each channel reads, backs off and dead-letters on its own (outbox.ts).
  if (!outboxColumns.includes("channel")) sql.exec(`ALTER TABLE ${t.outbox} ADD COLUMN channel TEXT NOT NULL DEFAULT ''`)
  if (!outboxColumns.includes("dead_at")) sql.exec(`ALTER TABLE ${t.outbox} ADD COLUMN dead_at INTEGER`)
  sql.exec(`CREATE INDEX IF NOT EXISTS ${t.outbox}_pending ON ${t.outbox} (channel, id) WHERE sent_at IS NULL AND dead_at IS NULL`)
  // Dead items by key: a delivered item deletes an older dead item for the same key (outbox.ts markSent).
  sql.exec(`CREATE INDEX IF NOT EXISTS ${t.outbox}_dead ON ${t.outbox} (channel, entity) WHERE dead_at IS NOT NULL`)
  sql.exec(`CREATE TABLE IF NOT EXISTS ${t.outbox}_backoff (channel TEXT PRIMARY KEY, attempts INTEGER NOT NULL, next_at INTEGER NOT NULL)`)
  // Poison failures of the channel's head in a row (transient failures never count toward dead letter).
  const backoffColumns = sql.exec<{ name: string }>(`PRAGMA table_info(${t.outbox}_backoff)`).map((c) => c.name)
  if (!backoffColumns.includes("poison")) sql.exec(`ALTER TABLE ${t.outbox}_backoff ADD COLUMN poison INTEGER NOT NULL DEFAULT 0`)
  sql.exec(`INSERT INTO ${t.meta} (key, value) VALUES ('schema_version', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value`, String(SCHEMA_VERSION))
}
