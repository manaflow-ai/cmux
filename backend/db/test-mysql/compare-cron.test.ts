import { afterAll, beforeAll, describe, expect, it, spyOn } from "bun:test"
import mysql from "mysql2/promise"
import pg from "pg"
import { projectionStatement } from "../../apps/api/src/projection.ts"
import { projectionStatementMysql } from "../../apps/api/src/projection-mysql.ts"
import { runProjectionCompare } from "../../apps/api/src/projection-compare-cron.ts"
import { PROJECTION_TABLES } from "../projection-compare.ts"
import { cases, junkFixture } from "./projection-cases.ts"

/**
 * The dual-write safety net (state-placement.md 4.5): the staging Worker's cron compares every
 * projected table between Postgres and MySQL (counts and per-row hashes, bounded rows) and emits an
 * error event for a difference that holds on a second pass. A clean run emits one ok summary.
 */
const pgUrl = process.env.SCRATCH_URL
const myUrl = process.env.MYSQL_URL
const run = pgUrl && myUrl ? describe : describe.skip

run("projection compare cron", () => {
  const pgc = new pg.Client({ connectionString: pgUrl })
  let my: mysql.Connection
  const deps = () => ({
    postgres: { query: (sql: string, values?: Array<unknown>) => pgc.query(sql, values) },
    mysql: { query: (sql: string, values?: Array<unknown>) => my.query(sql, values) },
    maxRows: 1000
  })
  beforeAll(async () => {
    await pgc.connect()
    my = await mysql.createConnection({ uri: myUrl!, timezone: "Z", dateStrings: true })
    await my.query("SET time_zone = '+00:00'")
    for (const t of Object.keys(PROJECTION_TABLES)) {
      await pgc.query(`DELETE FROM ${t}`)
      await my.query(`DELETE FROM ${t}`)
    }
    for (const c of cases) {
      const p = projectionStatement(c.kind, c.payload(5), "s:1", 5)!
      const m = projectionStatementMysql(c.kind, c.payload(5), "s:1", 5)!
      await pgc.query(p[0], p[1])
      await my.query(m[0], m[1])
    }
  }, 60_000)
  afterAll(async () => {
    await pgc.end()
    await my.end()
  })

  it("equal projections give one ok summary and no error", async () => {
    const errors = spyOn(console, "error").mockImplementation(() => {})
    const logs = spyOn(console, "log").mockImplementation(() => {})
    try {
      const report = await runProjectionCompare(deps())
      expect(report.diffs).toEqual([])
      expect(errors).not.toHaveBeenCalled()
      expect(JSON.parse(String(logs.mock.calls.at(-1)?.[0]))).toMatchObject({ event: "projection.compare.ok", tables: 13 })
    } finally {
      errors.mockRestore()
      logs.mockRestore()
    }
  }, 60_000)

  it("a lasting difference is an error event with counts and keys only", async () => {
    await my.query("UPDATE teams SET display_name = 'drifted' WHERE id = 'team_p1'")
    await my.query("DELETE FROM hosts WHERE id = 'host_p1'")
    const errors = spyOn(console, "error").mockImplementation(() => {})
    const logs = spyOn(console, "log").mockImplementation(() => {})
    try {
      const report = await runProjectionCompare(deps())
      expect(report.diffs.map((d) => d.table).sort()).toEqual(["hosts", "teams"])
      const events = errors.mock.calls.map((c) => JSON.parse(String(c[0])))
      expect(events).toContainEqual(expect.objectContaining({ event: "projection.compare.diff", level: "error", table: "teams", changed: ["team_p1"] }))
      expect(events).toContainEqual(expect.objectContaining({ event: "projection.compare.diff", level: "error", table: "hosts", missing_in_mysql: ["host_p1"], postgres_count: 1, mysql_count: 0 }))
      expect(JSON.stringify(events)).not.toContain("drifted")
    } finally {
      errors.mockRestore()
      logs.mockRestore()
    }
  }, 60_000)

  it("a difference gone by the second pass (a write between primary and shadow) is not reported", async () => {
    // Repair the drift between the passes: the first pass sees it, the second does not.
    const m = projectionStatementMysql("team.upsert", { id: "team_p1", kind: "personal", display_name: "Team 5" }, "s:1", 5)!
    let passes = 0
    const d = deps()
    const errors = spyOn(console, "error").mockImplementation(() => {})
    const logs = spyOn(console, "log").mockImplementation(() => {})
    try {
      const report = await runProjectionCompare({
        ...d,
        betweenPasses: async () => {
          passes += 1
          await my.query("UPDATE teams SET display_name = 'Team 5' WHERE id = 'team_p1'")
          await my.query(m[0], m[1])
        }
      })
      expect(passes).toBe(1)
      expect(report.diffs.map((x) => x.table)).toEqual(["hosts"])
    } finally {
      errors.mockRestore()
      logs.mockRestore()
    }
  }, 60_000)
  it("a lasting row missing or stale in the MySQL shadow is repaired from Postgres; extra MySQL rows stay and Postgres is never written", async () => {
    // Drift left by the earlier cases (hosts/host_p1 missing) plus a stale row and a MySQL-only row.
    await my.query("UPDATE teams SET display_name = 'drifted' WHERE id = 'team_p1'")
    await my.query("INSERT INTO teams (id, kind, display_name, source_stream, source_seq) VALUES ('team_only_mysql', 'personal', 'x', 's:9', 1)")
    const pgWrites: Array<string> = []
    const d = deps()
    const readOnlyPg = { query: (sql: string, values?: Array<unknown>) => (/^\s*(insert|update|delete)/i.test(sql) ? (pgWrites.push(sql), Promise.reject(new Error("write"))) : d.postgres.query(sql, values)) }
    const errors = spyOn(console, "error").mockImplementation(() => {})
    const logs = spyOn(console, "log").mockImplementation(() => {})
    try {
      const report = await runProjectionCompare({ ...d, postgres: readOnlyPg, repair: d.mysql })
      expect(report.repaired).toEqual({ hosts: 1, teams: 1 })
      const events = [...errors.mock.calls, ...logs.mock.calls].map((c) => JSON.parse(String(c[0])))
      expect(events).toContainEqual(expect.objectContaining({ event: "projection.compare.repaired", table: "teams", rows: 1 }))
      expect(JSON.stringify(events)).not.toContain("drifted")
      // The next run sees only the MySQL-only row, which a repair never deletes.
      const again = await runProjectionCompare({ ...d, postgres: readOnlyPg, repair: d.mysql })
      expect(again.diffs).toEqual([expect.objectContaining({ table: "teams", missing_in_postgres: ["team_only_mysql"], missing_in_mysql: [], changed: [] })])
      expect(again.repaired).toEqual({})
      const [[left]] = (await my.query("SELECT count(*) AS n FROM teams WHERE id = 'team_only_mysql'")) as [Array<{ n: number }>]
      expect(Number(left?.n)).toBe(1)
      expect(pgWrites).toEqual([])
    } finally {
      errors.mockRestore()
      logs.mockRestore()
      await my.query("DELETE FROM teams WHERE id = 'team_only_mysql'")
    }
  }, 60_000)

  it("a newer MySQL row (the shadow ahead of a slow primary) is never overwritten by an older Postgres row", async () => {
    await my.query("UPDATE teams SET display_name = 'ahead', source_seq = 99 WHERE id = 'team_p1'")
    const d = deps()
    const errors = spyOn(console, "error").mockImplementation(() => {})
    const logs = spyOn(console, "log").mockImplementation(() => {})
    try {
      await runProjectionCompare({ ...d, repair: d.mysql })
      const [[row]] = (await my.query("SELECT display_name AS n, source_seq AS s FROM teams WHERE id = 'team_p1'")) as [Array<{ n: string; s: number }>]
      expect(row).toMatchObject({ n: "ahead" })
      expect(Number(row?.s)).toBe(99)
    } finally {
      errors.mockRestore()
      logs.mockRestore()
    }
  }, 60_000)

  it("junk teams only Postgres has are no difference and are never repaired into MySQL", async () => {
    await my.query("UPDATE teams SET display_name = 'Team 5', source_seq = 5 WHERE id = 'team_p1'")
    const junkIds = new Set(["team_junk", "team_junk_empty"])
    for (const [i, [kind, payload]] of junkFixture.entries()) {
      const p = projectionStatement(kind, payload, `s:j${i}`, 1)!
      await pgc.query(p[0], p[1])
      if (junkIds.has(String(payload.team ?? payload.id))) continue
      const m = projectionStatementMysql(kind, payload, `s:j${i}`, 1)!
      await my.query(m[0], m[1])
    }
    const d = deps()
    const errors = spyOn(console, "error").mockImplementation(() => {})
    const logs = spyOn(console, "log").mockImplementation(() => {})
    try {
      const report = await runProjectionCompare({ ...d, repair: d.mysql })
      expect(report).toEqual({ diffs: [], repaired: {} })
      expect(JSON.parse(String(logs.mock.calls.at(-1)?.[0]))).toMatchObject({ event: "projection.compare.ok", junk_teams: 2 })
      const [[left]] = (await my.query("SELECT count(*) AS n FROM teams WHERE id IN ('team_junk', 'team_junk_empty')")) as [Array<{ n: number }>]
      expect(Number(left?.n)).toBe(0)
    } finally {
      errors.mockRestore()
      logs.mockRestore()
    }
  }, 60_000)
})
