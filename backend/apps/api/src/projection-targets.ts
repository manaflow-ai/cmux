import type { OutboxRow } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { connectMysql } from "./mysql-connect.ts"
import { applyRows, drainOutbox } from "./projection.ts"
import { projectionStatementMysql } from "./projection-mysql.ts"

/**
 * Where projection rows go during the Postgres to MySQL move (plans/cmux-next/state-placement.md 4.5).
 * PROJECTION_PRIMARY (default "postgres") decides the batch: its sent/dead result drives the outbox.
 * PROJECTION_SHADOW ("mysql" or "postgres", unset = none) gets the same rows; a shadow failure is
 * logged at error level and never fails, delays or dead-letters the batch. The rebuild and compare
 * jobs repair and prove the shadow before the primary switches.
 */
export type ProjectionTarget = "postgres" | "mysql"
type DrainResult = { sent: Array<number>; dead: Array<{ id: number; error: string }> }

export const projectionTargets = (env: Env): { primary: ProjectionTarget; shadow: ProjectionTarget | null } => {
  const primary: ProjectionTarget = env.PROJECTION_PRIMARY === "mysql" ? "mysql" : "postgres"
  const shadow = env.PROJECTION_SHADOW === "mysql" || env.PROJECTION_SHADOW === "postgres" ? env.PROJECTION_SHADOW : null
  return { primary, shadow: shadow === primary ? null : shadow }
}

export const drainOutboxMysql = async (env: Env, stream: string, rows: ReadonlyArray<OutboxRow>): Promise<DrainResult> => {
  if (!env.PS_MYSQL) throw new Error("PS_MYSQL binding missing")
  const client = await connectMysql(env.PS_MYSQL)
  try {
    return await applyRows(client, stream, rows, projectionStatementMysql)
  } finally {
    await client.end().catch(() => undefined)
  }
}

const drainers: Record<ProjectionTarget, (env: Env, stream: string, rows: ReadonlyArray<OutboxRow>) => Promise<DrainResult>> = {
  postgres: drainOutbox,
  mysql: drainOutboxMysql
}

/** The outbox projector: primary decides; the shadow mirrors best-effort. */
export const projectRows = async (env: Env, stream: string, rows: ReadonlyArray<OutboxRow>, impl: typeof drainers = drainers): Promise<DrainResult> => {
  const { primary, shadow } = projectionTargets(env)
  const result = await impl[primary](env, stream, rows)
  if (shadow) {
    // Only rows the primary accepted; a row dead on the primary stays out of the shadow too.
    const sent = new Set(result.sent)
    const mirrored = rows.filter((r) => sent.has(r.id))
    try {
      const s = await impl[shadow](env, stream, mirrored)
      if (s.dead.length > 0) console.error(JSON.stringify({ event: "projection.shadow.dead", level: "error", stream, target: shadow, rows: s.dead.map((d) => d.id) }))
    } catch (e) {
      // Codes only, never the server message (it can quote row values).
      const err = (e as { code?: unknown; errno?: unknown; sqlState?: unknown } | null) ?? {}
      console.error(JSON.stringify({ event: "projection.shadow.failed", level: "error", stream, target: shadow, rows: mirrored.length, code: String(err.code ?? ""), errno: typeof err.errno === "number" ? err.errno : null, sql_state: typeof err.sqlState === "string" ? err.sqlState : null }))
    }
  }
  return result
}
