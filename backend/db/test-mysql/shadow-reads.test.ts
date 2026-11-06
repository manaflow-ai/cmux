import { afterAll, beforeAll, describe, expect, it, spyOn } from "bun:test"
import mysql from "mysql2/promise"
import pg from "pg"
import { sweepDeps } from "../../apps/api/src/feed-sweep.ts"
import { homeSearch } from "../../apps/api/src/home-search.ts"
import { projectionStatement } from "../../apps/api/src/projection.ts"
import { projectionStatementMysql } from "../../apps/api/src/projection-mysql.ts"
import { PROJECTION_TABLES } from "../projection-compare.ts"
import { cases } from "./projection-cases.ts"

/**
 * PROJECTION_READS=shadow end to end (vitess-migration-DESIGN.md): the same projection in Postgres
 * and MySQL gives a match event per read for home.search and the feed sweep's user pages; a row
 * missing in MySQL gives a diff event, and the caller always gets the Postgres answer.
 */
const pgUrl = process.env.SCRATCH_URL
const myUrl = process.env.MYSQL_URL
const run = pgUrl && myUrl ? describe : describe.skip
const binding = () => {
  const u = new URL(myUrl!)
  return { host: u.hostname, port: Number(u.port || 3306), user: decodeURIComponent(u.username), password: decodeURIComponent(u.password), database: u.pathname.slice(1), tls: false }
}
const as = (user: string) => ({ identity: `session:${user}`, kind: "session", user }) as never

run("projection shadow reads (Postgres and MySQL)", () => {
  const pgc = new pg.Client({ connectionString: pgUrl })
  let my: mysql.Connection
  const env = () => ({ PROJECTION_READS: "shadow", HYPERDRIVE: { connectionString: pgUrl }, HYPERDRIVE_RO: { connectionString: pgUrl }, PS_MYSQL_RO: binding() }) as never
  const events = async (work: () => Promise<unknown>) => {
    const out: Array<Record<string, unknown>> = []
    const log = spyOn(console, "log").mockImplementation((m) => void out.push(JSON.parse(String(m))))
    const err = spyOn(console, "error").mockImplementation((m) => void out.push(JSON.parse(String(m))))
    try {
      return { value: await work(), events: out.filter((e) => String(e.event).startsWith("projection.read.")) }
    } finally {
      log.mockRestore()
      err.mockRestore()
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
    for (const c of cases) {
      const p = projectionStatement(c.kind, c.payload(0), "s:1", 1)!
      const m = projectionStatementMysql(c.kind, c.payload(0), "s:1", 1)!
      await pgc.query(p[0], p[1])
      await my.query(m[0], m[1])
    }
  }, 60_000)
  afterAll(async () => {
    await pgc.end()
    await my.end()
  })

  it("equal projections: home.search and the user page log a match and answer from Postgres", async () => {
    const s = await events(() => homeSearch(env(), as("user_p1"), { q: "body" }))
    expect(s.value).toMatchObject({ ok: true, value: { hits: [expect.objectContaining({ conversation: "conv_P1", seq: 1 })] } })
    expect(s.events).toEqual([{ event: "projection.read.match", read: "home.search", rows: 2 }])
    const u = await events(() => sweepDeps(env()).listUsers(null, 100))
    expect(u.value).toEqual(["user_p1"])
    expect(u.events).toEqual([{ event: "projection.read.match", read: "feed.users", rows: 1 }])
  }, 60_000)

  it("a message missing in MySQL is a diff event; the caller still gets the Postgres hit", async () => {
    await my.query("DELETE FROM home_message_search WHERE conversation_id = 'conv_P1'")
    const s = await events(() => homeSearch(env(), as("user_p1"), { q: "body" }))
    expect(s.value).toMatchObject({ ok: true, value: { hits: [expect.objectContaining({ seq: 1 })] } })
    expect(s.events).toEqual([expect.objectContaining({ event: "projection.read.diff", read: "home.search", only_primary: ["conv_P1/1"], only_shadow: [] })])
    expect(JSON.stringify(s.events)).not.toContain("body 0")
  }, 60_000)
})
