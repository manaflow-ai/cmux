import { afterAll, beforeAll, describe, expect, it } from "bun:test"
import mysql from "mysql2/promise"
import pg from "pg"
import { projectionStatement } from "../../apps/api/src/projection.ts"
import { projectionStatementMysql } from "../../apps/api/src/projection-mysql.ts"
import { cases, iso, T0 } from "./projection-cases.ts"
import { norm, PROJECTION_TABLES as TABLES } from "../projection-compare.ts"

/**
 * Parity (state-placement.md 4.5): the same projection inputs through the Postgres path and the
 * MySQL path give the same rows in every table. Needs both scratch databases (CI services; locally
 * SCRATCH_URL from a postgres:17 container and MYSQL_URL from scripts/mysql-scratch.sh).
 */
const pgUrl = process.env.SCRATCH_URL
const myUrl = process.env.MYSQL_URL
const run = pgUrl && myUrl ? describe : describe.skip

/** The inputs: every case at seq 5, 3 (older, ignored), 7, then deletes, audit and a participant re-upsert. */
const script = (): Array<[string, Record<string, unknown>, string, number]> => {
  const out: Array<[string, Record<string, unknown>, string, number]> = []
  for (const c of cases) for (const v of [5, 3, 7]) out.push([c.kind, c.payload(v), "s:1", v])
  out.push(["automation.delete", { id: "auto_p1" }, "s:1", 8])
  out.push(["home.message.upsert", { conversation_id: "conv_P2", seq: 2, message_id: "m2", author_id: "u", author_kind: "agent", created_at: iso(T0), edited_at: null, body: "kept" }, "s:2", 2])
  out.push(["audit.append", { team: "team_p1", n: 1, op: "team.policy.update", actor: "user_p1", on_behalf_of: null, tx: "t", at: T0, summary: "first", detail: { b: 1, a: [1, 2] }, prev_hash: "p", hash: "h" }, "team:team_p1", 1])
  out.push(["home.participant.upsert", { conversation_id: "conv_P1", participant_id: "user_p1", kind: "human", visible_from_seq: 9, left_at: iso(T0 + 50) }, "s:1", 9])
  return out
}

run("Postgres and MySQL projections give the same rows", () => {
  const pgc = new pg.Client({ connectionString: pgUrl })
  let my: mysql.Connection
  beforeAll(async () => {
    await pgc.connect()
    my = await mysql.createConnection({ uri: myUrl!, timezone: "Z", dateStrings: true })
    await my.query("SET time_zone = '+00:00'")
    for (const t of Object.keys(TABLES)) {
      await pgc.query(`DELETE FROM ${t}`)
      await my.query(`DELETE FROM ${t}`)
    }
    for (const [kind, payload, stream, seq] of script()) {
      const p = projectionStatement(kind, payload, stream, seq)!
      const m = projectionStatementMysql(kind, payload, stream, seq)!
      await pgc.query(p[0], p[1])
      await my.query(m[0], m[1])
    }
  }, 60_000)
  afterAll(async () => {
    await pgc.end()
    await my.end()
  })

  for (const [table, spec] of Object.entries(TABLES)) {
    it(`${table}: same rows`, async () => {
      const [cols] = (await my.query("SELECT column_name AS c FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? ORDER BY ordinal_position", [table])) as unknown as [Array<{ c: string }>]
      const names = cols.map((r) => r.c).filter((c) => !spec.skip.includes(c))
      const order = spec.key.join(", ")
      const list = names.map((n) => `"${n}"`).join(", ")
      const pgRows = (await pgc.query(`SELECT ${list} FROM ${table} ORDER BY ${order}`)).rows
      const [myRows] = (await my.query(`SELECT ${names.map((n) => `\`${n}\``).join(", ")} FROM ${table} ORDER BY ${order}`)) as unknown as [Array<Record<string, unknown>>]
      const shape = (rows: Array<Record<string, unknown>>) => rows.map((r) => Object.fromEntries(names.map((n) => [n, norm(r[n])])))
      expect(pgRows.length).toBeGreaterThan(0)
      expect(shape(myRows)).toEqual(shape(pgRows))
    })
  }
})
