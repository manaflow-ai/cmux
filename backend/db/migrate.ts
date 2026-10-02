/**
 * Migrations for PlanetScale `cmux-next` (never `cmux-prod`). Plain SQL files,
 * applied in order, each in its own transaction, recorded with a checksum in
 * `schema_migrations`. PlanetScale Postgres has no deploy requests, so safety
 * comes from expand/contract rules (checked on the parsed SQL) and the pre-merge
 * pipeline (skills/cmux-backend-migrations/SKILL.md).
 *
 *   bun migrate.ts --lint [--dir D]                        parse and check every file
 *   bun migrate.ts --env <env> [--dir D] [--dry-run]       apply pending files
 *   bun migrate.ts --env <env> [--dir D] --verify          exit 1 unless the database has exactly the repo's files
 *   bun migrate.ts --url-env VAR ...                       a scratch Postgres URL from VAR (no branch check)
 *
 * <env>: development | staging | production (applying to production needs
 * --confirm-production). Credentials: CMUX_NEXT_PG_MIGRATOR_URL, else
 * ~/.secrets/cmux-next-planetscale-<env>.env. The role's PlanetScale branch id
 * must match <env>, so a wrong URL (for example cmux-prod) is refused.
 */
import { createHash } from "node:crypto"
import { existsSync, readdirSync, readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const args = process.argv.slice(2)
const flag = (name: string) => args.includes(name)
const value = (name: string) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined)

/** PlanetScale branch ids of database `cmux-next` (ops/resources.md). */
const BRANCH_IDS: Record<string, string> = { production: "8ih62d5neek9", staging: "qxst3kra77vx", development: "2o41eh2nrsw8" }
const LOCK_KEY = 0x636d7578 // advisory lock: one migrator at a time per branch

export type Phase = "expand" | "contract"
const NAME = /^(\d{4})_[a-z0-9_]+\.sql$/

export const phaseOf = (sql: string): Phase | undefined => sql.match(/^--\s*phase:\s*(expand|contract)\b/m)?.[1] as Phase | undefined

type Node = Record<string, any>
const kind = (stmt: Node) => Object.keys(stmt)[0]!

/** Expand = only additions the deployed code survives. Everything else is contract. */
const expandProblems = (stmts: Array<Node>): Array<string> => {
  const problems: Array<string> = []
  const created = new Set<string>()
  for (const s of stmts) {
    const k = kind(s)
    const b = s[k]
    switch (k) {
      case "CreateStmt":
        created.add(b.relation?.relname)
        break
      case "IndexStmt":
        if (b.unique && !created.has(b.relation?.relname)) problems.push("CREATE UNIQUE INDEX on an existing table can reject writes from deployed code")
        break
      case "AlterTableStmt":
        for (const c of b.cmds ?? []) {
          const cmd = c.AlterTableCmd
          if (cmd.subtype === "AT_AddColumn") {
            const cons: Array<Node> = (cmd.def?.ColumnDef?.constraints ?? []).map((x: Node) => x.Constraint)
            const types = new Set(cons.map((x) => x.contype))
            for (const t of types) {
              if (!["CONSTR_DEFAULT", "CONSTR_NULL", "CONSTR_NOTNULL"].includes(t)) problems.push(`ADD COLUMN with ${t} on an existing table`)
            }
            if (types.has("CONSTR_NOTNULL") && !types.has("CONSTR_DEFAULT")) problems.push("ADD COLUMN ... NOT NULL needs a DEFAULT")
          } else if (cmd.subtype === "AT_AddConstraint") {
            const con = cmd.def?.Constraint
            if (!con?.skip_validation || !["CONSTR_CHECK", "CONSTR_FOREIGN"].includes(con.contype)) {
              problems.push("ADD CONSTRAINT must be CHECK or FOREIGN KEY with NOT VALID")
            }
          } else if (!created.has(b.relation?.relname)) {
            problems.push(`ALTER TABLE ${cmd.subtype} is a contract change`)
          }
        }
        break
      case "UpdateStmt":
      case "InsertStmt":
      case "CommentStmt":
      case "GrantStmt":
        break
      default:
        problems.push(`${k} is not allowed in an expand migration`)
    }
  }
  return problems
}

