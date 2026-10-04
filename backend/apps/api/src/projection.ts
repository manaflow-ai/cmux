import type { OutboxRow } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { pgSafe } from "./text-safe.ts"
import { drizzleStatements } from "./projection-drizzle.ts"

/**
 * Projection writes into PlanetScale `cmux-next`. A DO never writes Postgres in
 * its request path: it commits outbox rows with the op, and this drain applies
 * them with upserts guarded by `(source_stream, source_seq)`, so a replayed or
 * reordered batch never moves a row backwards (the DO stays the single writer).
 */
/** The search rows table is hash-partitioned (not modeled in Drizzle): raw SQL with the same guard. */
const rawStatements: Record<string, (p: Record<string, unknown>, stream: string, seq: number) => [string, Array<unknown>]> = {
  "home.message.upsert": (p, stream, seq) => [
    `INSERT INTO home_message_search (conversation_id, seq, message_id, author_id, author_kind, created_at, edited_at, body, source_stream, source_seq)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
     ON CONFLICT (conversation_id, seq) DO UPDATE SET message_id = excluded.message_id, author_id = excluded.author_id,
       author_kind = excluded.author_kind, edited_at = excluded.edited_at, body = excluded.body,
       source_stream = excluded.source_stream, source_seq = excluded.source_seq
     WHERE home_message_search.source_seq < excluded.source_seq`,
    [p.conversation_id, p.seq, p.message_id, p.author_id, p.author_kind, p.created_at, p.edited_at ?? null, p.body, stream, seq]
  ],
  "home.message.delete": (p, stream, seq) => [
    `DELETE FROM home_message_search WHERE conversation_id = $1 AND seq = $2 AND source_stream = $3 AND source_seq <= $4`,
    [p.conversation_id, p.seq, stream, seq]
  ],
  // Retention (conversation.sweep): every row of the conversation up to `seq`, one statement per sweep.
  "home.message.delete_through": (p, stream, seq) => [
    `DELETE FROM home_message_search WHERE conversation_id = $1 AND seq <= $2 AND source_stream = $3 AND source_seq <= $4`,
    [p.conversation_id, p.seq, stream, seq]
  ]
}

const statements: Record<string, (p: Record<string, unknown>, stream: string, seq: number) => [string, Array<unknown>]> = { ...drizzleStatements, ...rawStatements }

/** The SQL for one outbox row, or undefined for a kind this drain does not know. */
export const projectionStatement = (kind: string, payload: unknown, stream: string, seq: number): [string, Array<unknown>] | undefined => {
  const make = statements[kind]
  return make ? make(pgSafe(payload) as Record<string, unknown>, stream, seq) : undefined
}

/** The part of a pg client the drain uses (a fake in tests). */
export interface PgQuery {
  query(sql: string, values?: Array<unknown>): Promise<unknown>
}

/** MySQL server errors that mean "try again later": lock wait, deadlock, too many connections,
 * server shutdown, gone away / lost, read-only during failover, query interrupted by the server. */
const MYSQL_TRANSIENT_ERRNO = new Set([1040, 1053, 1205, 1213, 1290, 1317, 1836, 2002, 2003, 2006, 2013, 2055, 3024])

/**
 * True when the error says PlanetScale or Hyperdrive is unreachable or overloaded, not that the
 * row is bad. Postgres: SQLSTATE classes 08 (connection), 40 (rollback, deadlock), 53 (resources),
 * 57 (operator intervention, shutdown), 58 (system). MySQL (mysql2): the same SQLSTATE classes in
 * `sqlState`, plus the transient server errno list above. Network errors without a SQL code count
 * too. Such a batch backs off and retries forever; it never dead-letters (home-scale review P1).
 */
