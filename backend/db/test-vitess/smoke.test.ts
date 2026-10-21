import { afterAll, beforeAll, describe, expect, it } from "bun:test"
import mysql from "mysql2/promise"
import { applyRows } from "../../apps/api/src/projection.ts"
import { projectionStatementMysql } from "../../apps/api/src/projection-mysql.ts"
import { PROJECTION_TABLES } from "../projection-compare.ts"
import { cases } from "../test-mysql/projection-cases.ts"

/**
 * Vitess-only SQL check (CI against the PlanetScale development branch, which is also the live
 * development shadow): Vitess parses more strictly than MySQL 8.4 (`SAVEPOINT row` passed locally and
 * failed on Vitess, 2026-10-04). Every projection kind and the drain batch run on test-only keys, and
 * exactly those rows are deleted afterwards; no table is emptied.
 */
const url = process.env.VITESS_URL
const run = url ? describe : describe.skip
/** The keys these cases write (projection-cases.ts uses fixed *_p1 / *_P1 ids). */
const KEYS: Record<string, string> = {
  users: "id = 'user_p1'",
  teams: "id IN ('team_p1', 'team_vsmoke1', 'team_vsmoke2', 'team_vsmoke3')",
  installs: "id = 'inst_p1'",
  memberships: "team_id = 'team_p1' AND user_id = 'user_p1'",
  hosts: "id = 'host_p1'",
  automations: "id = 'auto_p1'",
  automation_runs: "id = 'run_p1'",
  connections: "id = 'conn_p1'",
  audit_events: "team_id = 'team_p1'",
  home_conversations: "id = 'conv_P1'",
  home_participants: "conversation_id = 'conv_P1'",
  home_invites: "id = 'inv_P1'",
  home_message_search: "conversation_id = 'conv_P1'"
}

/**
 * Each body against the shared branch may take long when the branch is slow (2026-10-19: every hook
 * hit the 5 s default). Hooks and bodies get one generous limit, and afterAll first waits for a body
 * that is still running after its own timeout, so the cleanup never deletes rows under it.
 */
const LIMIT = 60_000

run("projection SQL on Vitess (test-only keys)", () => {
  let db: mysql.Connection
  let running: Promise<unknown> = Promise.resolve()
  const tracked = (body: () => Promise<void>) => () => {
    const done = body()
    running = Promise.all([running, done.catch(() => {})])
    return done
  }
  const cleanup = async () => {
    for (const table of Object.keys(PROJECTION_TABLES)) await db.query(`DELETE FROM \`${table}\` WHERE ${KEYS[table]}`)
  }
  beforeAll(async () => {
    db = await mysql.createConnection({ uri: url!, timezone: "Z", dateStrings: true })
    await db.query("SET time_zone = '+00:00'")
    await cleanup()
  }, LIMIT)
  afterAll(async () => {
    await running
    await cleanup()
    await db.end()
  }, LIMIT)

  it("every projection kind parses and applies with the seq guard", tracked(async () => {
    for (const c of cases) {
      for (const v of [5, 3, 7]) {
        const s = projectionStatementMysql(c.kind, c.payload(v), "vitess:smoke", v)!
        await db.query(s[0], s[1])
      }
      const [rows] = (await db.query(c.read)) as unknown as [Array<Record<string, unknown>>]
      expect([c.kind, rows[0]?.[c.field]]).toEqual([c.kind, c.expect(7)])
    }
  }), LIMIT)

  it("the drain batch (transaction, savepoints, a poison row) works", tracked(async () => {
    const rows = [
      { id: 1, seq: 1, kind: "team.upsert", payload: { id: "team_vsmoke1", kind: "personal", display_name: "One" } },
      { id: 2, seq: 2, kind: "team.upsert", payload: { id: "team_vsmoke2", kind: "x".repeat(40), display_name: "Too long kind" } },
      { id: 3, seq: 3, kind: "team.upsert", payload: { id: "team_vsmoke3", kind: "personal", display_name: "Three" } }
    ] as never
    const res = await applyRows({ query: (sql: string, values?: Array<unknown>) => db.query(sql, values) }, "team:vsmoke", rows, projectionStatementMysql)
    expect(res.sent).toEqual([1, 3])
    expect(res.dead.map((d) => d.id)).toEqual([2])
  }), LIMIT)
})
