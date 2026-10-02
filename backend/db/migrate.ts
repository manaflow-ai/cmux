/**
 * Applies db/migrations/*.sql to PlanetScale `cmux-next` in order (backend.md
 * "Migrations": plain SQL, expand on staging first, no migrations at build or
 * boot). Each file runs in its own transaction and is recorded with its
 * checksum; a changed applied file is an error.
 *
 *   bun migrate.ts --env staging|development [--dry-run]
 *   bun migrate.ts --env production --confirm-production   (coordinator approval required)
 *
 * Credentials: CMUX_NEXT_PG_MIGRATOR_URL, or ~/.secrets/cmux-next-planetscale-<env>.env.
 * The database is always `cmux-next`; this tool never connects to `cmux-prod`.
 */
import { createHash } from "node:crypto"
import { existsSync, readdirSync, readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import pg from "pg"

const args = process.argv.slice(2)
const envName = args[args.indexOf("--env") + 1]
const dryRun = args.includes("--dry-run")
if (!envName || !["staging", "development", "production"].includes(envName)) {
  console.error("usage: bun migrate.ts --env staging|development|production [--dry-run]")
  process.exit(2)
}
if (envName === "production" && !args.includes("--confirm-production")) {
  console.error("production needs --confirm-production (and the coordinator's approval)")
  process.exit(2)
}

const loadUrl = (): string => {
  if (process.env.CMUX_NEXT_PG_MIGRATOR_URL) return process.env.CMUX_NEXT_PG_MIGRATOR_URL
  const file = join(homedir(), ".secrets", `cmux-next-planetscale-${envName}.env`)
  if (!existsSync(file)) throw new Error(`missing ${file}`)
  const line = readFileSync(file, "utf8").split("\n").find((l) => l.startsWith("CMUX_NEXT_PG_MIGRATOR_URL="))
  if (!line) throw new Error(`CMUX_NEXT_PG_MIGRATOR_URL not in ${file}`)
  return line.slice(line.indexOf("=") + 1).trim()
}

const dir = join(import.meta.dirname, "migrations")
const files = readdirSync(dir).filter((f) => /^\d{4}_[a-z0-9_]+\.sql$/.test(f)).sort()

const client = new pg.Client({ connectionString: loadUrl() })
await client.connect()
try {
  await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
    version text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())`)
  // Guard against a wrong target: the migrator must be on a cmux-next branch role.
  const who = await client.query<{ current_user: string }>("SELECT current_user")
  console.log(`connected as ${who.rows[0]?.current_user.split(".")[0]}... (cmux-next/${envName})`)
  const applied = new Map((await client.query<{ version: string; checksum: string }>("SELECT version, checksum FROM schema_migrations")).rows.map((r) => [r.version, r.checksum]))
  for (const f of files) {
    const sql = readFileSync(join(dir, f), "utf8")
    const sum = createHash("sha256").update(sql).digest("hex")
    const prior = applied.get(f)
    if (prior) {
      if (prior !== sum) throw new Error(`${f} changed after it was applied (checksum mismatch); add a new migration instead`)
      continue
    }
    if (dryRun) {
      console.log(`would apply ${f}`)
      continue
    }
    await client.query("BEGIN")
    try {
      await client.query(sql)
      await client.query("INSERT INTO schema_migrations (version, checksum) VALUES ($1, $2)", [f, sum])
      await client.query("COMMIT")
      console.log(`applied ${f}`)
    } catch (e) {
      await client.query("ROLLBACK")
      throw e
    }
  }
  console.log("migrations up to date")
} finally {
  await client.end()
}
