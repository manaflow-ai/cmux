import type { OutboxRow } from "@cmux/ownership"

/**
 * Projection writes into PlanetScale Vitess `cmux-next-vitess`. A DO never writes the database in
 * its request path: it commits outbox rows with the op, and the drain (projection-targets.ts)
 * applies them with upserts guarded by `(source_stream, source_seq)` (projection-mysql.ts), so a
 * replayed or reordered batch never moves a row backwards (the DO stays the single writer).
 */

/** The part of a SQL client the drain uses (a fake in tests). */
export interface SqlQuery {
  query(sql: string, values?: Array<unknown>): Promise<unknown>
}

/** MySQL server errors that mean "try again later": lock wait, deadlock, too many connections,
 * server shutdown, gone away / lost, read-only during failover, query interrupted by the server. */
const MYSQL_TRANSIENT_ERRNO = new Set([1040, 1053, 1205, 1213, 1290, 1317, 1836, 2002, 2003, 2006, 2013, 2055, 3024])

/**
 * True when the error says PlanetScale or Hyperdrive is unreachable or overloaded, not that the
 * row is bad: SQLSTATE classes 08 (connection), 40 (rollback, deadlock), 53 (resources),
 * 57 (operator intervention, shutdown), 58 (system) in mysql2's `sqlState`, plus the transient
 * server errno list above. Network errors without a SQL code count too. Such a batch backs off and retries forever; it never dead-letters (home-scale review P1).
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
  // Connection errors without a code (a missing binding, a lost Workers socket); nothing else is matched by text.
  const text = e instanceof Error ? e.message : String(e)
  return /^(Connection terminated|Connection terminated unexpectedly|connection timeout|timeout expired|PS_MYSQL binding missing|Network connection lost)/i.test(text)
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
export const applyRows = async (
  client: SqlQuery,
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
      // Not `row`: Vitess (PlanetScale MySQL) reserves it, so `SAVEPOINT row` is a syntax error there.
      await client.query("SAVEPOINT projection_row")
      try {
        await client.query(statement[0], statement[1])
        await client.query("RELEASE SAVEPOINT projection_row")
        sent.push(row.id)
      } catch (e) {
        if (isTransientError(e)) throw e
        await client.query("ROLLBACK TO SAVEPOINT projection_row")
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
