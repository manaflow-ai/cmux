import type { OutboxRow } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { connectMysql } from "./mysql-connect.ts"
import { applyRows } from "./projection.ts"
import { projectionStatementMysql } from "./projection-mysql.ts"

/**
 * The outbox projector: every batch goes to the PlanetScale Vitess projection (`PS_MYSQL`), and its
 * sent/dead result drives the outbox. `PROJECTION_PRIMARY=none` (a self-hosted chat server,
 * backend/apps/home-server, has no PlanetScale) marks every row done.
 */
type DrainResult = { sent: Array<number>; dead: Array<{ id: number; error: string }> }

export const drainOutboxMysql = async (env: Env, stream: string, rows: ReadonlyArray<OutboxRow>): Promise<DrainResult> => {
  if (!env.PS_MYSQL) throw new Error("PS_MYSQL binding missing")
  const client = await connectMysql(env.PS_MYSQL)
  try {
    return await applyRows(client, stream, rows, projectionStatementMysql)
  } finally {
    await client.end().catch(() => undefined)
  }
}

export const projectRows = async (env: Env, stream: string, rows: ReadonlyArray<OutboxRow>, drain: typeof drainOutboxMysql = drainOutboxMysql): Promise<DrainResult> => {
  if (env.PROJECTION_PRIMARY === "none") return { sent: rows.map((r) => r.id), dead: [] }
  return drain(env, stream, rows)
}
