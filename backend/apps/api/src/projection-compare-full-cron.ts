import { junkTeams, PROJECTION_TABLES, type MyLike, type PgLike } from "@cmux/db/projection-compare"
import {
  compareTableFull,
  FullCompareBudgetExceeded,
  fullDiffCount,
  selectOnlyMy,
  selectOnlyPg,
  type FullBudget,
  type FullTableReport
} from "@cmux/db/projection-compare-full"
import type { Env } from "./env.ts"

/**
 * The hourly full verify (cmuxterm-hq#4767 step 5) run by the Worker itself: every row of every projected
 * table, Postgres against MySQL (projection-compare-full.ts), read only. The 15-minute compare
 * (projection-compare-cron.ts) stays as it is: 5,000 rows per table, with repairs while Postgres is
 * the primary. This pass never repairs or writes, whatever PROJECTION_PRIMARY says: it opens no MySQL
 * writer, and both handles refuse any statement that is not a SELECT.
 *
 * Events (keys only, never values), all with the same `pass` (the cron's scheduled time):
 * - `projection.compare.full.table`, one per table: rows on each side, rows checked, `outcome`
 *   (equal, diff, incomplete, failed or skipped), the difference count and up to 20 keys per kind; an
 *   error level line when the table is not equal;
 * - `projection.compare.full.done`: totals, `complete` (every table read to the end) and the duration;
 *   an error level line unless every table is equal.
 *
 * Bounded per invocation: at most `maxRows` rows read (both sides) and `wallMs` of wall time; a pass
 * that reaches either stops with that table `incomplete` and the rest listed in `skipped`. The whole
 * projection is about 48k rows a side, a small part of either bound (the PR that added this measured
 * it), so a pass finishes in one run.
 */
export interface FullCompareDeps {
  readonly postgres: PgLike
  readonly mysql: MyLike
  readonly pass: string
  readonly maxRows?: number
  readonly wallMs?: number
  readonly pageSize?: number
  readonly now?: () => number
  /** Test seam: runs before each table's recheck. */
  readonly beforeRecheck?: () => Promise<void>
}

/** Keys shown per list (an event stays small; the counts say how many there are). */
const KEYS_SHOWN = 20
/** Rows read per invocation, both sides: about 6x today's projection (about 96k rows for both sides). */
export const FULL_MAX_ROWS = 600_000
/** Wall time per invocation: under the 15-minute limit of a scheduled Worker, with room to log and close. */
export const FULL_WALL_MS = 10 * 60_000

export interface FullCompareResult {
  readonly complete: boolean
  readonly tables: Array<FullTableReport>
  readonly failed: Array<string>
  readonly skipped: Array<string>
}

const code = (e: unknown) => {
  const err = (e as { code?: unknown; name?: unknown } | null) ?? {}
  return String(err.code ?? err.name ?? "error")
}

export const runFullCompare = async (deps: FullCompareDeps): Promise<FullCompareResult> => {
  const now = deps.now ?? Date.now
  const started = now()
  const postgres = selectOnlyPg(deps.postgres)
  const mysql = selectOnlyMy(deps.mysql)
  const budget: FullBudget = { rowsRead: 0, maxRows: deps.maxRows ?? FULL_MAX_ROWS, deadline: started + (deps.wallMs ?? FULL_WALL_MS), now }
  // The junk list (JUNK_TEAMS_SQL, as the 15-minute compare reads it) has at most one id per team row; its rows count against the bound.
  const excludeTeams = await junkTeams(postgres)
  budget.rowsRead += excludeTeams.length
  const tables: Array<FullTableReport> = []
  const failed: Array<string> = []
  const skipped: Array<string> = []
  let stopped = false
  for (const table of Object.keys(PROJECTION_TABLES)) {
    if (stopped) {
      skipped.push(table)
      console.error(JSON.stringify({ event: "projection.compare.full.table", level: "error", pass: deps.pass, table, outcome: "skipped" }))
      continue
    }
    const t0 = now()
    try {
      const r = await compareTableFull(postgres, mysql, table, { excludeTeams, budget, ...(deps.pageSize ? { pageSize: deps.pageSize } : {}), ...(deps.beforeRecheck ? { beforeRecheck: deps.beforeRecheck } : {}) })
      tables.push(r)
      const diffs = fullDiffCount(r)
      const line = {
        event: "projection.compare.full.table",
        level: diffs > 0 ? "error" : "info",
        pass: deps.pass,
        table,
        outcome: diffs > 0 ? "diff" : "equal",
        postgres_rows: r.postgresRows,
        mysql_rows: r.mysqlRows,
        rows_checked: r.rowsChecked,
        diffs,
        missing_in_mysql: r.missingInMysql.slice(0, KEYS_SHOWN),
        missing_in_postgres: r.missingInPostgres.slice(0, KEYS_SHOWN),
        changed: r.changed.slice(0, KEYS_SHOWN),
        counts: { missing_in_mysql: r.missingInMysql.length, missing_in_postgres: r.missingInPostgres.length, changed: r.changed.length, unchecked: r.unchecked },
        pages: r.pages,
        duration_ms: now() - t0
      }
      if (diffs > 0) console.error(JSON.stringify(line))
      else console.log(JSON.stringify(line))
    } catch (e) {
      const incomplete = e instanceof FullCompareBudgetExceeded
      if (incomplete) stopped = true
      failed.push(table)
      console.error(JSON.stringify({ event: "projection.compare.full.table", level: "error", pass: deps.pass, table, outcome: incomplete ? "incomplete" : "failed", code: code(e), rows_read: budget.rowsRead, duration_ms: now() - t0 }))
    }
  }
  const diffs = tables.reduce((n, r) => n + fullDiffCount(r), 0)
  // Complete: every table read to its end (none stopped by the bound, none failed).
  const complete = !stopped && failed.length === 0
  const clean = complete && diffs === 0
  const done = {
    event: "projection.compare.full.done",
    level: clean ? "info" : "error",
    pass: deps.pass,
    complete,
    clean,
    tables: Object.keys(PROJECTION_TABLES).length,
    tables_equal: tables.filter((r) => fullDiffCount(r) === 0).length,
    tables_diff: tables.filter((r) => fullDiffCount(r) > 0).map((r) => r.table),
    failed,
    skipped,
    postgres_rows: tables.reduce((n, r) => n + r.postgresRows, 0),
    mysql_rows: tables.reduce((n, r) => n + r.mysqlRows, 0),
    rows_checked: tables.reduce((n, r) => n + r.rowsChecked, 0),
    rows_read: budget.rowsRead,
    diffs,
    junk_teams: excludeTeams.length,
    duration_ms: now() - started
  }
  if (clean) console.log(JSON.stringify(done))
  else console.error(JSON.stringify(done))
  return { complete, tables, failed, skipped }
}

