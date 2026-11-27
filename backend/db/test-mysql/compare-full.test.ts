import { afterAll, beforeAll, describe, expect, it, spyOn } from "bun:test"
import mysql from "mysql2/promise"
import pg from "pg"
import { projectionStatement } from "../../apps/api/src/projection.ts"
import { projectionStatementMysql } from "../../apps/api/src/projection-mysql.ts"
import { runFullCompare } from "../../apps/api/src/projection-compare-full-cron.ts"
import { PROJECTION_TABLES } from "../projection-compare.ts"
import { selectOnlyMy, selectOnlyPg } from "../projection-compare-full.ts"
import { cases, junkFixture, T0 } from "./projection-cases.ts"

/**
 * The hourly full verify (cmuxterm-hq#4767 step 5) in the Worker: every row of every projected table,
 * keyset pages merged in key order, suspects read again, read only. Real Postgres and MySQL (CI services).
 */
const pgUrl = process.env.SCRATCH_URL
const myUrl = process.env.MYSQL_URL
const run = pgUrl && myUrl ? describe : describe.skip
const TABLES = Object.keys(PROJECTION_TABLES).length

run("projection full compare", () => {
  const pgc = new pg.Client({ connectionString: pgUrl })
  let my: mysql.Connection
  const sql: Array<string> = []
  // Every statement the pass sends is recorded; anything but a SELECT fails the test before it runs.
  const postgres = { query: (q: string, v?: Array<unknown>) => (sql.push(q), /^\s*select\s/i.test(q) ? pgc.query(q, v) : Promise.reject(new Error(`write: ${q}`))) }
  const mysqlDb = { query: (q: string, v?: Array<unknown>) => (sql.push(q), /^\s*select\s/i.test(q) ? my.query(q, v) : Promise.reject(new Error(`write: ${q}`))) }
  const both = async (kind: string, payload: Record<string, unknown>, seq = 5, stream = "s:1") => {
    const p = projectionStatement(kind, payload, stream, seq)!
    const m = projectionStatementMysql(kind, payload, stream, seq)!
    await pgc.query(p[0], p[1])
    await my.query(m[0], m[1])
  }
  const audit = (team: string, n: number) => ({ team, n, op: "team.rename", actor: "user_p1", on_behalf_of: null, tx: `tx${n}`, at: T0 + n, summary: `event ${n}`, detail: { n, note: "x".repeat(200) }, prev_hash: `p${n}`, hash: `h${n}` })
  /** Runs one pass with console captured; returns the parsed events too. */
  const pass = async (extra: Partial<Parameters<typeof runFullCompare>[0]> = {}) => {
    const logs = spyOn(console, "log").mockImplementation(() => {})
    const errors = spyOn(console, "error").mockImplementation(() => {})
    try {
      const result = await runFullCompare({ postgres, mysql: mysqlDb, pass: "2026-10-28T00:07:00.000Z", pageSize: 3, ...extra })
      const events = [...logs.mock.calls, ...errors.mock.calls].map((c) => JSON.parse(String(c[0])) as Record<string, unknown>)
      const errorEvents = errors.mock.calls.map((c) => JSON.parse(String(c[0])) as Record<string, unknown>)
      return { result, events, errorEvents, table: (t: string) => events.find((e) => e.event === "projection.compare.full.table" && e.table === t)!, done: events.find((e) => e.event === "projection.compare.full.done")! }
    } finally {
      logs.mockRestore()
      errors.mockRestore()
    }
  }

  beforeAll(async () => {
    await pgc.connect()
    my = await mysql.createConnection({ uri: myUrl!, timezone: "Z", dateStrings: true })
    await my.query("SET time_zone = '+00:00'")
    for (const t of Object.keys(PROJECTION_TABLES)) {
      await pgc.query(`DELETE FROM ${t}`)
      await my.query(`DELETE FROM ${t}`)
    }
    for (const c of cases) await both(c.kind, c.payload(5))
    // Enough rows for several pages at pageSize 3, with ids and numeric keys whose text order differs from their order (n 2 < 10).
    for (let i = 0; i < 14; i++) await both("team.upsert", { id: `team_page_${String(i).padStart(2, "0")}`, kind: "personal", display_name: `Team ${i}` })
    // (source_stream, source_seq) is unique in audit_events: each event its own stream.
    for (let n = 1; n <= 12; n++) await both("audit.append", audit("team_p1", n), 1, `s:a${n}`)
  }, 60_000)
  afterAll(async () => {
    await pgc.end()
    await my.end()
  })

  it("equal projections: one equal line per table and a clean, complete done line; only SELECTs are sent", async () => {
    sql.length = 0
    const { result, events, errorEvents, table, done } = await pass()
    expect(result.complete).toBe(true)
    expect(errorEvents).toEqual([])
    expect(events.filter((e) => e.event === "projection.compare.full.table")).toHaveLength(TABLES)
    expect(table("teams")).toMatchObject({ outcome: "equal", level: "info", diffs: 0, postgres_rows: 15, mysql_rows: 15, rows_checked: 15, pass: "2026-10-28T00:07:00.000Z" })
    expect(table("audit_events")).toMatchObject({ outcome: "equal", postgres_rows: 12, mysql_rows: 12 })
    expect(done).toMatchObject({ level: "info", complete: true, clean: true, tables: TABLES, tables_equal: TABLES, tables_diff: [], failed: [], skipped: [], diffs: 0 })
    expect(sql.length).toBeGreaterThan(TABLES * 2)
    expect(sql.filter((q) => !/^\s*select\s/i.test(q))).toEqual([])
  }, 60_000)

  it("a difference on any page is a diff line with its keys, never repaired; the done line is an error", async () => {
    await my.query("UPDATE teams SET display_name = 'drifted' WHERE id = 'team_page_04'")
    await my.query("DELETE FROM teams WHERE id = 'team_page_09'")
    await my.query("INSERT INTO teams (id, kind, display_name, source_stream, source_seq) VALUES ('team_page_10b', 'personal', 'x', 's:9', 1)")
    await my.query("DELETE FROM audit_events WHERE team_id = 'team_p1' AND n = 10")
    try {
      const { result, table, done, events } = await pass()
      expect(result.complete).toBe(true)
      expect(table("teams")).toMatchObject({ outcome: "diff", level: "error", diffs: 3, changed: ["team_page_04"], missing_in_mysql: ["team_page_09"], missing_in_postgres: ["team_page_10b"], postgres_rows: 15, mysql_rows: 15, rows_checked: 16 })
      expect(table("audit_events")).toMatchObject({ outcome: "diff", missing_in_mysql: ["team_p1/10"], changed: [], missing_in_postgres: [] })
      expect(table("hosts")).toMatchObject({ outcome: "equal" })
      expect(done).toMatchObject({ level: "error", complete: true, clean: false, tables_diff: ["teams", "audit_events"], diffs: 4 })
      expect(JSON.stringify(events)).not.toContain("drifted")
      // Read only: whatever the primary, the missing row is still missing and the changed one still changed.
      const [[gone]] = (await my.query("SELECT count(*) AS n FROM teams WHERE id = 'team_page_09'")) as [Array<{ n: number }>]
      expect(Number(gone?.n)).toBe(0)
      const [[row]] = (await my.query("SELECT display_name AS d FROM teams WHERE id = 'team_page_04'")) as [Array<{ d: string }>]
      expect(row?.d).toBe("drifted")
    } finally {
      await my.query("DELETE FROM teams WHERE id = 'team_page_10b'")
      await both("team.upsert", { id: "team_page_04", kind: "personal", display_name: "Team 4" }, 6)
      await both("team.upsert", { id: "team_page_09", kind: "personal", display_name: "Team 9" }, 6)
      const m = projectionStatementMysql("audit.append", audit("team_p1", 10), "s:a10", 1)!
      await my.query(m[0], m[1])
    }
  }, 60_000)

  it("a difference gone by the recheck (the shadow caught up) is not reported", async () => {
    await my.query("UPDATE teams SET display_name = 'behind' WHERE id = 'team_page_07'")
    let rechecks = 0
    const { table, done } = await pass({
      beforeRecheck: async () => {
        rechecks += 1
        await my.query("UPDATE teams SET display_name = 'Team 7' WHERE id = 'team_page_07'")
      }
    })
    expect(rechecks).toBe(1)
    expect(table("teams")).toMatchObject({ outcome: "equal", diffs: 0 })
    expect(done).toMatchObject({ clean: true })
  }, 60_000)

  it("junk teams only Postgres has are left out on both sides, as in the 15-minute compare", async () => {
    const junkIds = new Set(["team_junk", "team_junk_empty"])
    for (const [i, [kind, payload]] of junkFixture.entries()) {
      const p = projectionStatement(kind, payload, `s:j${i}`, 1)!
      await pgc.query(p[0], p[1])
      if (junkIds.has(String(payload.team ?? payload.id))) continue
      const m = projectionStatementMysql(kind, payload, `s:j${i}`, 1)!
      await my.query(m[0], m[1])
    }
    const { done, table } = await pass()
    expect(done).toMatchObject({ clean: true, junk_teams: 2 })
    expect(table("audit_events")).toMatchObject({ outcome: "equal", postgres_rows: 12 })
  }, 60_000)

  it("the per-invocation bound stops the pass: that table is incomplete, the rest skipped, the done line an error", async () => {
    const { result, done, table } = await pass({ maxRows: 20 })
    expect(result.complete).toBe(false)
    expect(done).toMatchObject({ level: "error", complete: false, clean: false })
    const stoppedAt = (done.failed as Array<string>)[0]!
    expect(table(stoppedAt)).toMatchObject({ outcome: "incomplete", level: "error" })
    expect((done.skipped as Array<string>).length + (done.failed as Array<string>).length + Number(done.tables_equal)).toBe(TABLES)
    for (const t of done.skipped as Array<string>) expect(table(t)).toMatchObject({ outcome: "skipped", level: "error" })
    expect(Number(done.rows_read)).toBeLessThanOrEqual(20)
    const late = await pass({ wallMs: 0 })
    expect(late.done).toMatchObject({ complete: false, rows_checked: 0 })
  }, 60_000)

  it("a 16-digit numeric key (text from Postgres, a number from MySQL) compares equal", async () => {
    await both("audit.append", { ...audit("team_p1", 1), n: 1_000_000_000_000_000 }, 1, "s:big16")
    try {
      const { table } = await pass()
      expect(table("audit_events")).toMatchObject({ outcome: "equal", diffs: 0 })
    } finally {
      await pgc.query("DELETE FROM audit_events WHERE n > 1000000")
      await my.query("DELETE FROM audit_events WHERE n > 1000000")
    }
  }, 60_000)

  it("a numeric key past 2^53 fails its table instead of comparing rounded keys", async () => {
    await both("audit.append", { ...audit("team_p1", 1), n: 2 ** 53 }, 1, "s:big53")
    try {
      const { table, done } = await pass()
      expect(table("audit_events")).toMatchObject({ outcome: "failed", level: "error" })
      expect(done).toMatchObject({ complete: false, clean: false, failed: ["audit_events"] })
    } finally {
      await pgc.query("DELETE FROM audit_events WHERE n > 1000000")
      await my.query("DELETE FROM audit_events WHERE n > 1000000")
    }
  }, 60_000)

  it("the SELECT-only handles refuse a write before it reaches the database", async () => {
    const seen: Array<string> = []
    const raw = { query: async (q: string) => (seen.push(q), { rows: [] }) }
    for (const q of ["INSERT INTO teams VALUES (1)", " update teams set x = 1", "DELETE FROM teams", "WITH d AS (DELETE FROM teams RETURNING 1) SELECT 1", "SET x = 1", "SELECT 1; DELETE FROM teams"]) {
      await expect(selectOnlyPg(raw).query(q)).rejects.toThrow("read-only")
      await expect(selectOnlyMy(raw).query(q)).rejects.toThrow("read-only")
    }
    expect(seen).toEqual([])
    await selectOnlyPg(raw).query("SELECT 1")
    expect(seen).toEqual(["SELECT 1"])
  })

  it("measures a pass over a production-sized table (rows, wall and CPU time)", async () => {
    const N = 6000
    for (let n = 13; n < 13 + N; n++) await both("audit.append", audit("team_p1", n), 1, `s:a${n}`)
    const cpu0 = process.cpuUsage()
    const t0 = performance.now()
    const { done, table } = await pass({ pageSize: 1000 })
    const cpu = process.cpuUsage(cpu0)
    const wall = performance.now() - t0
    expect(table("audit_events")).toMatchObject({ outcome: "equal", postgres_rows: 12 + N })
    expect(done).toMatchObject({ clean: true })
    const rows = Number(done.rows_read)
    process.stderr.write(`projection full compare measurement: ${rows} rows read, wall ${wall.toFixed(0)} ms, cpu ${((cpu.user + cpu.system) / 1000).toFixed(0)} ms, ${(((cpu.user + cpu.system) / rows)).toFixed(1)} us cpu/row\n`)
  }, 180_000)
})
