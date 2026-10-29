/**
 * Copy the Postgres `cmux-next` projection into PlanetScale MySQL `cmux-next-vitess`, then verify
 * (state-placement.md 4.5). One environment at a time: development, then staging, then main.
 *
 *   bun copy-pg-to-mysql.ts --branch development|staging|main [--exclude-junk-teams | --include-junk-teams] [--verify-only] [--my-url-env VAR]
 *
 * By default (or with --exclude-junk-teams) the run skips the junk teams (projection-compare.ts
 * JUNK_TEAMS_SQL: anonymous visitors' Stack personal-team mirrors no cmux-next user belongs to and
 * that were never used) and their team-scoped rows, read from Postgres at the start of the run, and
 * verify then compares only the kept set, as the compare cron does. It prints the number of junk
 * teams and of rows left out per table (counts only), so the operator checks the set before
 * cutover. --include-junk-teams copies and verifies every row. Nothing is deleted on either side.
 *
 * Reads Postgres with ~/.secrets/cmux-next-planetscale-<branch>.env (variable DATABASE_URL or the
 * first *_URL in that file) in a session forced read-only (default_transaction_read_only), because
 * the -ro role there is search-ro and may read only the search tables. Writes MySQL with the
 * readwriter credential (~/.secrets/cmux-next-vitess-<branch>-rw.env), or the mysql:// URL in the variable
 * named by --my-url-env (main: a short-lived password, never written to disk). Never prints a credential.
 *
 * The copy uses the same single-writer guard as the projection: a MySQL row that is already newer
 * (a dual-write shadow row) keeps its values. Verify compares row counts and a per-row sha256 of
 * the normalized facts (projection-compare.ts) and lists every key that differs; a non-equal
 * table fails the run (exit 1).
 */
import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import mysql from "mysql2/promise"
import pg from "pg"
import { PROJECTION_TABLES, TEAM_COLUMN, guardedUpsertMysql, junkTeams, sharedColumns, toMysqlValue, verifyTables, type MyLike, type PgLike } from "./projection-compare.ts"

export { junkTeams, verifyTables }

/** Copies every projected table, without the rows of the `excludeTeams` teams (TEAM_COLUMN). */
export const copyTables = async (pgc: PgLike, my: MyLike, options: { readonly batch?: number; readonly excludeTeams?: ReadonlyArray<string> } = {}): Promise<{ rows: number; perTable: Record<string, number> }> => {
  const batch = options.batch ?? 500
  const exclude = options.excludeTeams ?? []
  const perTable: Record<string, number> = {}
  let total = 0
  for (const [table, spec] of Object.entries(PROJECTION_TABLES)) {
    const columns = await sharedColumns(pgc, my, table)
    const list = columns.map((c) => `"${c}"`).join(", ")
    const order = spec.key.map((k) => `"${k}"`).join(", ")
    const col = TEAM_COLUMN[table]
    const scoped = col !== undefined && exclude.length > 0
    const where = scoped ? ` WHERE ("${col}" IS NULL OR NOT ("${col}" = ANY($1::text[])))` : ""
    const values = scoped ? [[...exclude]] : []
    let offset = 0
    perTable[table] = 0
    for (;;) {
      const rows = (await pgc.query(`SELECT ${list} FROM ${table}${where} ORDER BY ${order} LIMIT ${batch} OFFSET ${offset}`, values)).rows
      if (rows.length === 0) break
      await my.query(guardedUpsertMysql(table, columns, rows.length), rows.flatMap((r) => columns.map((c) => toMysqlValue(r[c]))))
      perTable[table] += rows.length
      total += rows.length
      offset += rows.length
    }
  }
  return { rows: total, perTable }
}

/** Rows per team-scoped table that belong to the `teams` (what --exclude-junk-teams leaves out). */
export const teamRowCounts = async (pgc: PgLike, teams: ReadonlyArray<string>): Promise<Record<string, number>> => {
  const out: Record<string, number> = {}
  for (const [table, col] of Object.entries(TEAM_COLUMN)) {
    out[table] = teams.length === 0 ? 0 : Number((await pgc.query(`SELECT count(*) AS n FROM ${table} WHERE "${col}" = ANY($1::text[])`, [[...teams]])).rows[0]?.n ?? 0)
  }
  return out
}