/** As Postgres's query_timeout: a MySQL read that hangs ends the run instead of holding it to the platform's wall limit. */
const MYSQL_QUERY_TIMEOUT_MS = 25_000
const withTimeout = (my: MyLike & { destroy(): void }, ms: number): MyLike => ({
  query: (sql, values) => {
    let timer: ReturnType<typeof setTimeout> | undefined
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        my.destroy()
        reject(Object.assign(new Error("mysql query timeout"), { code: "QUERY_TIMEOUT" }))
      }, ms)
    })
    return Promise.race([my.query(sql, values), timeout]).finally(() => clearTimeout(timer))
  }
})

/**
 * The cron entry (wrangler.jsonc: staging's hourly PROJECTION_COMPARE_FULL_CRON; production has no such
 * trigger until the cutover runbook asks). Runs while a MySQL shadow or primary is configured; a switch set
 * without the read bindings fails the run. Never touches PS_MYSQL, the MySQL writer.
 */
export const compareFullFromEnv = async (env: Env, scheduledTime: number): Promise<void> => {
  const active = env.PROJECTION_SHADOW === "mysql" || env.PROJECTION_PRIMARY === "mysql"
  if (!active) return
  if (!env.HYPERDRIVE || !env.PS_MYSQL_RO) {
    console.error(JSON.stringify({ event: "projection.compare.full.unconfigured", level: "error", postgres: !!env.HYPERDRIVE, mysql: !!env.PS_MYSQL_RO }))
    throw new Error("projection full compare unconfigured: a MySQL switch is set without HYPERDRIVE and PS_MYSQL_RO")
  }
  const { default: pg } = await import("pg")
  const { connectMysql } = await import("./mysql-connect.ts")
  // The writer role reads every projected table (the -ro role is search-ro); the session is read-only and the handle SELECT-only.
  const pgc = new pg.Client({ connectionString: env.HYPERDRIVE.connectionString, statement_timeout: 20_000, query_timeout: 25_000, connectionTimeoutMillis: 10_000 })
  let my: Awaited<ReturnType<typeof connectMysql>> | undefined
  try {
    await pgc.connect()
    await pgc.query("SET default_transaction_read_only = on")
    // connectMysql's own setup query has no timeout: a stalled connect ends the run instead of holding it, and a
    // connection that opens after the timeout is closed at once.
    let connectTimer: ReturnType<typeof setTimeout> | undefined
    const connecting = connectMysql(env.PS_MYSQL_RO)
    my = await Promise.race([
      connecting,
      new Promise<never>((_, reject) => {
        connectTimer = setTimeout(() => {
          connecting.then((late) => late.destroy(), () => undefined)
          reject(Object.assign(new Error("mysql connect timeout"), { code: "CONNECT_TIMEOUT" }))
        }, MYSQL_QUERY_TIMEOUT_MS)
      })
    ]).finally(() => clearTimeout(connectTimer))
    await runFullCompare({ postgres: pgc, mysql: withTimeout(my, MYSQL_QUERY_TIMEOUT_MS), pass: new Date(scheduledTime).toISOString() })
  } finally {
    await pgc.end().catch(() => undefined)
    await my?.end().catch(() => undefined)
  }
}
