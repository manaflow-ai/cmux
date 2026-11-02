import { copyKeysToMysql, junkTeams, verifyTables, type MyLike, type PgLike, type TableReport } from "@cmux/db/projection-compare"
import type { Env } from "./env.ts"

/**
 * The dual-write safety net (state-placement.md 4.5): every 15 minutes the Worker compares each
 * projected table between Postgres and the MySQL shadow (counts and per-row hashes, at most
 * `maxRows` rows per table). A table that differs is compared once more; only keys that still
 * differ are reported, so a row written to the primary while the shadow catches up is not an alarm.
 * A lasting difference is one error event per table with counts and keys (ids, never values).
 *
 * With `repair` (the MySQL writer, only while Postgres is the primary), the rows of a lasting
 * difference that are missing or changed in MySQL are copied again from Postgres through the
 * projection's seq guard, so a lost best-effort shadow write converges within one run instead of
 * staying behind forever. A row only MySQL has is reported, never deleted.
 *
 * Junk teams (projection-compare.ts JUNK_TEAMS_SQL, read from Postgres each run) are left out on both
 * sides, as the production copy leaves them out (copy-pg-to-mysql.ts --exclude-junk-teams), so they
 * are never a difference and never repaired into MySQL.
 */
export interface CompareDeps {
  readonly postgres: PgLike
  readonly mysql: MyLike
  readonly maxRows?: number
  /** Test seam: runs between the two passes. */
  readonly betweenPasses?: () => Promise<void>
  /** The MySQL writer for repairs; absent = report only. */
  readonly repair?: MyLike
}

export interface CompareDiff {
  readonly table: string
  readonly postgres_count: number
  readonly mysql_count: number
  readonly partial: boolean
  readonly missing_in_mysql: Array<string>
  readonly missing_in_postgres: Array<string>
  readonly changed: Array<string>
}

/** Keys reported per list (an event stays small; the counts say how many there are). */
const KEYS_SHOWN = 20
const both = (first: ReadonlyArray<string>, second: ReadonlyArray<string>) => second.filter((k) => first.includes(k))

export const runProjectionCompare = async (deps: CompareDeps): Promise<{ diffs: Array<CompareDiff>; repaired: Record<string, number> }> => {
  const maxRows = deps.maxRows ?? 5000
  const excludeTeams = await junkTeams(deps.postgres)
  const first = await verifyTables(deps.postgres, deps.mysql, { maxRows, excludeTeams })
  const suspect = first.filter((r) => !r.equal)
  const diffs: Array<CompareDiff> = []
  if (suspect.length > 0) {
    await deps.betweenPasses?.()
    const second = await verifyTables(deps.postgres, deps.mysql, { maxRows, excludeTeams, tables: suspect.map((r) => r.table) })
    for (const again of second) {
      const was = suspect.find((r) => r.table === again.table) as TableReport
      const diff: CompareDiff = {
        table: again.table,
        postgres_count: again.pgCount,
        mysql_count: again.mysqlCount,
        partial: again.partial,
        missing_in_mysql: both(was.missingInMysql, again.missingInMysql),
        missing_in_postgres: both(was.missingInPostgres, again.missingInPostgres),
        changed: both(was.changed, again.changed)
      }
      const lasting = diff.missing_in_mysql.length + diff.missing_in_postgres.length + diff.changed.length > 0 || (again.pgCount !== again.mysqlCount && was.pgCount !== was.mysqlCount)
      if (lasting) diffs.push(diff)
    }
  }
  for (const d of diffs) {
    console.error(JSON.stringify({
      event: "projection.compare.diff",
      level: "error",
      ...d,
      missing_in_mysql: d.missing_in_mysql.slice(0, KEYS_SHOWN),
      missing_in_postgres: d.missing_in_postgres.slice(0, KEYS_SHOWN),
      changed: d.changed.slice(0, KEYS_SHOWN),
      counts: { missing_in_mysql: d.missing_in_mysql.length, missing_in_postgres: d.missing_in_postgres.length, changed: d.changed.length }
    }))
  }
  const repaired: Record<string, number> = {}
  if (deps.repair) {
    for (const d of diffs) {
      const keys = [...d.missing_in_mysql, ...d.changed]
      if (keys.length === 0) continue
      try {
        const rows = await copyKeysToMysql(deps.postgres, deps.repair, d.table, keys)
        repaired[d.table] = rows
        console.log(JSON.stringify({ event: "projection.compare.repaired", table: d.table, rows, keys: keys.slice(0, KEYS_SHOWN) }))
      } catch (e) {
        const err = (e as { code?: unknown } | null) ?? {}
        console.error(JSON.stringify({ event: "projection.compare.repair_failed", level: "error", table: d.table, code: String(err.code ?? "") }))
      }
    }
  }
  if (diffs.length === 0) console.log(JSON.stringify({ event: "projection.compare.ok", tables: first.length, junk_teams: excludeTeams.length, partial: first.filter((r) => r.partial).map((r) => r.table) }))
  return { diffs, repaired }
}

/** The cron entry: runs only while a MySQL shadow or primary is configured; without both bindings the run fails. */
export const compareFromEnv = async (env: Env): Promise<void> => {
  const active = env.PROJECTION_SHADOW === "mysql" || env.PROJECTION_PRIMARY === "mysql"
  if (!active) return
  if (!env.HYPERDRIVE || !env.PS_MYSQL_RO) {
    console.error(JSON.stringify({ event: "projection.compare.unconfigured", level: "error", postgres: !!env.HYPERDRIVE, mysql: !!env.PS_MYSQL_RO }))
    // A failed cron run, not a quiet skip: a config that drops a binding must not look like a clean compare.
    throw new Error("projection compare unconfigured: a MySQL switch is set without HYPERDRIVE and PS_MYSQL_RO")
  }
  const { default: pg } = await import("pg")
  const { connectMysql } = await import("./mysql-connect.ts")
  // The writer role reads every projected table (the -ro role is search-ro); the session is read-only.
  const pgc = new pg.Client({ connectionString: env.HYPERDRIVE.connectionString, statement_timeout: 20_000, query_timeout: 25_000, connectionTimeoutMillis: 10_000 })
  let my: Awaited<ReturnType<typeof connectMysql>> | undefined
  let writer: Awaited<ReturnType<typeof connectMysql>> | undefined
  // Every connection opened is closed, also when a later one fails (a PlanetScale outage must not leak Postgres clients).
  try {
    await pgc.connect()
    my = await connectMysql(env.PS_MYSQL_RO)
    // Repairs flow primary -> shadow only: while Postgres is the primary and the writer binding exists.
    if (env.PROJECTION_PRIMARY !== "mysql" && env.PS_MYSQL) writer = await connectMysql(env.PS_MYSQL)
    await pgc.query("SET default_transaction_read_only = on")
    await runProjectionCompare({ postgres: pgc, mysql: my, ...(writer ? { repair: writer } : {}) })
  } finally {
    await pgc.end().catch(() => undefined)
    await my?.end().catch(() => undefined)
    await writer?.end().catch(() => undefined)
  }
}
