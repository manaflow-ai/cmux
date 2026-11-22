import { env, exports } from "cloudflare:workers"
import { runInDurableObject as runIn } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"

/** (f) steps 2-3: TeamDO members and hosts live in rows, not in the 2 MB head; old heads migrate on wake. */
const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; TEAM_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const token = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const post = async (path: string, t: string, body: unknown) =>
  (await (await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) })).json()) as any
const head = (stub: unknown) => runInDurableObject(stub, async (_i, state) => String(state.storage.sql.exec("SELECT json FROM own_state WHERE id = 1").one().json))

describe("TeamDO members in rows", { timeout: 120_000 }, () => {
  it("a new team keeps its member as a row, not in the head", async () => {
    const t = await token("team-rows-1")
    const team = (await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: "e", origin: "user" })).value.personal_team as string
    const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))
    const json = JSON.parse(await head(stub))
    expect(json.members).toBeUndefined()
    expect(json.member_count).toBe(1)
    const rows = await runInDurableObject(stub, async (_i, state) => Number(state.storage.sql.exec("SELECT COUNT(*) AS n FROM own_rows WHERE tbl = 'member'").one().n))
    expect(rows).toBe(1)
    // The member still reads team ops.
    expect((await post("/v1/read", t, { op: "team.policy.get", params: {} })).value?.policy).toBeDefined()
  })

  it("an old head with 12,000 members migrates to rows on wake and stays under 100 KB", async () => {
    const t = await token("team-rows-2")
    const team = (await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: "e", origin: "user" })).value.personal_team as string
    const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))
    const owner = Object.keys((await post("/v1/read", t, { op: "team.directory", params: {} })).value.members.reduce((m: Record<string, true>, x: { user: string }) => ({ ...m, [x.user]: true }), {}))[0]!
    // Write an old-style head: members and hosts as maps (what deployed objects hold today).
    await runInDurableObject(stub, async (_i, state) => {
      const sql = state.storage.sql
      const cur = JSON.parse(String(sql.exec("SELECT json FROM own_state WHERE id = 1").one().json))
      const members: Record<string, unknown> = { [owner]: { user: owner, role: "owner", display_name: "Owner" } }
      for (let i = 0; i < 12_000; i++) members[`user_${String(i).padStart(20, "0")}`] = { user: `user_${String(i).padStart(20, "0")}`, role: "member", display_name: `Member ${i}` }
      const legacy = { ...cur, members, hosts: {} }
      delete legacy.member_count
      sql.exec("UPDATE own_state SET json = ? WHERE id = 1", JSON.stringify(legacy))
      sql.exec("DELETE FROM own_rows WHERE tbl = 'member'")
    })
    // As after a deploy: the engine reopens from storage, and the next bind migrates.
    await runInDurableObject(stub, async (instance) => {
      instance.engine = undefined
    })
    expect((await post("/v1/read", t, { op: "team.policy.get", params: {} })).value?.policy).toBeDefined()
    const json = await head(stub)
    expect(json.length).toBeLessThan(100_000)
    expect(JSON.parse(json).member_count).toBe(12_001)
    const n = await runInDurableObject(stub, async (_i, state) => Number(state.storage.sql.exec("SELECT COUNT(*) AS n FROM own_rows WHERE tbl = 'member'").one().n))
    expect(n).toBe(12_001)
  })
})

