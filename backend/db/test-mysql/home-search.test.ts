import { afterAll, beforeAll, describe, expect, it } from "bun:test"
import mysql from "mysql2/promise"
import { homeSearchMysql } from "../../apps/api/src/home-search-mysql.ts"

/**
 * home.search on the MySQL projection: membership, since_join, LIKE escaping, CJK and accents,
 * paging, limits. Same cases as test-pg/home-search.test.ts plus CJK.
 */
const url = process.env.MYSQL_URL
const run = url ? describe : describe.skip
const binding = () => {
  const u = new URL(url!)
  return { host: u.hostname, port: Number(u.port || 3306), user: decodeURIComponent(u.username), password: decodeURIComponent(u.password), database: u.pathname.slice(1), tls: u.searchParams.has("ssl") }
}
const env = () => ({ PS_MYSQL_RO: binding() }) as never
const as = (user: string) => ({ identity: `session:${user}`, kind: "session", user }) as never
const ids = (r: Awaited<ReturnType<typeof homeSearchMysql>>) => (r.ok ? r.value.hits.map((h) => `${h.conversation}#${h.seq}`) : [`ERR ${r.message}`])

run("home.search on the MySQL projection", () => {
  let db: mysql.Connection
  beforeAll(async () => {
    db = await mysql.createConnection({ uri: url!, timezone: "Z" })
    await db.query("SET time_zone = '+00:00'")
    const now = "2026-10-03 00:00:00.000"
    await db.query(`DELETE FROM home_message_search WHERE conversation_id LIKE 'conv\\_T%'`)
    await db.query(`DELETE FROM home_participants WHERE conversation_id LIKE 'conv\\_T%'`)
    await db.query(`DELETE FROM home_conversations WHERE id LIKE 'conv\\_T%'`)
    await db.query(
      `INSERT INTO home_conversations (id, kind, team_id, title, created_by, created_at, last_seq, last_at, participant_count, state, source_stream, source_seq) VALUES
       ('conv_TA','group',NULL,'Plans','user_ta',?,3,?,2,'active','conv:TA',1), ('conv_TB','group',NULL,'Other',NULL,?,1,?,1,'active','conv:TB',1)`,
      [now, now, now, now]
    )
    await db.query(
      `INSERT INTO home_participants (conversation_id, participant_id, kind, visible_from_seq, joined_at, source_stream, source_seq) VALUES
       ('conv_TA','user_ta','human',0,?,'conv:TA',1), ('conv_TA','user_tb','human',2,?,'conv:TA',1), ('conv_TB','user_tc','human',0,?,'conv:TB',1)`,
      [now, now, now]
    )
    const msg = (conv: string, seq: number, body: string, minute: number) =>
      db.query(
        `INSERT INTO home_message_search (conversation_id, seq, message_id, author_id, author_kind, created_at, body, source_stream, source_seq) VALUES (?,?,?,'user_ta','human',?,?,'s',1)`,
        [conv, seq, `msg_${conv}_${seq}`, new Date(Date.parse("2026-10-03T00:00:00Z") + minute * 60_000), body]
      )
    await msg("conv_TA", 1, "Launch plan draft", 1)
    await msg("conv_TA", 2, "the PLAN is 100% done_ok", 2)
    await msg("conv_TA", 3, "after join: plan B", 3)
    await msg("conv_TB", 1, "other people's plan", 4)
    await msg("conv_TA", 4, "明日の計画を確認します", 5)
  })
  afterAll(() => db.end())

  it("returns only conversations the caller is in, newest first, honoring since_join", async () => {
    expect(ids(await homeSearchMysql(env(), as("user_ta"), { q: "plan" }))).toEqual(["conv_TA#3", "conv_TA#2", "conv_TA#1"])
    expect(ids(await homeSearchMysql(env(), as("user_tb"), { q: "plan" }))).toEqual(["conv_TA#3"])
    expect(ids(await homeSearchMysql(env(), as("user_tz"), { q: "plan" }))).toEqual([])
  })

  it("treats % and _ in the query as text", async () => {
    expect(ids(await homeSearchMysql(env(), as("user_ta"), { q: "100%" }))).toEqual(["conv_TA#2"])
    expect(ids(await homeSearchMysql(env(), as("user_ta"), { q: "_ok" }))).toEqual(["conv_TA#2"])
    expect(ids(await homeSearchMysql(env(), as("user_ta"), { q: "1%d" }))).toEqual([])
  })

  it("finds a CJK substring", async () => {
    expect(ids(await homeSearchMysql(env(), as("user_ta"), { q: "計画" }))).toEqual(["conv_TA#4"])
  })

  it("pages with the cursor, returns snippet ranges and the title, and checks limits", async () => {
    const first = await homeSearchMysql(env(), as("user_ta"), { q: "plan", limit: 2 })
    expect(ids(first)).toEqual(["conv_TA#3", "conv_TA#2"])
    const cursor = first.ok ? first.value.cursor : undefined
    expect(cursor).toBeDefined()
    expect(ids(await homeSearchMysql(env(), as("user_ta"), { q: "plan", limit: 2, cursor }))).toEqual(["conv_TA#1"])
    if (first.ok) expect(first.value.hits[0]).toMatchObject({ title: "Plans", snippet: "after join: plan B", ranges: [{ start: 12, length: 4 }], created_at: "2026-10-03T00:03:00.000Z" })
    expect(ids(await homeSearchMysql(env(), as("user_ta"), { q: "plan", limit: 101 }))).toEqual(["ERR invalid_limit"])
    expect(ids(await homeSearchMysql(env(), as("user_ta"), { q: "" }))).toEqual(["ERR invalid_query"])
    expect(ids(await homeSearchMysql(env(), as("user_ta"), { q: "plan", before: "not a time" }))).toEqual(["ERR invalid before"])
    const install = { identity: "install:x", kind: "install", user: "user_ta", grant_classes: ["mutate-own"] } as never
    expect(ids(await homeSearchMysql(env(), install, { q: "plan" }))).toEqual(["ERR grant does not cover read"])
  })
})

describe.skipIf(!url)("feed sweep user paging on MySQL", () => {
  it("pages user ids in byte order after a cursor", async () => {
    const { listUsersMysql } = await import("../../apps/api/src/feed-sweep.ts")
    const db = await mysql.createConnection({ uri: url!, timezone: "Z" })
    await db.query("DELETE FROM users WHERE id LIKE 'user\\_fs%'")
    for (const id of ["user_fsB", "user_fsA", "user_fsa", "user_fsC"]) await db.query("INSERT INTO users (id, stack_user_id, display_name, personal_team, source_stream, source_seq) VALUES (?, ?, 'x', 't', 's', 1)", [id, `st_${id}`])
    await db.end()
    const env = { PS_MYSQL_RO: binding() } as never
    const all = (await listUsersMysql(env, null, 1000)).filter((id) => id.startsWith("user_fs"))
    expect(all).toEqual(["user_fsA", "user_fsB", "user_fsC", "user_fsa"])
    expect((await listUsersMysql(env, "user_fsB", 2)).filter((id) => id.startsWith("user_fs"))).toEqual(["user_fsC", "user_fsa"])
  })
})
