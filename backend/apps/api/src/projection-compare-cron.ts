import { verifyTables, type MyLike, type PgLike, type TableReport } from "@cmux/db/projection-compare"
import type { Env } from "./env.ts"

/**
 * The dual-write safety net (state-placement.md 4.5): every 15 minutes the Worker compares each
 * projected table between Postgres and the MySQL shadow (counts and per-row hashes, at most
 * `maxRows` rows per table). A table that differs is compared once more; only keys that still
 * differ are reported, so a row written to the primary while the shadow catches up is not an alarm.
 * A lasting difference is one error event per table with counts and keys (ids, never values).
 */
export interface CompareDeps {
  readonly postgres: PgLike
  readonly mysql: MyLike
  readonly maxRows?: number
  /** Test seam: runs between the two passes. */
  readonly betweenPasses?: () => Promise<void>
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

export const runProjectionCompare = async (deps: CompareDeps): Promise<{ diffs: Array<CompareDiff> }> => {
  const maxRows = deps.maxRows ?? 5000
  const first = await verifyTables(deps.postgres, deps.mysql, { maxRows })
  const suspect = first.filter((r) => !r.equal)
  const diffs: Array<CompareDiff> = []
  if (suspect.length > 0) {
    await deps.betweenPasses?.()
    const second = await verifyTables(deps.postgres, deps.mysql, { maxRows, tables: suspect.map((r) => r.table) })
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
  if (diffs.length === 0) console.log(JSON.stringify({ event: "projection.compare.ok", tables: first.length, partial: first.filter((r) => r.partial).map((r) => r.table) }))
  return { diffs }
}

/** The cron entry: runs only while a MySQL shadow or primary is configured, with both bindings. */
export const compareFromEnv = async (env: Env): Promise<void> => {
  const active = env.PROJECTION_SHADOW === "mysql" || env.PROJECTION_PRIMARY === "mysql"
  if (!active) return
  if (!env.HYPERDRIVE || !env.PS_MYSQL_RO) {
    console.error(JSON.stringify({ event: "projection.compare.unconfigured", level: "error", postgres: !!env.HYPERDRIVE, mysql: !!env.PS_MYSQL_RO }))
    return
  }
  const { default: pg } = await import("pg")
  const { connectMysql } = await import("./mysql-connect.ts")
  // The writer role reads every projected table (the -ro role is search-ro); the session is read-only.
  const pgc = new pg.Client({ connectionString: env.HYPERDRIVE.connectionString, statement_timeout: 20_000, query_timeout: 25_000, connectionTimeoutMillis: 10_000 })
  await pgc.connect()
  const my = await connectMysql(env.PS_MYSQL_RO)
  try {
    await pgc.query("SET default_transaction_read_only = on")
    await runProjectionCompare({ postgres: pgc, mysql: my })
  } finally {
    await pgc.end().catch(() => undefined)
    await my.end().catch(() => undefined)
  }
}
