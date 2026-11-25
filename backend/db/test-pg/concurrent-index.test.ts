import { afterAll, describe, expect, it } from "bun:test"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import pg from "pg"

/**
 * migrate.ts applies a CREATE/DROP INDEX CONCURRENTLY file outside a transaction (Postgres
 * refuses it inside one), recovers the INVALID index an interrupted build leaves, and keeps every
 * other file in its own transaction. Each case runs the real CLI against a throwaway database on
 * the scratch Postgres.
 */
const url = process.env.SCRATCH_URL
const run = url ? describe : describe.skip
const root = join(import.meta.dir, "..")
const scratch = mkdtempSync(join(tmpdir(), "cmux-next-migrate-"))
const databases: Array<string> = []

const admin = async <T>(fn: (c: pg.Client) => Promise<T>): Promise<T> => {
  const c = new pg.Client({ connectionString: url })
  await c.connect()
  try {
    return await fn(c)
  } finally {
    await c.end()
  }
}

afterAll(async () => {
  if (url) await admin(async (c) => { for (const d of databases) await c.query(`DROP DATABASE IF EXISTS "${d}" WITH (FORCE)`) })
  rmSync(scratch, { recursive: true, force: true })
})

/** A fresh database and a migrations dir holding `files`; returns its URL and the dir. */
const setup = async (files: Record<string, string>) => {
  const name = `cmux_next_migrate_${process.pid}_${databases.length}`
  databases.push(name)
  await admin(async (c) => {
    await c.query(`DROP DATABASE IF EXISTS "${name}" WITH (FORCE)`)
    await c.query(`CREATE DATABASE "${name}"`)
  })
  const u = new URL(url!)
  u.pathname = `/${name}`
  const dir = join(scratch, name)
  mkdirSync(dir)
  for (const [f, sql] of Object.entries(files)) writeFileSync(join(dir, f), sql)
  return { dbUrl: u.href, dir }
}

const migrate = (dbUrl: string, dir: string) => {
  const p = Bun.spawnSync(["bun", "migrate.ts", "--url-env", "FIXTURE_URL", "--dir", dir], {
    cwd: root,
    env: { ...process.env, FIXTURE_URL: dbUrl },
  })
  return { code: p.exitCode, out: `${p.stdout.toString()}${p.stderr.toString()}` }
}

const query = async (dbUrl: string, sql: string) => {
  const c = new pg.Client({ connectionString: dbUrl })
  await c.connect()
  try {
    return (await c.query(sql)).rows
  } finally {
    await c.end()
  }
}

const valid = async (dbUrl: string, index: string) =>
  (await query(dbUrl, `SELECT (SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass('${index}')) AS v`))[0]!.v as boolean | null
const versions = async (dbUrl: string) => (await query(dbUrl, "SELECT version FROM schema_migrations ORDER BY version")).map((r) => r.version as string)

const table = "-- phase: expand\nCREATE TABLE t (id int PRIMARY KEY, v int);\n"

run("CONCURRENTLY migrations on Postgres", () => {
  it("applies a CREATE INDEX CONCURRENTLY file between transactional files, and a re-run is a no-op", async () => {
    const { dbUrl, dir } = await setup({
      "0001_t.sql": table,
      "0002_t_v.sql": "-- phase: expand\nCREATE INDEX CONCURRENTLY IF NOT EXISTS t_v ON t (v);\n",
      "0003_t_w.sql": "-- phase: expand\nALTER TABLE t ADD COLUMN w int;\n",
    })
    const first = migrate(dbUrl, dir)
    expect(first.out).toContain("applied 0002_t_v.sql to $FIXTURE_URL (outside a transaction)")
    expect(first.code).toBe(0)
    expect(await valid(dbUrl, "t_v")).toBe(true)
    expect(await versions(dbUrl)).toEqual(["0001_t.sql", "0002_t_v.sql", "0003_t_w.sql"])

    const before = await query(dbUrl, "SELECT version, checksum, applied_at FROM schema_migrations ORDER BY version")
    const again = migrate(dbUrl, dir)
    expect(again.code).toBe(0)
    expect(again.out).not.toContain("applied ")
    expect(await query(dbUrl, "SELECT version, checksum, applied_at FROM schema_migrations ORDER BY version")).toEqual(before)
  })

  it("drops and rebuilds the INVALID index an interrupted build left", async () => {
    const { dbUrl, dir } = await setup({
      "0001_t.sql": table,
      "0002_seed.sql": "-- phase: expand\nINSERT INTO t (id, v) VALUES (1, 7), (2, 7);\n",
      "0003_t_v.sql": "-- phase: expand\nCREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS t_v_unique ON t (v);\n",
    })
    // The duplicate fails the build part way: an INVALID index stays and no tracking row is written.
    const failed = migrate(dbUrl, dir)
    expect(failed.code).toBe(1)
    expect(await valid(dbUrl, "t_v_unique")).toBe(false)
    expect(await versions(dbUrl)).toEqual(["0001_t.sql", "0002_seed.sql"])

    // IF NOT EXISTS alone would skip the INVALID index and record the file.
    await query(dbUrl, "DELETE FROM t WHERE id = 2")
    const retried = migrate(dbUrl, dir)
    expect(retried.code).toBe(0)
    expect(await valid(dbUrl, "t_v_unique")).toBe(true)
    expect(await versions(dbUrl)).toEqual(["0001_t.sql", "0002_seed.sql", "0003_t_v.sql"])
  })

  it("applies DROP INDEX CONCURRENTLY outside a transaction", async () => {
    const { dbUrl, dir } = await setup({
      "0001_t.sql": `${table}CREATE INDEX t_v ON t (v);\n`,
      "0002_drop.sql": "-- phase: contract\nDROP INDEX CONCURRENTLY IF EXISTS t_v;\n",
    })
    expect(migrate(dbUrl, dir).code).toBe(0)
    expect(await valid(dbUrl, "t_v")).toBe(null)
    expect(await versions(dbUrl)).toEqual(["0001_t.sql", "0002_drop.sql"])
  })

  it("still rolls back a failing transactional file whole", async () => {
    const { dbUrl, dir } = await setup({
      "0001_t.sql": table,
      "0002_half.sql": "-- phase: expand\nCREATE TABLE half (id int);\nSELECT 1 / 0;\n",
    })
    expect(migrate(dbUrl, dir).code).toBe(1)
    expect((await query(dbUrl, "SELECT to_regclass('half')::text AS t"))[0]!.t).toBe(null)
    expect(await versions(dbUrl)).toEqual(["0001_t.sql"])
  })
})
