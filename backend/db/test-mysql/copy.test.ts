import { afterAll, beforeAll, describe, expect, it } from "bun:test"
import mysql from "mysql2/promise"
import pg from "pg"
import { projectionStatement } from "../../apps/api/src/projection.ts"
import { projectionStatementMysql } from "../../apps/api/src/projection-mysql.ts"
import { copyTables, junkTeams, teamRowCounts, verifyTables } from "../copy-pg-to-mysql.ts"
import { PROJECTION_TABLES } from "../projection-compare.ts"
import { cases, junkFixture } from "./projection-cases.ts"

/**
 * The Postgres to MySQL copy and verify job (state-placement.md 4.5): a copy makes every table
 * equal (count and per-row hash), never moves a newer MySQL row (a shadow write) backwards, and
 * verify reports a changed or missing row. With --exclude-junk-teams it skips the junk teams (Stack
 * mirrors no cmux-next user is in and never used) and their rows, and verify compares the kept set.
 */
const pgUrl = process.env.SCRATCH_URL
const myUrl = process.env.MYSQL_URL
const run = pgUrl && myUrl ? describe : describe.skip

run("copy Postgres projection rows into MySQL, then verify", () => {
  const pgc = new pg.Client({ connectionString: pgUrl })
  let my: mysql.Connection
  beforeAll(async () => {
    await pgc.connect()
    my = await mysql.createConnection({ uri: myUrl!, timezone: "Z", dateStrings: true })
    await my.query("SET time_zone = '+00:00'")
    for (const t of Object.keys(PROJECTION_TABLES)) {
      await pgc.query(`DELETE FROM ${t}`)
      await my.query(`DELETE FROM ${t}`)
    }
    for (const c of cases) {
      const s = projectionStatement(c.kind, c.payload(5), "s:1", 5)!
      await pgc.query(s[0], s[1])
    }
    // A shadow write already in MySQL that is newer than Postgres must survive the copy.
    const newer = cases.find((c) => c.kind === "team.upsert")!
    const m = projectionStatementMysql(newer.kind, newer.payload(9), "s:1", 9)!
    await my.query(m[0], m[1])
  }, 60_000)
  afterAll(async () => {
    await pgc.end()
    await my.end()
  })

  it("copies every row, keeps the newer MySQL row, and verify then differs only on that row", async () => {
    const copied = await copyTables(pgc, my)
    expect(copied.rows).toBeGreaterThan(10)
    const report = await verifyTables(pgc, my)
    expect(report.filter((r) => r.table !== "teams" && !r.equal)).toEqual([])
    const teams = report.find((r) => r.table === "teams")!
    expect(teams).toMatchObject({ equal: false, pgCount: 1, mysqlCount: 1, changed: ["team_p1"] })
    const [rows] = (await my.query("SELECT display_name, source_seq FROM teams WHERE id = 'team_p1'")) as unknown as [Array<Record<string, unknown>>]
    expect(rows[0]).toMatchObject({ display_name: "Team 9", source_seq: 9 })
  }, 60_000)

  it("verify reports a row missing on either side", async () => {
    await my.query("DELETE FROM hosts")
    const report = await verifyTables(pgc, my)
    expect(report.find((r) => r.table === "hosts")).toMatchObject({ equal: false, missingInMysql: ["host_p1"] })
    await copyTables(pgc, my)
    expect((await verifyTables(pgc, my)).find((r) => r.table === "hosts")!.equal).toBe(true)
  }, 60_000)

  it("--exclude-junk-teams skips the junk teams and their rows; verify compares the kept set", async () => {
    for (const [i, [kind, payload]] of junkFixture.entries()) {
      const s = projectionStatement(kind, payload, `s:j${i}`, 1)!
      await pgc.query(s[0], s[1])
    }
    const junk = await junkTeams(pgc)
    expect(junk).toEqual(["team_junk", "team_junk_empty"])
    expect(await teamRowCounts(pgc, junk)).toMatchObject({ teams: 2, memberships: 1, audit_events: 1, hosts: 0 })
    await copyTables(pgc, my, { excludeTeams: junk, batch: 2 })
    const [kept] = (await my.query("SELECT id FROM teams WHERE kind = 'stack' ORDER BY id")) as unknown as [Array<{ id: string }>]
    expect(kept.map((r) => r.id)).toEqual(["team_stack_named", "team_stack_real", "team_stack_used"])
    const [junkRows] = (await my.query("SELECT (SELECT count(*) FROM memberships WHERE team_id = 'team_junk') + (SELECT count(*) FROM audit_events WHERE team_id = 'team_junk') AS n")) as unknown as [Array<{ n: number }>]
    expect(Number(junkRows[0]?.n)).toBe(0)
    // The kept set is equal (teams differs only on the newer shadow row of the first case).
    const scoped = await verifyTables(pgc, my, { excludeTeams: junk })
    expect(scoped.filter((r) => r.table !== "teams" && !r.equal)).toEqual([])
    expect(scoped.find((r) => r.table === "teams")).toMatchObject({ pgCount: 4, mysqlCount: 4, missingInMysql: [], missingInPostgres: [], changed: ["team_p1"] })
    // Without the filter the skipped rows show as missing in MySQL.
    const full = await verifyTables(pgc, my)
    expect(full.find((r) => r.table === "teams")!.missingInMysql).toEqual(["team_junk", "team_junk_empty"])
    expect(full.find((r) => r.table === "memberships")!.missingInMysql).toEqual(["team_junk/user_anon"])
    expect(full.find((r) => r.table === "audit_events")!.missingInMysql).toEqual(["team_junk/1"])
    // A conversation with no team is never left out by the filter.
    expect(scoped.find((r) => r.table === "home_conversations")).toMatchObject({ equal: true, pgCount: 1 })
  }, 60_000)
})
