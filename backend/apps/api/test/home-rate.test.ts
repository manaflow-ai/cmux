import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"
import { conversationMutate } from "../src/home-routes.ts"
import { recordingEnv } from "./reach-recorder.ts"

/**
 * Home rate limits on ops that resolve human reach (home-messaging.md section 9): the caller's
 * UserDO counts conversation.create (60 per hour) and participants.add (120 per hour) per actor,
 * and the Worker asks it BEFORE any reach RPC, so a flood never fans out to TeamDO, other
 * users' UserDOs or ConversationDOs. A refusal is `home.rate_limited`, retryable, with
 * `details.retry_after_ms`.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; TEAM_DO: DurableObjectNamespace; USER_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const sessionToken = async (sub: string, name: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const op = async (token: string, name: string, params: unknown) => {
  const res = await worker.fetch("https://api.test/v1/ops", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ op: name, params, idempotency_key: crypto.randomUUID(), origin: "user" })
  })
  return (await res.json().catch(() => null)) as any
}
interface Person {
  readonly token: string
  readonly user: string
  readonly team: string
  readonly name: string
}
const signIn = async (sub: string, name: string): Promise<Person> => {
  const token = await sessionToken(sub, name)
  const ensured = await op(token, "user.ensure", {})
  expect(ensured.ok).toBe(true)
  return { token, user: userIdFor(testEnv.STACK_PROJECT_ID, sub), team: ensured.value.personal_team as string, name }
}
const joinTeam = async (owner: Person, member: Person) => {
  await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(owner.team)), async (instance) => {
    const engine = instance.boundEngine
    engine.state = { ...engine.currentState, members: { ...engine.currentState.members, [member.user]: { user: member.user, role: "member", display_name: member.name } } }
  })
}
const human = (p: Person, name = "anything") => ({ id: p.user, kind: "human", display_name: name })
/** Fills `actor`'s hourly budget for `op` in `owner`'s UserDO with `n` attempts made now (no reach RPCs). */
const spend = (owner: Person, actor: string, op: string, n: number) =>
  inDO(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(owner.user)), async (_i, state) => {
    state.storage.sql.exec("CREATE TABLE IF NOT EXISTS home_rate (actor TEXT NOT NULL, op TEXT NOT NULL, at INTEGER NOT NULL)")
    for (let i = 0; i < n; i++) state.storage.sql.exec("INSERT INTO home_rate (actor, op, at) VALUES (?, ?, ?)", actor, op, Date.now())
  })

const sessionPrincipal = (p: Person) => ({ identity: `${p.user}:s`, kind: "session" as const, user: p.user, team: p.team, display_name: p.name })
const rejectOf = (res: { frames: ReadonlyArray<{ t: string }> }) => res.frames.find((f) => f.t === "reject") as { code: string; retryable: boolean; details?: { retry_after_ms?: number } } | undefined

