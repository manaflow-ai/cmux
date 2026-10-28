/**
 * Copy the Postgres `cmux-next` projection into PlanetScale MySQL `cmux-next-vitess`, then verify
 * (state-placement.md 4.5). One environment at a time: development, then staging, then main.
 *
 *   bun copy-pg-to-mysql.ts --branch development|staging|main [--verify-only] [--my-url-env VAR]
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
import { PROJECTION_TABLES, guardedUpsertMysql, sharedColumns, toMysqlValue, verifyTables, type MyLike, type PgLike } from "./projection-compare.ts"

export { verifyTables }

export const copyTables = async (pgc: PgLike, my: MyLike, batch = 500): Promise<{ rows: number; perTable: Record<string, number> }> => {
  const perTable: Record<string, number> = {}
  let total = 0
  for (const [table, spec] of Object.entries(PROJECTION_TABLES)) {
    const columns = await sharedColumns(pgc, my, table)
    const list = columns.map((c) => `"${c}"`).join(", ")
    const order = spec.key.map((k) => `"${k}"`).join(", ")
    let offset = 0
    perTable[table] = 0
    for (;;) {
      const rows = (await pgc.query(`SELECT ${list} FROM ${table} ORDER BY ${order} LIMIT ${batch} OFFSET ${offset}`)).rows
      if (rows.length === 0) break
      await my.query(guardedUpsertMysql(table, columns, rows.length), rows.flatMap((r) => columns.map((c) => toMysqlValue(r[c]))))
      perTable[table] += rows.length
      total += rows.length
      offset += rows.length
    }
  }
  return { rows: total, perTable }
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
    console.error("usage: bun copy-pg-to-mysql.ts --branch development|staging|main [--verify-only]")
    process.exit(2)
  }
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
    if (!process.argv.includes("--verify-only")) console.log(JSON.stringify({ step: "copy", branch, ...(await copyTables(pgc, my)) }))
    const report = await verifyTables(pgc, my)
    for (const r of report) console.log(JSON.stringify(r))
    const bad = report.filter((r) => !r.equal)
    console.log(bad.length === 0 ? `verify ok: ${report.length} tables equal` : `verify FAILED: ${bad.map((r) => r.table).join(", ")}`)
    process.exitCode = bad.length === 0 ? 0 : 1
  } finally {
    await pgc.end()
    await my.end()
  }
}