export const isTransientError = (e: unknown): boolean => {
  const err = (e ?? {}) as { code?: unknown; sqlState?: unknown; errno?: unknown; fatal?: unknown }
  if (typeof err.errno === "number" && MYSQL_TRANSIENT_ERRNO.has(err.errno)) return true
  if (typeof err.sqlState === "string" && /^[0-9A-Z]{5}$/.test(err.sqlState) && err.sqlState !== "HY000") return /^(08|40|53|57|58)/.test(err.sqlState)
  const code = err.code
  if (typeof code === "string" && /^[0-9A-Z]{5}$/.test(code)) return /^(08|40|53|57|58)/.test(code)
  // Node-style socket codes (ECONNRESET, ETIMEDOUT, EPIPE, ...) and mysql2 protocol losses.
  if (typeof code === "string" && (/^E[A-Z]+$/.test(code) || /^PROTOCOL_(CONNECTION_LOST|SEQUENCE_TIMEOUT)$/.test(code))) return true
  // A fatal mysql2 error with no server errno is a dead connection.
  if (err.fatal === true && typeof err.errno !== "number") return true
  // The pg client's own connection errors carry no code; nothing else is matched by text.
  const text = e instanceof Error ? e.message : String(e)
  return /^(Connection terminated|Connection terminated unexpectedly|connection timeout|timeout expired|HYPERDRIVE binding missing|PS_MYSQL binding missing|Network connection lost)/i.test(text)
}

const describeError = (e: unknown): string => {
  const code = (e as { code?: unknown } | null)?.code
  return `${typeof code === "string" ? `${code} ` : ""}${e instanceof Error ? e.message : String(e)}`.slice(0, 300)
}

/**
 * Applies one batch in one transaction, each row under its own savepoint. A row that fails with a
 * non-transient error rolls back to its savepoint and is returned as dead (only that row); the
 * other rows commit. A transient error rolls back the whole batch and is thrown (the channel backs
 * off). Upserts are guarded by (source_stream, source_seq), so a later replay of the dead row
 * cannot move a newer row backwards.
 */
export const applyProjectionRows = (client: PgQuery, stream: string, rows: ReadonlyArray<OutboxRow>) => applyRows(client, stream, rows, projectionStatement)

/** applyProjectionRows for any SQL dialect: the statement renderer is the only difference. */
export const applyRows = async (
  client: PgQuery,
  stream: string,
  rows: ReadonlyArray<OutboxRow>,
  statementOf: (kind: string, payload: unknown, stream: string, seq: number) => [string, Array<unknown>] | undefined
): Promise<{ sent: Array<number>; dead: Array<{ id: number; error: string }> }> => {
  const sent: Array<number> = []
  const dead: Array<{ id: number; error: string }> = []
  await client.query("BEGIN")
  try {
    for (const row of rows) {
      let statement: [string, Array<unknown>] | undefined
      try {
        statement = statementOf(row.kind, row.payload, stream, row.seq)
      } catch (e) {
        // A payload that cannot even be rendered is poison for this row only.
        dead.push({ id: row.id, error: describeError(e) })
        continue
      }
      // An unknown kind (newer writer than this drain) must not block every later row.
      if (!statement) {
        console.error(JSON.stringify({ msg: "outbox row skipped: no projection", stream, seq: row.seq, kind: row.kind }))
        sent.push(row.id)
        continue
      }
      await client.query("SAVEPOINT row")
      try {
        await client.query(statement[0], statement[1])
        await client.query("RELEASE SAVEPOINT row")
        sent.push(row.id)
      } catch (e) {
        if (isTransientError(e)) throw e
        await client.query("ROLLBACK TO SAVEPOINT row")
        dead.push({ id: row.id, error: describeError(e) })
      }
    }
    await client.query("COMMIT")
  } catch (e) {
    await client.query("ROLLBACK").catch(() => undefined)
    throw e
  }
  return { sent, dead }
}

export const drainOutbox = async (env: Env, stream: string, rows: ReadonlyArray<OutboxRow>): Promise<{ sent: Array<number>; dead: Array<{ id: number; error: string }> }> => {
  if (!env.HYPERDRIVE) throw new Error("HYPERDRIVE binding missing")
  // Loaded on first drain only: keeps pg (CommonJS, node:net) off the request path and out of unit tests.
  const { default: pg } = await import("pg")
  const client = new pg.Client({ connectionString: env.HYPERDRIVE.connectionString })
  await client.connect()
  try {
    return await applyProjectionRows(client, stream, rows)
  } finally {
    await client.end()
  }
}