describe("Home rate limits before reach", { timeout: 120_000 }, () => {
  it("the 61st conversation.create in an hour is refused, and no reach RPC runs for it", async () => {
    const amy = await signIn("rate-create-amy", "Amy")
    const ben = await signIn("rate-create-ben", "Ben")
    await joinTeam(amy, ben)
    for (let i = 0; i < 59; i++) {
      const created = await op(amy.token, "conversation.create", { title: `c${i}`, participants: [human(amy, "Amy")] })
      expect(created.error).toBeUndefined()
    }
    // The 60th is allowed, and the recorder sees its reach RPCs (so an empty list below means none ran).
    const allowed = recordingEnv()
    const sixtieth = await conversationMutate(allowed.env, sessionPrincipal(amy), { t: "op", op: "conversation.create", params: { title: "c59", participants: [human(amy, "Amy"), human(ben)] }, idempotency_key: crypto.randomUUID() })
    expect(rejectOf(sixtieth)).toBeUndefined()
    expect(allowed.calls).toContain("team.homeCoMembers")
    const rec = recordingEnv()
    const refused = await conversationMutate(rec.env, sessionPrincipal(amy), {
      t: "op",
      op: "conversation.create",
      params: { title: "one too many", participants: [human(amy, "Amy"), human(ben)] },
      idempotency_key: crypto.randomUUID()
    })
    expect(rejectOf(refused)).toMatchObject({ code: "home.rate_limited", retryable: true })
    expect(rejectOf(refused)?.details?.retry_after_ms).toBeGreaterThan(0)
    expect(rejectOf(refused)?.details?.retry_after_ms).toBeLessThanOrEqual(3_600_000)
    expect(rec.calls).toEqual([])
    // Through the public API the refusal is the same, with the retry hint.
    const api = await op(amy.token, "conversation.create", { title: "again", participants: [human(amy, "Amy")] })
    expect(api.error).toMatchObject({ code: "home.rate_limited", retryable: true })
    // Another user has their own budget.
    expect((await op(ben.token, "conversation.create", { title: "mine", participants: [human(ben, "Ben")] })).error).toBeUndefined()
  })

  it("the 121st participants.add in an hour is refused before the member check and reach", async () => {
    const cat = await signIn("rate-add-cat", "Cat")
    const dan = await signIn("rate-add-dan", "Dan")
    const conversation = (await op(cat.token, "conversation.create", { title: "Plans", participants: [human(cat, "Cat")] })).value.conversation.id as string
    // Attempts count whether or not they succeed (a stranger is refused not_reachable).
    for (let i = 0; i < 120; i++) expect((await op(cat.token, "participants.add", { conversation, participant: human(dan) })).error?.code).toBe("not_reachable")
    const rec = recordingEnv()
    const refused = await conversationMutate(rec.env, sessionPrincipal(cat), { t: "op", op: "participants.add", params: { conversation, participant: human(dan) }, idempotency_key: crypto.randomUUID() })
    expect(rejectOf(refused)).toMatchObject({ code: "home.rate_limited", retryable: true })
    expect(rec.calls).toEqual([])
  })

  it("homeRateTake creates no storage in a UserDO that never served the user, and refuses", async () => {
    const id = userIdFor(testEnv.STACK_PROJECT_ID, "rate-unbound-nobody")
    const stub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(id)) as unknown as { homeRateTake(e: string, a: string, op: string): Promise<{ ok: boolean }> }
    expect(await stub.homeRateTake(id, id, "conversation.create")).toMatchObject({ ok: false })
    const tables = await inDO(stub, async (_i, state) => state.storage.sql.exec("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('home_rate', 'do_entity')").toArray().map((r: any) => r.name))
    expect(tables).not.toContain("home_rate")
  })

  it("dm.open with a user peer counts against the conversation.create budget, before any reach RPC", async () => {
    const eve = await signIn("rate-dm-eve", "Eve")
    const fay = await signIn("rate-dm-fay", "Fay")
    await joinTeam(eve, fay)
    await spend(eve, eve.user, "conversation.create", 60)
    const rec = recordingEnv()
    const refused = await conversationMutate(rec.env, sessionPrincipal(eve), { t: "op", op: "dm.open", params: { peer: fay.user }, idempotency_key: crypto.randomUUID() })
    expect(rejectOf(refused)).toMatchObject({ code: "home.rate_limited", retryable: true })
    expect(rec.calls).toEqual([])
  })

  it("all of an owner's chiefs share one total budget: archived and new chiefs get no fresh budget past 3x the per-actor limit", async () => {
    const gus = await signIn("rate-chiefs-gus", "Gus")
    const stub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(gus.user)) as unknown as { homeRateTake(e: string, a: string, op: string): Promise<{ ok: boolean }> }
    const chief = (n: number) => `agent_${String(n).padStart(26, "0")}`
    // Three chiefs spend their whole conversation.create budget through the RPC (each attempt also counts toward the total).
    for (const n of [1, 2, 3]) for (let i = 0; i < 60; i++) expect((await stub.homeRateTake(gus.user, chief(n), "conversation.create")).ok).toBe(true)
    // A fourth chief (say, created after archiving one) has a fresh per-chief budget but the owner's chief total is spent.
    expect(await stub.homeRateTake(gus.user, chief(4), "conversation.create")).toMatchObject({ ok: false })
    // The owner's own budget is separate from the chiefs' total.
    expect((await stub.homeRateTake(gus.user, gus.user, "conversation.create")).ok).toBe(true)
  })

  it("a retry of an already-decided key after the budget is spent gets its stored result, not home.rate_limited", async () => {
    const hal = await signIn("rate-replay-hal", "Hal")
    const key = crypto.randomUUID()
    const create = () => conversationMutate(testEnv as never, sessionPrincipal(hal), { t: "op", op: "conversation.create", params: { title: "once", participants: [human(hal, "Hal")] }, idempotency_key: key })
    const first = (await create()).frames.find((f) => f.t === "result") as { value: { conversation: { id: string } } } | undefined
    expect(first).toBeDefined()
    await spend(hal, hal.user, "conversation.create", 60)
    const again = await create()
    expect(rejectOf(again)).toBeUndefined()
    expect(again.frames.find((f) => f.t === "result")).toMatchObject({ replayed: true, value: { conversation: { id: first!.value.conversation.id } } })
    // A new key is still refused.
    const fresh = await conversationMutate(testEnv as never, sessionPrincipal(hal), { t: "op", op: "conversation.create", params: { title: "new", participants: [human(hal, "Hal")] }, idempotency_key: crypto.randomUUID() })
    expect(rejectOf(fresh)).toMatchObject({ code: "home.rate_limited" })
  })

  it("after the budget is spent, a same-key retry with new participants resolves no reach and gets idempotency.conflict; an exact retry replays", async () => {
    const ivy = await signIn("rate-replay-ivy", "Ivy")
    const jon = await signIn("rate-replay-jon", "Jon")
    await joinTeam(ivy, jon)
    const key = crypto.randomUUID()
    const create = (env: never, participants: Array<unknown>) => conversationMutate(env, sessionPrincipal(ivy), { t: "op", op: "conversation.create", params: { title: "once", participants }, idempotency_key: key })
    expect((await create(testEnv as never, [human(ivy, "Ivy")])).frames.some((f) => f.t === "result")).toBe(true)
    await spend(ivy, ivy.user, "conversation.create", 60)
    const changed = recordingEnv()
    expect(rejectOf(await create(changed.env, [human(ivy, "Ivy"), human(jon)]))).toMatchObject({ code: "idempotency.conflict" })
    expect(changed.calls).toEqual([])
    const exact = recordingEnv()
    expect((await create(exact.env, [human(ivy, "Ivy")])).frames.find((f) => f.t === "result")).toMatchObject({ replayed: true })
    expect(exact.calls).toEqual([])
  })

  it("after the budget is spent, a same-key participants.add retry with another participant resolves no reach and gets idempotency.conflict", async () => {
    const kay = await signIn("rate-replay-kay", "Kay")
    const lou = await signIn("rate-replay-lou", "Lou")
    const max = await signIn("rate-replay-max", "Max")
    await joinTeam(kay, lou)
    await joinTeam(kay, max)
    const conversation = (await op(kay.token, "conversation.create", { title: "Plans", participants: [human(kay, "Kay")] })).value.conversation.id as string
    const key = crypto.randomUUID()
    const add = (env: never, who: Person) => conversationMutate(env, sessionPrincipal(kay), { t: "op", op: "participants.add", params: { conversation, participant: human(who) }, idempotency_key: key })
    expect((await add(testEnv as never, lou)).frames.some((f) => f.t === "result")).toBe(true)
    await spend(kay, kay.user, "participants.add", 120)
    const changed = recordingEnv()
    expect(rejectOf(await add(changed.env, max))).toMatchObject({ code: "idempotency.conflict" })
    expect(changed.calls).toEqual([])
  })
})
