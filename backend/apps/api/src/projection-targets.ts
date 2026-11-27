import type { OutboxRow } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { connectMysql } from "./mysql-connect.ts"
import { applyRows, drainOutbox } from "./projection.ts"
import { projectionStatementMysql } from "./projection-mysql.ts"
import { spaceRows } from "./build-space-projection.ts"
import { spaceOfEnv } from "./build-space.ts"

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
  // A self-hosted chat server (backend/apps/home-server) has no PlanetScale: its rows are done.
  if ((env.PROJECTION_PRIMARY as string | undefined) === "none") return { sent: rows.map((r) => r.id), dead: [] }
  // Dev build rows (build-space-projection.ts) go to Postgres only, keyed by their space; the rest drain as before.
  // Postgres takes them as the primary or as the shadow (staging and production run MySQL primary, Postgres shadow):
  // as the shadow a failure is logged and never holds the batch, as it is for nightly's rows. With no Postgres
  // target at all they are projected nowhere, and a dev build's home.search finds nothing (AGENTS.md).
  const spaced = spaceRows(spaceOfEnv(env), rows)
  const { primary, shadow } = projectionTargets(env)
  const done = { sent: spaced.dev.map((r) => r.id), dead: [] as Array<{ id: number; error: string }> }
  const dev = spaced.dev.length === 0
    ? { sent: [], dead: [] }
    : primary === "postgres"
      ? await impl.postgres(env, stream, spaced.dev)
      : shadow === "postgres"
        ? await impl.postgres(env, stream, spaced.dev).then((r) => {
            if (r.dead.length > 0) console.error(JSON.stringify({ event: "projection.shadow.dead", level: "error", stream, target: "postgres", space: "dev", rows: r.dead.map((d) => d.id) }))
            return done
          }, (e: unknown) => {
            console.error(JSON.stringify({ event: "projection.shadow.failed", level: "error", stream, target: "postgres", space: "dev", rows: spaced.dev.length, code: String((e as { code?: unknown } | null)?.code ?? "") }))
            return done
          })
        : done
  const base = spaced.base.length === 0 ? { sent: [], dead: [] } : await impl[primary](env, stream, spaced.base)
  const result = { sent: [...base.sent, ...dev.sent, ...spaced.skipped], dead: [...base.dead, ...dev.dead] }
  if (shadow && spaced.base.length > 0) {
    // Only rows the primary accepted; a row dead on the primary stays out of the shadow too.
    const sent = new Set(base.sent)
    const mirrored = spaced.base.filter((r) => sent.has(r.id))
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
