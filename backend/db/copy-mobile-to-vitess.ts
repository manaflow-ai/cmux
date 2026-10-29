/**
 * Copy cmux-mobile-api's Postgres tables (cmux-mobile-dev / cmux-mobile-prod: devices, push_tokens,
 * team_prefs) into cmux-next-vitess `mobile_*` (drizzle-mysql 0002_mobile), then verify every row.
 *
 *   bun copy-mobile-to-vitess.ts --pg-url-env PG --my-url-env MY [--verify-only]
 *
 * Both URLs come from environment variables, never arguments, and are never printed. The Postgres
 * session is forced read-only. A MySQL row whose updated_at is newer than the Postgres one (written by
 * the Worker after its switch to Vitess) keeps its values, so the copy can run again after the switch.
 * Verify compares counts and a sha256 of each row's normalized values; any difference exits 1.
 */
import { createHash } from "node:crypto"
import mysql from "mysql2/promise"
import pg from "pg"

export interface PgLike {
  query(sql: string): Promise<{ rows: Array<Record<string, unknown>> }>
}
export interface MyLike {
  query(sql: string, values?: Array<unknown>): Promise<unknown>
}

interface Spec {
  readonly pg: string
  readonly my: string
  readonly key: ReadonlyArray<string>
  readonly columns: ReadonlyArray<string>
  readonly times: ReadonlyArray<string>
  readonly bools: ReadonlyArray<string>
  readonly uuids: ReadonlyArray<string>
}

export const MOBILE_TABLES: ReadonlyArray<Spec> = [
  {
    pg: "devices",
    my: "mobile_devices",
    key: ["device_id"],
    columns: ["device_id", "owner_user_id", "team_id", "kind", "name", "wg_public_key", "machine_id", "created_at", "updated_at", "last_seen_at"],
    times: ["created_at", "updated_at", "last_seen_at"],
    bools: [],
    uuids: ["device_id"]
  },
  {
    pg: "push_tokens",
    my: "mobile_push_tokens",
    key: ["device_id"],
    columns: ["device_id", "owner_user_id", "token", "environment", "topic", "kinds", "muted_macs", "previews", "updated_at"],
    times: ["updated_at"],
    bools: ["previews"],
    uuids: ["device_id"]
  },
  {
    pg: "team_prefs",
    my: "mobile_team_prefs",
    key: ["user_id", "team_id"],
    columns: ["user_id", "team_id", "color", "emoji", "transparent", "updated_at"],
    times: ["updated_at"],
    bools: ["transparent"],
    uuids: []
  }
]

/** A timestamp as "YYYY-MM-DD HH:MM:SS.mmm" UTC (MySQL datetime(3)); Postgres keeps microseconds, MySQL milliseconds. */
const time = (v: unknown): string | null => {
  if (v === null || v === undefined) return null
  const d = v instanceof Date ? v : new Date(String(v).replace(" ", "T") + (String(v).match(/Z|[+-]\d\d(:?\d\d)?$/) ? "" : "Z"))
  return d.toISOString().replace("T", " ").replace("Z", "")
}

/** One row's values in a form both databases produce the same way. */
export const normalize = (spec: Spec, r: Record<string, unknown>): Array<unknown> =>
  spec.columns.map((c) => {
    const v = r[c]
    if (spec.times.includes(c)) return time(v)
    if (spec.bools.includes(c)) return v === null || v === undefined ? null : v === true || Number(v) === 1
    if (spec.uuids.includes(c)) return String(v).toLowerCase()
    return v ?? null
  })

const rowHash = (vals: ReadonlyArray<unknown>) => createHash("sha256").update(JSON.stringify(vals)).digest("hex")

