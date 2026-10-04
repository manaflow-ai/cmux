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

/**
 * True when the error says PlanetScale or Hyperdrive is unreachable or overloaded, not that the
 * row is bad: Postgres classes 08 (connection), 40 (rollback, deadlock), 53 (resources),
 * 57 (operator intervention, shutdown), 58 (system), and network errors without a SQLSTATE.
 * Such a batch backs off and retries forever; it never dead-letters (home-scale review P1).
 */
export const isTransientError = (e: unknown): boolean => {
  const code = (e as { code?: unknown } | null)?.code
  if (typeof code === "string" && /^[0-9A-Z]{5}$/.test(code)) return /^(08|40|53|57|58)/.test(code)
  const text = e instanceof Error ? `${e.name} ${e.message}` : String(e)
  return /connect|connection|timeout|timed out|ECONN|EPIPE|reset|network|socket|terminated|hyperdrive|binding missing|overloaded|unavailable/i.test(text)
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
export const applyProjectionRows = async (client: PgQuery, stream: string, rows: ReadonlyArray<OutboxRow>): Promise<{ sent: Array<number>; dead: Array<{ id: number; error: string }> }> => {
  const sent: Array<number> = []
  const dead: Array<{ id: number; error: string }> = []
  await client.query("BEGIN")
  try {
    for (const row of rows) {
      const statement = projectionStatement(row.kind, row.payload, stream, row.seq)
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
