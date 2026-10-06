import { afterAll, beforeAll, describe, expect, it } from "bun:test"
import mysql from "mysql2/promise"
import { applyRows } from "../../apps/api/src/projection.ts"
import { projectionStatementMysql } from "../../apps/api/src/projection-mysql.ts"

/**
 * The real drain batch on MySQL: one transaction, a savepoint per row, a poison row isolated.
 * Runs on the PlanetScale development branch too, where Vitess parses SQL more strictly than
 * MySQL (2026-10-04: `SAVEPOINT row` is a syntax error on Vitess, so every shadow batch failed).
 */
const url = process.env.MYSQL_URL
const run = url ? describe : describe.skip

run("projection drain batch on MySQL", () => {
  let db: mysql.Connection
  beforeAll(async () => {
    db = await mysql.createConnection({ uri: url!, timezone: "Z", dateStrings: true })
    await db.query("SET time_zone = '+00:00'")
    await db.query("DELETE FROM teams WHERE id LIKE 'team\\_drain%'")
  })
  afterAll(async () => {
    await db.query("DELETE FROM teams WHERE id LIKE 'team\\_drain%'")
    await db.end()
  })

  it("commits the good rows and returns the poison row as dead", async () => {
    const rows = [
      { id: 1, seq: 1, kind: "team.upsert", payload: { id: "team_drain1", kind: "personal", display_name: "One" } },
      { id: 2, seq: 2, kind: "team.upsert", payload: { id: "team_drain2", kind: "x".repeat(40), display_name: "Too long kind" } },
      { id: 3, seq: 3, kind: "team.upsert", payload: { id: "team_drain3", kind: "personal", display_name: "Three" } }
    ] as never
    const client = { query: (sql: string, values?: Array<unknown>) => db.query(sql, values) }
    const res = await applyRows(client, "team:drain", rows, projectionStatementMysql)
    expect(res.sent).toEqual([1, 3])
    expect(res.dead.map((d) => d.id)).toEqual([2])
    const [found] = (await db.query("SELECT id FROM teams WHERE id LIKE 'team\\_drain%' ORDER BY id")) as unknown as [Array<{ id: string }>]
    expect(found.map((r) => r.id)).toEqual(["team_drain1", "team_drain3"])
  })
})