export const copyMobile = async (pgc: PgLike, my: MyLike): Promise<Record<string, number>> => {
  const out: Record<string, number> = {}
  for (const spec of MOBILE_TABLES) {
    const rows = (await pgc.query(`SELECT ${spec.columns.join(", ")} FROM ${spec.pg} ORDER BY ${spec.key.join(", ")}`)).rows
    let copied = 0
    for (let i = 0; i < rows.length; i += 200) {
      const batch = rows.slice(i, i + 200)
      const marks = batch.map(() => `(${spec.columns.map(() => "?").join(", ")})`).join(", ")
      // Keep a MySQL row that is newer (written after the Worker switched to Vitess).
      const keep = "VALUES(updated_at) >= updated_at"
      const set = spec.columns.filter((c) => !spec.key.includes(c)).map((c) => `${c} = IF(${keep}, VALUES(${c}), ${c})`)
      // updated_at goes last: the IF() of the other columns must read the old value.
      const ordered = [...set.filter((s) => !s.startsWith("updated_at ")), ...set.filter((s) => s.startsWith("updated_at "))]
      await my.query(`INSERT INTO ${spec.my} (${spec.columns.join(", ")}) VALUES ${marks} ON DUPLICATE KEY UPDATE ${ordered.join(", ")}`, batch.flatMap((r) => normalize(spec, r)))
      copied += batch.length
    }
    out[spec.my] = copied
  }
  return out
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

export const verifyMobile = async (pgc: PgLike, my: MyLike): Promise<Array<TableReport>> => {
  const out: Array<TableReport> = []
  for (const spec of MOBILE_TABLES) {
    const pgRows = (await pgc.query(`SELECT ${spec.columns.join(", ")} FROM ${spec.pg}`)).rows
    const [myRows] = (await my.query(`SELECT ${spec.columns.join(", ")} FROM ${spec.my}`)) as [Array<Record<string, unknown>>]
    const index = (rows: Array<Record<string, unknown>>) =>
      new Map(
        rows.map((r) => {
          const n = normalize(spec, r)
          return [spec.key.map((k) => n[spec.columns.indexOf(k)]).join("\u0000"), rowHash(n)] as const
        })
      )
    const a = index(pgRows)
    const b = index(myRows)
    const missingInMysql = [...a.keys()].filter((k) => !b.has(k))
    const missingInPostgres = [...b.keys()].filter((k) => !a.has(k))
    const changed = [...a.keys()].filter((k) => b.has(k) && b.get(k) !== a.get(k))
    out.push({
      table: spec.my,
      equal: missingInMysql.length + missingInPostgres.length + changed.length === 0,
      pgCount: pgRows.length,
      mysqlCount: myRows.length,
      missingInMysql,
      missingInPostgres,
      changed
    })
  }
  return out
}

if (import.meta.main) {
  const arg = (f: string) => (process.argv.includes(f) ? process.argv[process.argv.indexOf(f) + 1] : undefined)
  const pgUrl = process.env[arg("--pg-url-env") ?? ""]
  const myUrl = process.env[arg("--my-url-env") ?? ""]
  if (!pgUrl || !myUrl) {
    console.error("usage: bun copy-mobile-to-vitess.ts --pg-url-env PG --my-url-env MY [--verify-only] (both variables set)")
    process.exit(2)
  }
  const pgc = new pg.Client({ connectionString: pgUrl })
  await pgc.connect()
  await pgc.query("SET default_transaction_read_only = on")
  await pgc.query("SET TIME ZONE 'UTC'")
  const my = await mysql.createConnection({ uri: myUrl, timezone: "Z", dateStrings: true })
  await my.query("SET time_zone = '+00:00'")
  try {
    if (!process.argv.includes("--verify-only")) console.log(JSON.stringify({ step: "copy", ...(await copyMobile(pgc, my)) }))
    const report = await verifyMobile(pgc, my)
    for (const r of report) console.log(JSON.stringify(r))
    const bad = report.filter((r) => !r.equal)
    console.log(bad.length === 0 ? `verify ok: ${report.length} tables equal` : `verify FAILED: ${bad.map((r) => r.table).join(", ")}`)
    process.exitCode = bad.length === 0 ? 0 : 1
  } finally {
    await pgc.end()
    await my.end()
  }
}