export const lintFile = async (name: string, sql: string): Promise<Array<string>> => {
  const { parse } = await import("libpg-query")
  const errors: Array<string> = []
  if (!NAME.test(name)) errors.push(`${name}: name must be NNNN_lower_snake.sql`)
  // 0001 predates the header rule.
  const phase = phaseOf(sql) ?? (name.startsWith("0001_") ? "expand" : undefined)
  if (!phase) errors.push(`${name}: first lines must declare "-- phase: expand" or "-- phase: contract"`)
  let stmts: Array<Node>
  try {
    stmts = ((await parse(sql)) as { stmts?: Array<{ stmt: Node }> }).stmts?.map((s) => s.stmt) ?? []
  } catch (e) {
    return [...errors, `${name}: does not parse: ${(e as Error).message}`]
  }
  if (stmts.some((s) => kind(s) === "TransactionStmt")) errors.push(`${name}: do not write BEGIN/COMMIT; the runner wraps each file in a transaction`)
  if (phase === "expand") for (const p of expandProblems(stmts)) errors.push(`${name}: ${p}; use a separate "-- phase: contract" migration`)
  return errors
}

const checksum = (sql: string) => createHash("sha256").update(sql).digest("hex")

if (import.meta.main) {
  const dir = value("--dir") ?? join(import.meta.dirname, "migrations")
  const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort()

  if (flag("--lint")) {
    const errors = (await Promise.all(files.map((f) => lintFile(f, readFileSync(join(dir, f), "utf8"))))).flat()
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
  if (!urlEnv && (!envName || !(envName in BRANCH_IDS))) {
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

  const url = loadUrl()
  if (!urlEnv) {
    // PlanetScale routes by the branch id after the dot in the user name: refuse any
    // other database or branch (for example a cmux-prod URL).
    const user = decodeURIComponent(new URL(url).username)
    if (!user.endsWith(`.${BRANCH_IDS[envName!]}`)) {
      console.error(`migrate: credentials are not for cmux-next/${envName} (branch ${user.split(".").pop()})`)
      process.exit(1)
    }
  }
  const { default: pg } = await import("pg")
  const client = new pg.Client({ connectionString: url })
  await client.connect()
  const target = urlEnv ? `$${urlEnv}` : `cmux-next/${envName}`
  try {
    const exists = (await client.query<{ t: string | null }>("SELECT to_regclass('public.schema_migrations')::text AS t")).rows[0]!.t !== null
    if (!exists && !verify && !dryRun) {
      await client.query(`CREATE TABLE schema_migrations (version text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())`)
    }
    if (!verify && !dryRun) await client.query("SELECT pg_advisory_lock($1)", [LOCK_KEY])
    const rows = exists || (!verify && !dryRun) ? (await client.query<{ version: string; checksum: string }>("SELECT version, checksum FROM schema_migrations")).rows : []
    const applied = new Map(rows.map((r) => [r.version, r.checksum]))
    // A row the repo lacks: another PR's migration (merge its base first) or an abandoned one (operator fix).
    const unknown = [...applied.keys()].filter((v) => !files.includes(v))
    if (unknown.length) {
      // Development is shared by every open PR's preview, so it may hold another PR's
      // unmerged migration; staging and production must match the tree exactly.
      if (envName === "development") console.warn(`${target} also has migrations this tree lacks: ${unknown.join(", ")} (other open PRs)`)
      else throw new Error(`${target} has migrations this tree lacks: ${unknown.join(", ")}; merge the base branch first`)
    }
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
  } catch (e) {
    console.error(`migrate: ${(e as Error).message}`)
    process.exitCode = 1
  } finally {
    await client.end()
  }
}
