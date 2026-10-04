/**
 * Copy the Postgres `cmux-next` projection into PlanetScale MySQL `cmux-next-vitess`, then verify
 * (state-placement.md 4.5). One environment at a time: development, then staging, then main.
 *
 *   bun copy-pg-to-mysql.ts --branch development|staging|main [--verify-only]
 *
 * Reads Postgres with the read-only credential (~/.secrets/cmux-next-planetscale-ro-<branch>.env,
 * variable DATABASE_URL or the first *_URL in that file) and writes MySQL with the readwriter
 * credential (~/.secrets/cmux-next-vitess-<branch>-rw.env). Never prints a credential.
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
import { PROJECTION_TABLES, rowHash, shapeRow, toMysqlValue } from "./projection-compare.ts"

interface PgLike {
  query(sql: string, values?: Array<unknown>): Promise<{ rows: Array<Record<string, unknown>> }>
}
interface MyLike {
  query(sql: string, values?: Array<unknown>): Promise<unknown>
}

const mysqlColumns = async (my: MyLike, table: string): Promise<Array<string>> => {
  const [rows] = (await my.query("SELECT column_name AS c FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? ORDER BY ordinal_position", [table])) as [Array<{ c: string }>]
  return rows.map((r) => r.c)
}
const pgColumns = async (pgc: PgLike, table: string): Promise<Set<string>> =>
  new Set((await pgc.query("SELECT column_name AS c FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND is_generated = 'NEVER'", [table])).rows.map((r) => String(r.c)))

/** The columns both databases have (Postgres-only columns such as the tsvector are left out). */
const sharedColumns = async (pgc: PgLike, my: MyLike, table: string) => {
  const inPg = await pgColumns(pgc, table)
  return (await mysqlColumns(my, table)).filter((c) => inPg.has(c))
}

export const copyTables = async (pgc: PgLike, my: MyLike, batch = 500): Promise<{ rows: number; perTable: Record<string, number> }> => {
  const perTable: Record<string, number> = {}
  let total = 0
  for (const [table, spec] of Object.entries(PROJECTION_TABLES)) {
    const columns = await sharedColumns(pgc, my, table)
    const keys = new Set(spec.key)
    const guarded = columns.filter((c) => !keys.has(c) && c !== "source_seq")
    const set = [
      ...guarded.map((c) => `\`${c}\` = IF(\`source_seq\` <= VALUES(\`source_seq\`), VALUES(\`${c}\`), \`${c}\`)`),
      "`source_seq` = GREATEST(`source_seq`, VALUES(`source_seq`))"
    ].join(", ")
    const list = columns.map((c) => `"${c}"`).join(", ")
    const order = spec.key.map((k) => `"${k}"`).join(", ")
    let offset = 0
    perTable[table] = 0
    for (;;) {
      const rows = (await pgc.query(`SELECT ${list} FROM ${table} ORDER BY ${order} LIMIT ${batch} OFFSET ${offset}`)).rows
      if (rows.length === 0) break
      const placeholders = rows.map(() => `(${columns.map(() => "?").join(", ")})`).join(", ")
      const values = rows.flatMap((r) => columns.map((c) => toMysqlValue(r[c])))
      await my.query(`INSERT INTO \`${table}\` (${columns.map((c) => `\`${c}\``).join(", ")}) VALUES ${placeholders} ON DUPLICATE KEY UPDATE ${set}`, values)
      perTable[table] += rows.length
      total += rows.length
      offset += rows.length
    }
  }
  return { rows: total, perTable }
}

export interface TableReport {
  readonly table: string
  readonly equal: boolean
  readonly pgCount: number
  readonly mysqlCount: number
  readonly missingInMysql: Array<string>
  readonly missingInPostgres: Array<string>
  readonly changed: Array<string>
}

export const verifyTables = async (pgc: PgLike, my: MyLike): Promise<Array<TableReport>> => {
  const out: Array<TableReport> = []
  for (const [table, spec] of Object.entries(PROJECTION_TABLES)) {
    const columns = (await sharedColumns(pgc, my, table)).filter((c) => !spec.skip.includes(c))
    const keyOf = (r: Record<string, unknown>) => spec.key.map((k) => String(r[k])).join("/")
    const pgRows = (await pgc.query(`SELECT ${columns.map((c) => `"${c}"`).join(", ")} FROM ${table}`)).rows
    const [myRows] = (await my.query(`SELECT ${columns.map((c) => `\`${c}\``).join(", ")} FROM \`${table}\``)) as [Array<Record<string, unknown>>]
    const pgHash = new Map(pgRows.map((r) => [keyOf(r), rowHash(shapeRow(r, columns))]))
    const myHash = new Map(myRows.map((r) => [keyOf(r), rowHash(shapeRow(r, columns))]))
    const missingInMysql = [...pgHash.keys()].filter((k) => !myHash.has(k)).sort()
    const missingInPostgres = [...myHash.keys()].filter((k) => !pgHash.has(k)).sort()
    const changed = [...pgHash.keys()].filter((k) => myHash.has(k) && myHash.get(k) !== pgHash.get(k)).sort()
    out.push({ table, equal: missingInMysql.length + missingInPostgres.length + changed.length === 0, pgCount: pgRows.length, mysqlCount: myRows.length, missingInMysql, missingInPostgres, changed })
  }
  return out
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
  const pgEnv = readEnvFile(join(homedir(), ".secrets", `cmux-next-planetscale-ro-${pgName}.env`))
  const pgUrl = pgEnv.DATABASE_URL ?? Object.entries(pgEnv).find(([k]) => k.endsWith("_URL"))?.[1]
  const myEnv = readEnvFile(join(homedir(), ".secrets", `cmux-next-vitess-${branch}-rw.env`))
  if (!pgUrl || !myEnv.DATABASE_HOST) throw new Error("missing credential file or variable (values are not printed)")
  const pgc = new pg.Client({ connectionString: pgUrl, ssl: { rejectUnauthorized: true } })
  await pgc.connect()
  await pgc.query("SET default_transaction_read_only = on")
  const my = await mysql.createConnection({ host: myEnv.DATABASE_HOST, user: myEnv.DATABASE_USERNAME, password: myEnv.DATABASE_PASSWORD, database: myEnv.DATABASE_NAME, ssl: { rejectUnauthorized: true }, timezone: "Z", dateStrings: true })
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