describe("team member and host paging", { timeout: 120_000 }, () => {
  it("pages members by user id with a stable cursor, filters by role, and counts", async () => {
    const t = await token("team-rows-3")
    const team = (await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: "e", origin: "user" })).value.personal_team as string
    const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))
    await runInDurableObject(stub, async (_i, state) => {
      for (let i = 0; i < 450; i++) state.storage.sql.exec("INSERT INTO own_rows (tbl, k, n, json) VALUES ('member', ?, NULL, ?)", `user_${String(i).padStart(20, "0")}`, JSON.stringify({ user: `user_${String(i).padStart(20, "0")}`, role: i % 100 === 0 ? "admin" : "member", display_name: `M${i}` }))
    })
    const seen: Array<string> = []
    let cursor: string | undefined
    for (let page = 0; page < 10; page++) {
      const r = (await post("/v1/read", t, { op: "team.members.list", params: { limit: 200, ...(cursor ? { cursor } : {}) } })).value
      seen.push(...r.members.map((m: { user: string }) => m.user))
      cursor = r.next_cursor ?? undefined
      if (!cursor) break
    }
    expect(seen).toHaveLength(451)
    expect(new Set(seen).size).toBe(451)
    expect([...seen].sort()).toEqual(seen)
    const admins = (await post("/v1/read", t, { op: "team.members.list", params: { role: "admin" } })).value.members
    expect(admins.map((m: { role: string }) => m.role)).toEqual(["admin", "admin", "admin", "admin", "admin"])
    const hosts = (await post("/v1/read", t, { op: "team.hosts.list", params: {} })).value
    expect(hosts).toMatchObject({ hosts: [], next_cursor: null })
  })
})

describe("UserDO membership index", { timeout: 60_000 }, () => {
  it("lists every team the user belongs to, fed by TeamDO membership writes", async () => {
    const t = await token("team-index-1")
    const ensured = (await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: "e", origin: "user" })).value
    const team = ensured.personal_team as string
    const user = ensured.id as string
    const teamStub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))
    const userStub = (env as unknown as { USER_DO: DurableObjectNamespace }).USER_DO.get((env as unknown as { USER_DO: DurableObjectNamespace }).USER_DO.idFromName(user)) as unknown as { homeTeamsOf(entity: string): Promise<Array<{ team: string; role: string; kind: string }>> }
    // The TeamDO outbox delivers the index item from its alarm (it may already be running).
    let teams: Array<unknown> = []
    for (let i = 0; i < 50 && teams.length === 0; i++) {
      await fireAlarm(teamStub)
      teams = await userStub.homeTeamsOf(user)
      if (teams.length === 0) await new Promise((r) => setTimeout(r, 20))
    }
    expect(teams).toEqual([{ team, role: "owner", kind: "personal" }])
  })
})

describe("row-mode team events carry no admin state", { timeout: 60_000 }, () => {
  it("a plain member's event frame has no policy history, tokens, SSO, domains or audit head", async () => {
    const t = await token("team-rows-4")
    const ensured = (await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: "e", origin: "user" })).value
    const team = ensured.personal_team as string
    const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)) as any
    const member = "user_00000000000000000077"
    await runInDurableObject(stub, async (_i, state) => {
      state.storage.sql.exec("INSERT INTO own_rows (tbl, k, n, json) VALUES ('member', ?, NULL, ?)", member, JSON.stringify({ user: member, role: "member", display_name: "M" }))
    })
    const res = await stub.fetch("https://do/", { headers: { Upgrade: "websocket", "x-cmux-entity": team, "x-cmux-principal": JSON.stringify({ identity: `session:${member}`, kind: "session", user: member, team }) } })
    const ws = res.webSocket as WebSocket
    const frames: Array<any> = []
    ws.addEventListener("message", (e) => frames.push(JSON.parse(e.data as string)))
    ws.accept()
    ws.send(JSON.stringify({ t: "subscribe", pending: [] }))
    for (let i = 0; i < 50 && !frames.some((f) => f.t === "snapshot"); i++) await new Promise((r) => setTimeout(r, 10))
    const version = (await post("/v1/read", t, { op: "team.policy.get", params: {} })).value.policy.version
    expect((await post("/v1/ops", t, { op: "team.policy.update", params: { changes: [{ key: "updates.minimumVersion", value: { value: "0.0.9", mode: "enforced" } }], expected_version: version, reason: "t" }, idempotency_key: "p", origin: "user" })).ok).toBe(true)
    for (let i = 0; i < 50 && !frames.some((f) => f.t === "event"); i++) await new Promise((r) => setTimeout(r, 10))
    const event = frames.find((f) => f.t === "event")
    expect(event).toBeDefined()
    const st = event.effects?.state ?? {}
    for (const k of ["policy_history", "enrollment_tokens", "sso_connections", "domains", "audit_head", "audit_count"]) expect(st[k], k).toBeUndefined()
  })
})
