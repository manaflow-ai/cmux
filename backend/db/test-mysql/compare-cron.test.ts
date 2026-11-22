import { afterAll, beforeAll, describe, expect, it, spyOn } from "bun:test"
import mysql from "mysql2/promise"
import pg from "pg"
import { projectionStatement } from "../../apps/api/src/projection.ts"
import { projectionStatementMysql } from "../../apps/api/src/projection-mysql.ts"
import { runProjectionCompare } from "../../apps/api/src/projection-compare-cron.ts"
import { PROJECTION_TABLES } from "../projection-compare.ts"
import { cases } from "./projection-cases.ts"

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
})
