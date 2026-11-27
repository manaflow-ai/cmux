import { afterAll, beforeAll, describe, expect, it } from "bun:test"
import pg from "pg"
import { homeSearch } from "../../apps/api/src/home-search.ts"

/**
 * home.search SQL on a migrated Postgres (CI: the scratch database after "Migrations apply
 * from zero"; locally: SCRATCH_URL). Membership, since_join, LIKE escaping, paging, limits.
 */
const url = process.env.SCRATCH_URL
const run = url ? describe : describe.skip
const env = { HYPERDRIVE_RO: { connectionString: url } } as never
const as = (user: string) => ({ identity: `session:${user}`, kind: "session", user }) as never
const ids = (r: Awaited<ReturnType<typeof homeSearch>>) => (r.ok ? r.value.hits.map((h) => `${h.conversation}#${h.seq}`) : [`ERR ${r.message}`])

run("home.search on the projection", () => {
  const db = new pg.Client({ connectionString: url })
  beforeAll(async () => {
    await db.connect()
    const now = new Date("2026-10-03T00:00:00Z")
    await db.query(`DELETE FROM home_message_search WHERE conversation_id LIKE 'conv_T%'`)
    await db.query(`DELETE FROM home_participants WHERE conversation_id LIKE 'conv_T%'`)
    await db.query(`DELETE FROM home_conversations WHERE id LIKE 'conv_T%'`)
    await db.query(
      `INSERT INTO home_conversations VALUES ('conv_TA','group',NULL,'Plans','user_ta',$1,3,$1,2,'active','conv:TA',1,now()), ('conv_TB','group',NULL,'Other',NULL,$1,1,$1,1,'active','conv:TB',1,now())`,
      [now]
    )
    await db.query(
      `INSERT INTO home_participants (conversation_id, participant_id, kind, visible_from_seq, joined_at, source_stream, source_seq) VALUES
       ('conv_TA','user_ta','human',0,$1,'conv:TA',1), ('conv_TA','user_tb','human',2,$1,'conv:TA',1), ('conv_TB','user_tc','human',0,$1,'conv:TB',1)`,
      [now]
    )
    const msg = (conv: string, seq: number, body: string, minute: number) =>
      db.query(
        `INSERT INTO home_message_search (conversation_id, seq, message_id, author_id, author_kind, created_at, body, source_stream, source_seq) VALUES ($1,$2,$3,'user_ta','human',$4,$5,'s',1)`,
        [conv, seq, `msg_${conv}_${seq}`, new Date(now.getTime() + minute * 60_000), body]
      )
    await msg("conv_TA", 1, "Launch plan draft", 1)
    await msg("conv_TA", 2, "the PLAN is 100% done_ok", 2)
    await msg("conv_TA", 3, "after join: plan B", 3)
    await msg("conv_TB", 1, "other people's plan", 4)
  })
  afterAll(() => db.end())

  it("returns only conversations the caller is in, newest first, honoring since_join", async () => {
    expect(ids(await homeSearch(env, as("user_ta"), { q: "plan" }))).toEqual(["conv_TA#3", "conv_TA#2", "conv_TA#1"])
    expect(ids(await homeSearch(env, as("user_tb"), { q: "plan" }))).toEqual(["conv_TA#3"])
    expect(ids(await homeSearch(env, as("user_tz"), { q: "plan" }))).toEqual([])
  })

  it("treats % and _ in the query as text", async () => {
    expect(ids(await homeSearch(env, as("user_ta"), { q: "100%" }))).toEqual(["conv_TA#2"])
    expect(ids(await homeSearch(env, as("user_ta"), { q: "_ok" }))).toEqual(["conv_TA#2"])
    expect(ids(await homeSearch(env, as("user_ta"), { q: "1%d" }))).toEqual([])
  })

  it("pages with the cursor, returns snippet ranges and the title, and checks limits", async () => {
    const first = await homeSearch(env, as("user_ta"), { q: "plan", limit: 2 })
    expect(ids(first)).toEqual(["conv_TA#3", "conv_TA#2"])
    const cursor = first.ok ? first.value.cursor : undefined
    expect(cursor).toBeDefined()
    expect(ids(await homeSearch(env, as("user_ta"), { q: "plan", limit: 2, cursor }))).toEqual(["conv_TA#1"])
    if (first.ok) expect(first.value.hits[0]).toMatchObject({ title: "Plans", snippet: "after join: plan B", ranges: [{ start: 12, length: 4 }] })
    expect(ids(await homeSearch(env, as("user_ta"), { q: "plan", limit: 101 }))).toEqual(["ERR invalid_limit"])
    expect(ids(await homeSearch(env, as("user_ta"), { q: "" }))).toEqual(["ERR invalid_query"])
    expect(ids(await homeSearch(env, as("user_ta"), { q: "plan", before: "not a time" }))).toEqual(["ERR invalid before"])
    expect(ids(await homeSearch(env, as("user_ta"), { q: "plan", cursor: Buffer.from(JSON.stringify(["x", "conv_TA", 1.5])).toString("base64url") }))).toEqual(["ERR invalid cursor"])
    // An install whose grant does not cover read finds nothing.
    const install = { identity: "install:x", kind: "install", user: "user_ta", grant_classes: ["mutate-own"] } as never
    expect(ids(await homeSearch(env, install, { q: "plan" }))).toEqual(["ERR grant does not cover read"])
  })
})