/** The CLI's junk-team choice: excluded unless --include-junk-teams; both flags at once is an error. */
export const junkMode = (argv: ReadonlyArray<string>): "exclude" | "include" => {
  const include = argv.includes("--include-junk-teams")
  if (include && argv.includes("--exclude-junk-teams")) throw new Error("--include-junk-teams and --exclude-junk-teams are exclusive")
  return include ? "include" : "exclude"
}

/** KEY=value lines of a ~/.secrets env file (values never printed). */
const readEnvFile = (path: string): Record<string, string> =>
  Object.fromEntries(
    readFileSync(path, "utf8")
      .split("\n")
      .map((l) => l.match(/^([A-Z0-9_]+)=(.*)$/))
      .filter((m): m is RegExpMatchArray => m !== null)
      .map((m) => [m[1]!, m[2]!.replace(/^["']|["']$/g, "")])
  )

if (import.meta.main) {
  const branch = process.argv[process.argv.indexOf("--branch") + 1]
  if (!["development", "staging", "main"].includes(branch ?? "")) {
    console.error("usage: bun copy-pg-to-mysql.ts --branch development|staging|main [--exclude-junk-teams | --include-junk-teams] [--verify-only] [--my-url-env VAR]")
    process.exit(2)
  }
  const junk = junkMode(process.argv)
  // The Postgres branch is named production where the Vitess one is main.
  const pgName = branch === "main" ? "production" : branch!
  const pgEnv = readEnvFile(join(homedir(), ".secrets", `cmux-next-planetscale-${pgName}.env`))
  const pgUrl = pgEnv.DATABASE_URL ?? Object.entries(pgEnv).find(([k]) => k.endsWith("_URL"))?.[1]
  const myUrlVar = process.argv.includes("--my-url-env") ? process.argv[process.argv.indexOf("--my-url-env") + 1] : undefined
  const myUrl = myUrlVar ? process.env[myUrlVar] : undefined
  const myEnv = myUrl ? {} : readEnvFile(join(homedir(), ".secrets", `cmux-next-vitess-${branch}-rw.env`))
  if (!pgUrl || (!myUrl && !myEnv.DATABASE_HOST)) throw new Error("missing credential file or variable (values are not printed)")
  const pgc = new pg.Client({ connectionString: pgUrl, ssl: { rejectUnauthorized: true } })
  await pgc.connect()
  await pgc.query("SET default_transaction_read_only = on")
  if ((await pgc.query("SHOW default_transaction_read_only")).rows[0]?.default_transaction_read_only !== "on") throw new Error("Postgres session is not read-only")
  const my = myUrl
    ? await mysql.createConnection({ uri: myUrl, timezone: "Z", dateStrings: true })
    : await mysql.createConnection({ host: myEnv.DATABASE_HOST, user: myEnv.DATABASE_USERNAME, password: myEnv.DATABASE_PASSWORD, database: myEnv.DATABASE_NAME, ssl: { rejectUnauthorized: true }, timezone: "Z", dateStrings: true })
  await my.query("SET time_zone = '+00:00'")
  try {
    const excludeTeams = junk === "exclude" ? await junkTeams(pgc) : []
    console.log(JSON.stringify({ step: "junk", branch, mode: junk, teams: excludeTeams.length, rows_left_out: await teamRowCounts(pgc, excludeTeams) }))
    if (!process.argv.includes("--verify-only")) console.log(JSON.stringify({ step: "copy", branch, ...(await copyTables(pgc, my, { excludeTeams })) }))
    const report = await verifyTables(pgc, my, { excludeTeams })
    for (const r of report) console.log(JSON.stringify(r))
    const bad = report.filter((r) => !r.equal)
    console.log(bad.length === 0 ? `verify ok: ${report.length} tables equal` : `verify FAILED: ${bad.map((r) => r.table).join(", ")}`)
    process.exitCode = bad.length === 0 ? 0 : 1
  } finally {
    await pgc.end()
    await my.end()
  }
}
