/**
 * PlanetScale MySQL (Vitess) migration runner for cmux-next (plans/cmux-next/state-placement.md 4.4).
 *
 *   bun migrate-mysql.ts --lint                      check drizzle-mysql/*.sql against the Vitess rules
 *   bun migrate-mysql.ts --branch development        apply pending migrations (credentials from env)
 *   bun migrate-mysql.ts --branch staging [--verify] same for staging; --verify only checks the history
 *   bun migrate-mysql.ts --url-env MYSQL_URL         a scratch MySQL (tests, CI service container)
 *
 * Credentials come from the environment, never from arguments: either MYSQL_URL-style URL in the
 * variable named by --url-env, or DATABASE_HOST/DATABASE_USERNAME/DATABASE_PASSWORD/DATABASE_NAME
 * (source ~/.secrets/cmux-next-vitess-<branch>-admin.env first). The main branch never runs here:
 * production schema changes go through PlanetScale deploy requests.
 */
import { createHash } from "node:crypto"
import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import mysql from "mysql2/promise"

const DIR = join(import.meta.dir, "drizzle-mysql")

export interface Migration {
  readonly name: string
  readonly checksum: string
  readonly statements: ReadonlyArray<string>
}

export const loadMigrations = (dir = DIR): Array<Migration> =>
  readdirSync(dir)
    .filter((f) => /^\d{4}_[a-z0-9_]+\.sql$/.test(f))
    .sort()
    .map((f) => {
      const text = readFileSync(join(dir, f), "utf8")
      return {
        name: f.replace(/\.sql$/, ""),
        checksum: createHash("sha256").update(text).digest("hex"),
        statements: text.split("--> statement-breakpoint").map((s) => s.trim()).filter(Boolean)
      }
    })

/** Vitess and single-writer rules: what a migration may not contain. Returns one message per problem. */
export const lintSql = (name: string, statements: ReadonlyArray<string>): Array<string> => {
  const problems: Array<string> = []
  for (const s of statements) {
    const upper = s.toUpperCase()
    if (/\bFOREIGN\s+KEY\b|\bREFERENCES\b/.test(upper)) problems.push(`${name}: foreign keys are not allowed (Vitess; the owning DO keeps integrity)`)
    if (/\bPARTITION\s+BY\b/.test(upper)) problems.push(`${name}: partitions are not allowed (Vitess shards by keyspace)`)
    if (/\bCREATE\s+(TRIGGER|PROCEDURE|FUNCTION|EVENT)\b/.test(upper)) problems.push(`${name}: triggers, routines and events are not allowed`)
    if (/\bCHECK\s*\(/.test(upper)) problems.push(`${name}: CHECK constraints are not allowed (the owning DO validates)`)
    if (/^\s*CREATE\s+TABLE\b/.test(upper) && !/\bPRIMARY\s+KEY\b/.test(upper)) problems.push(`${name}: every table needs a primary key`)
    if (/^\s*DROP\s+(TABLE|DATABASE)\b/.test(upper)) problems.push(`${name}: DROP TABLE/DATABASE needs a deploy request and a written plan, not a migration`)
  }
  return problems
}

const arg = (flag: string): string | undefined => {
  const i = process.argv.indexOf(flag)
  return i >= 0 ? process.argv[i + 1] : undefined
}

export const connect = async (urlEnv?: string) => {
  const common = { multipleStatements: false, timezone: "Z" as const, dateStrings: true }
  const conn = urlEnv
    ? await mysql.createConnection({ uri: process.env[urlEnv] ?? "", ...common })
    : await mysql.createConnection({
        host: process.env.DATABASE_HOST,
        user: process.env.DATABASE_USERNAME,
        password: process.env.DATABASE_PASSWORD,
        database: process.env.DATABASE_NAME,
        ssl: { rejectUnauthorized: true },
        ...common
      })
  await conn.query("SET time_zone = '+00:00'")
  return conn
}

export const apply = async (conn: mysql.Connection, migrations: ReadonlyArray<Migration>, verifyOnly = false): Promise<{ applied: Array<string>; pending: Array<string> }> => {
  await conn.query(
    "CREATE TABLE IF NOT EXISTS schema_migrations (name varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY, checksum char(64) CHARACTER SET ascii NOT NULL, applied_at datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)))"
  )
  const [rows] = (await conn.query("SELECT name, checksum FROM schema_migrations")) as unknown as [Array<{ name: string; checksum: string }>]
  const done = new Map(rows.map((r) => [r.name, r.checksum]))
  for (const [name, checksum] of done) {
    const local = migrations.find((m) => m.name === name)
    if (!local) throw new Error(`applied migration ${name} is missing locally`)
    if (local.checksum !== checksum) throw new Error(`applied migration ${name} was edited after it ran (checksum differs)`)
  }
  const pending = migrations.filter((m) => !done.has(m.name))
  if (verifyOnly) return { applied: [], pending: pending.map((m) => m.name) }
  const applied: Array<string> = []
  for (const m of pending) {
    // MySQL DDL commits implicitly, so a migration is not atomic: each one is small and re-runnable
    // only after a fix; the history row is written after its last statement succeeds.
    for (const s of m.statements) await conn.query(s)
    await conn.query("INSERT INTO schema_migrations (name, checksum) VALUES (?, ?)", [m.name, m.checksum])
    applied.push(m.name)
  }
  return { applied, pending: [] }
}

if (import.meta.main) {
  const migrations = loadMigrations()
  const problems = migrations.flatMap((m) => lintSql(m.name, m.statements))
  if (problems.length > 0) {
    for (const p of problems) console.error(p)
    process.exit(1)
  }
  if (process.argv.includes("--lint")) {
    console.log(`lint ok: ${migrations.length} migration(s)`)
    process.exit(0)
  }
  const branch = arg("--branch")
  const urlEnv = arg("--url-env")
  if (!urlEnv && branch !== "development" && branch !== "staging") {
    console.error("usage: --branch development|staging, or --url-env VAR (main uses PlanetScale deploy requests)")
    process.exit(2)
  }
  const conn = await connect(urlEnv)
  try {
    const result = await apply(conn, migrations, process.argv.includes("--verify"))
    if (process.argv.includes("--verify")) {
      if (result.pending.length > 0) {
        console.error(`pending: ${result.pending.join(", ")}`)
        process.exit(1)
      }
      console.log("verify ok: history matches")
    } else console.log(result.applied.length > 0 ? `applied: ${result.applied.join(", ")}` : "up to date")
  } finally {
    await conn.end()
  }
}
