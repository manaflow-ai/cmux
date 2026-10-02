/**
 * Migrations for PlanetScale `cmux-next` (never `cmux-prod`). Plain SQL files in
 * db/migrations, applied in order, each in its own transaction, recorded with a
 * checksum in `schema_migrations`. PlanetScale Postgres has no deploy requests,
 * so safety comes from expand/contract rules and the pre-merge pipeline
 * (skills/cmux-backend-migrations/SKILL.md).
 *
 *   bun migrate.ts --lint                         check files: names, phase header, expand rules
 *   bun migrate.ts --env <env> [--dry-run]        apply pending files
 *   bun migrate.ts --env <env> --verify           exit 1 unless every file is applied with its checksum
 *   bun migrate.ts --url-env DATABASE_URL ...     use a URL from that variable (CI scratch Postgres)
 *
 * <env>: development | staging | production (production also needs --confirm-production
 * to apply; --verify does not). Credentials: CMUX_NEXT_PG_MIGRATOR_URL, else
 * ~/.secrets/cmux-next-planetscale-<env>.env.
 */
import { createHash } from "node:crypto"
import { existsSync, readdirSync, readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const args = process.argv.slice(2)
const flag = (name: string) => args.includes(name)
const value = (name: string) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined)

const dir = join(import.meta.dirname, "migrations")
const NAME = /^(\d{4})_[a-z0-9_]+\.sql$/
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort()

export type Phase = "expand" | "contract"

/** Statements that break code already deployed: allowed only in a contract migration. */
const CONTRACT_ONLY: ReadonlyArray<[RegExp, string]> = [
  [/\bDROP\s+(TABLE|COLUMN|INDEX|SCHEMA|TYPE|VIEW|FUNCTION|CONSTRAINT)\b/i, "DROP"],
  [/\bRENAME\b/i, "RENAME"],
  [/\bALTER\s+COLUMN\s+\S+\s+(SET\s+DATA\s+)?TYPE\b/i, "ALTER COLUMN ... TYPE"],
  [/\bALTER\s+COLUMN\s+\S+\s+SET\s+NOT\s+NULL\b/i, "SET NOT NULL"],
  [/\bTRUNCATE\b/i, "TRUNCATE"],
  [/\bDELETE\s+FROM\b/i, "DELETE FROM"]
]

export const lintFile = (name: string, sql: string): Array<string> => {
  const errors: Array<string> = []
  if (!NAME.test(name)) errors.push(`${name}: name must be NNNN_lower_snake.sql`)
  const header = sql.match(/^--\s*phase:\s*(expand|contract)\b/m)
  // 0001 predates the header rule.
  const phase: Phase | undefined = header ? (header[1] as Phase) : name.startsWith("0001_") ? "expand" : undefined
  if (!phase) errors.push(`${name}: first lines must declare "-- phase: expand" or "-- phase: contract"`)
  const code = sql.replace(/--.*$/gm, "")
  if (phase === "expand") {
    for (const [re, what] of CONTRACT_ONLY) if (re.test(code)) errors.push(`${name}: ${what} is a contract change; put it in a separate "-- phase: contract" migration`)
    // A new NOT NULL column without a default fails on existing rows and breaks old writers.
    for (const m of code.matchAll(/\bADD\s+COLUMN\s+[^,;]*\bNOT\s+NULL\b[^,;]*/gi)) {
      if (!/\bDEFAULT\b/i.test(m[0])) errors.push(`${name}: ADD COLUMN ... NOT NULL needs a DEFAULT in an expand migration`)
    }
  }
  if (/\b(BEGIN|COMMIT)\s*;/i.test(code)) errors.push(`${name}: do not write BEGIN/COMMIT; the runner wraps each file in a transaction`)
  return errors
}

export const phaseOf = (sql: string): Phase => (sql.match(/^--\s*phase:\s*(expand|contract)\b/m)?.[1] as Phase | undefined) ?? "expand"

const checksum = (sql: string) => createHash("sha256").update(sql).digest("hex")

if (import.meta.main) {
  if (flag("--lint")) {
    const errors = files.flatMap((f) => lintFile(f, readFileSync(join(dir, f), "utf8")))
    const versions = files.map((f) => f.slice(0, 4))
    if (new Set(versions).size !== versions.length) errors.push("two migrations share a number")
    if (errors.length) {
      for (const e of errors) console.error(`lint: ${e}`)
      process.exit(1)
    }
    console.log(`lint ok: ${files.length} migrations`)
    process.exit(0)
  }

  const envName = value("--env")
  const urlEnv = value("--url-env")
  const verify = flag("--verify")
  const dryRun = flag("--dry-run")
  if (!urlEnv && (!envName || !["staging", "development", "production"].includes(envName))) {
    console.error("usage: bun migrate.ts --lint | --env development|staging|production [--verify|--dry-run] | --url-env VAR")
    process.exit(2)
  }
  if (envName === "production" && !verify && !dryRun && !flag("--confirm-production")) {
    console.error("applying to production needs --confirm-production (the pre-merge pipeline passes it)")
    process.exit(2)
  }

  const loadUrl = (): string => {
    if (urlEnv) {
      const u = process.env[urlEnv]
      if (!u) throw new Error(`${urlEnv} is empty`)
      return u
    }
    if (process.env.CMUX_NEXT_PG_MIGRATOR_URL) return process.env.CMUX_NEXT_PG_MIGRATOR_URL
    const file = join(homedir(), ".secrets", `cmux-next-planetscale-${envName}.env`)
    if (!existsSync(file)) throw new Error(`missing ${file} and CMUX_NEXT_PG_MIGRATOR_URL`)
    const line = readFileSync(file, "utf8").split("\n").find((l) => l.startsWith("CMUX_NEXT_PG_MIGRATOR_URL="))
    if (!line) throw new Error(`CMUX_NEXT_PG_MIGRATOR_URL not in ${file}`)
    return line.slice(line.indexOf("=") + 1).trim()
  }

  const { default: pg } = await import("pg")
  const client = new pg.Client({ connectionString: loadUrl() })
  await client.connect()
  const target = urlEnv ? `$${urlEnv}` : `cmux-next/${envName}`
  try {
    await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
      version text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())`)
    const applied = new Map(
      (await client.query<{ version: string; checksum: string }>("SELECT version, checksum FROM schema_migrations")).rows.map((r) => [r.version, r.checksum])
    )
    const pending: Array<string> = []
    for (const f of files) {
      const sql = readFileSync(join(dir, f), "utf8")
      const prior = applied.get(f)
      if (prior && prior !== checksum(sql)) throw new Error(`${f} changed after it was applied to ${target}; add a new migration instead`)
      if (!prior) pending.push(f)
    }
    if (verify) {
      if (pending.length) {
        console.error(`${target}: not applied: ${pending.join(", ")}`)
        process.exit(1)
      }
      console.log(`${target}: all ${files.length} migrations applied`)
    } else {
      for (const f of pending) {
        if (dryRun) {
          console.log(`would apply ${f} to ${target}`)
          continue
        }
        const sql = readFileSync(join(dir, f), "utf8")
        await client.query("BEGIN")
        try {
          await client.query(sql)
          await client.query("INSERT INTO schema_migrations (version, checksum) VALUES ($1, $2)", [f, checksum(sql)])
          await client.query("COMMIT")
          console.log(`applied ${f} to ${target}`)
        } catch (e) {
          await client.query("ROLLBACK")
          throw e
        }
      }
      console.log(`${target}: migrations up to date`)
    }
  } finally {
    await client.end()
  }
}
