import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { conversation as homeConversation, invites } from "@cmux/home-core"
import { userIdFor } from "../src/domains/user.ts"
import { conversationMutate } from "../src/home-routes.ts"
import { recordingEnv } from "./reach-recorder.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Home rate limits on ops that resolve human reach (home-messaging.md section 9): the caller's
 * UserDO counts conversation.create (60 per hour) and participants.add (120 per hour) per actor,
 * and the Worker asks it BEFORE any reach RPC, so a flood never fans out to TeamDO, other
 * users' UserDOs or ConversationDOs. A refusal is `home.rate_limited`, retryable, with
 * `details.retry_after_ms`.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; HOME_ADDRESS_KEY: string; ADDRESS_DO: DurableObjectNamespace; TEAM_DO: DurableObjectNamespace; USER_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace }
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
/** `owner`'s DM with `peer` from the owner's inbox peer index (the UserDO read the Worker uses). */
const dmPeer = (owner: Person, peer: Person) =>
  inDO(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(owner.user)), async (i) => (await i.readInbox(owner.user, sessionPrincipal(owner), "inbox.dm_peer", { peer: peer.user })).value?.conversation)
/** Waits (bounded) until `dm` is `owner`'s DM with `peer` in the inbox peer index. */
const waitDm = async (owner: Person, peer: Person, dm: string) => {
  for (let n = 0; n < 100 && (await dmPeer(owner, peer)) !== dm; n++) {
    await fireAlarm(testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(dm)))
    await new Promise((r) => setTimeout(r, 20))
  }
  expect(await dmPeer(owner, peer)).toBe(dm)
}
/** `inviter` invites `invitee` (by the invitee's verified email) into a DM, the invitee accepts; the DM id is invite-born, not the pair id. */
const inviteDm = async (inviter: Person, invitee: Person, sub: string) => {
  const email = `${sub}@example.com`
  const opened = await op(inviter.token, "dm.open", { peer: { email } })
  const dm = opened.value.conversation.id as string
  const address = invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizeEmail(email) as invites.Address)
  const secret = await inDO(testEnv.ADDRESS_DO.get(testEnv.ADDRESS_DO.idFromName(address)), async (_i, state) => String(state.storage.sql.exec("SELECT secret FROM address_secrets").toArray()[0]!.secret))
  expect((await op(invitee.token, "invite.accept", { code: invites.linkCode(dm), secret })).ok).toBe(true)
  await waitDm(inviter, invitee, dm)
  return dm
}
/** Attempts counted for `actor` and `op` in `owner`'s UserDO. */
const spent = (owner: Person, actor: string, op: string) =>
  inDO(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(owner.user)), async (_i, state) => {
    state.storage.sql.exec("CREATE TABLE IF NOT EXISTS home_rate (actor TEXT NOT NULL, op TEXT NOT NULL, at INTEGER NOT NULL)")
    return Number((state.storage.sql.exec("SELECT COUNT(*) AS n FROM home_rate WHERE actor = ? AND op = ?", actor, op).toArray()[0] as { n: number }).n)
  })
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
    // Only the caller's own inbox is asked for an existing DM to reopen; no reach RPC to anyone else.
    expect(rec.calls).toEqual(["user.readInbox"])
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

  it("a session user who never called user.ensure gets home.user_not_ready (not retryable), not home.rate_limited", async () => {
    const user = userIdFor(testEnv.STACK_PROJECT_ID, "rate-not-ready-nia")
    const nia = { identity: `${user}:s`, kind: "session" as const, user, display_name: "Nia" }
    const res = await conversationMutate(testEnv as never, nia, { t: "op", op: "conversation.create", params: { title: "first", participants: [{ id: user, kind: "human", display_name: "Nia" }] }, idempotency_key: crypto.randomUUID() })
    expect(rejectOf(res)).toMatchObject({ code: "home.user_not_ready", retryable: false })
  })

  it("with the budget spent, dm.open still reopens an existing DM (no charge, no reach); a new DM is refused", async () => {
    const ola = await signIn("rate-reopen-ola", "Ola")
    const pam = await signIn("rate-reopen-pam", "Pam")
    const quin = await signIn("rate-reopen-quin", "Quin")
    await joinTeam(ola, pam)
    await joinTeam(ola, quin)
    const opened = await op(ola.token, "dm.open", { peer: pam.user })
    const dm = opened.value.conversation.id as string
    // The DM reaches Ola's inbox peer index once the outbox drains.
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(dm))
    const peerOf = () => inDO(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(ola.user)), async (i) => (await i.readInbox(ola.user, sessionPrincipal(ola), "inbox.dm_peer", { peer: pam.user })).value?.conversation)
    for (let n = 0; n < 100 && (await peerOf()) !== dm; n++) {
      await fireAlarm(conv)
      await new Promise((r) => setTimeout(r, 20))
    }
    expect(await peerOf()).toBe(dm)
    await spend(ola, ola.user, "conversation.create", 60)
    const rec = recordingEnv()
    const again = await conversationMutate(rec.env, sessionPrincipal(ola), { t: "op", op: "dm.open", params: { peer: pam.user }, idempotency_key: crypto.randomUUID() })
    expect(again.frames.find((f) => f.t === "result")).toMatchObject({ value: { conversation: { id: dm } } })
    expect(rec.calls.filter((c) => c !== "user.readInbox")).toEqual([])
    const fresh = await conversationMutate(testEnv as never, sessionPrincipal(ola), { t: "op", op: "dm.open", params: { peer: quin.user }, idempotency_key: crypto.randomUUID() })
    expect(rejectOf(fresh)).toMatchObject({ code: "home.rate_limited" })
  })

  it("a same-key dm.open retry after the budget is spent replays its stored result with no reach, after a create and after a reopen", async () => {
    const rex = await signIn("rate-dmreplay-rex", "Rex")
    const sam = await signIn("rate-dmreplay-sam", "Sam")
    await joinTeam(rex, sam)
    const open = (env: never, key: string) => conversationMutate(env, sessionPrincipal(rex), { t: "op", op: "dm.open", params: { peer: sam.user }, idempotency_key: key })
    const created = crypto.randomUUID()
    const first = (await open(testEnv as never, created)).frames.find((f) => f.t === "result") as { value: { conversation: { id: string } } } | undefined
    const dm = first!.value.conversation.id
    // Wait until the DM is in Rex's inbox peer index, so the next dm.open reopens it.
    const peerOf = () => inDO(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(rex.user)), async (i) => (await i.readInbox(rex.user, sessionPrincipal(rex), "inbox.dm_peer", { peer: sam.user })).value?.conversation)
    for (let n = 0; n < 100 && (await peerOf()) !== dm; n++) {
      await fireAlarm(testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(dm)))
      await new Promise((r) => setTimeout(r, 20))
    }
    const reopened = crypto.randomUUID()
    expect((await open(testEnv as never, reopened)).frames.find((f) => f.t === "result")).toMatchObject({ value: { conversation: { id: dm } } })
    await spend(rex, rex.user, "conversation.create", 60)
    for (const key of [created, reopened]) {
      const rec = recordingEnv()
      const again = await open(rec.env, key)
      expect(rejectOf(again)).toBeUndefined()
      expect(again.frames.find((f) => f.t === "result")).toMatchObject({ replayed: true, value: { conversation: { id: dm } } })
      expect(rec.calls).toEqual([])
    }
  })

  it("a chief whose budget is spent gets home.rate_limited for dm.open without a lookup in its owner's inbox", async () => {
    const tia = await signIn("rate-chief-reopen-tia", "Tia")
    const uma = await signIn("rate-chief-reopen-uma", "Uma")
    await joinTeam(tia, uma)
    // The owner has a DM with the peer: a reopen through the owner's inbox would find it.
    const dm = (await op(tia.token, "dm.open", { peer: uma.user })).value.conversation.id as string
    await waitDm(tia, uma, dm)
    const chief = "agent_" + "7".repeat(26)
    await spend(tia, chief, "conversation.create", 60)
    const asChief = { ...sessionPrincipal(tia), identity: `${tia.user}:chief`, agent: chief }
    const rec = recordingEnv()
    const res = await conversationMutate(rec.env, asChief, { t: "op", op: "dm.open", params: { peer: uma.user }, idempotency_key: crypto.randomUUID() })
    expect(rejectOf(res)).toMatchObject({ code: "home.rate_limited" })
    expect(rec.calls).toEqual([])
  })

  it("a same-key dm.open retry with a changed display name, after the budget is spent, returns the stored result", async () => {
    const vic = await signIn("rate-dmname-vic", "Vic")
    const wes = await signIn("rate-dmname-wes", "Wes")
    await joinTeam(vic, wes)
    const key = crypto.randomUUID()
    const open = (name: string) => conversationMutate(testEnv as never, { ...sessionPrincipal(vic), display_name: name }, { t: "op", op: "dm.open", params: { peer: wes.user }, idempotency_key: key })
    expect((await open("Vic")).frames.some((f) => f.t === "result")).toBe(true)
    await spend(vic, vic.user, "conversation.create", 60)
    const again = await open("Victoria")
    expect(rejectOf(again)).toBeUndefined()
    expect(again.frames.find((f) => f.t === "result")).toMatchObject({ replayed: true })
  })

  it("with budget left, a same-key retry of a decided op takes no unit and resolves no reach (create, participants.add, dm.open)", async () => {
    const xia = await signIn("rate-retry-xia", "Xia")
    const yan = await signIn("rate-retry-yan", "Yan")
    const zed = await signIn("rate-retry-zed", "Zed")
    await joinTeam(xia, yan)
    await joinTeam(xia, zed)
    const run = (env: never, op: string, params: unknown, key: string) => conversationMutate(env, sessionPrincipal(xia), { t: "op", op, params, idempotency_key: key })
    const retry = async (op: string, params: unknown, key: string, budget: string) => {
      const before = await spent(xia, xia.user, budget)
      const rec = recordingEnv()
      const again = await run(rec.env, op, params, key)
      expect(rejectOf(again)).toBeUndefined()
      expect(again.frames.find((f) => f.t === "result")).toMatchObject({ replayed: true })
      expect(rec.calls).toEqual([])
      expect(await spent(xia, xia.user, budget)).toBe(before)
    }
    // conversation.create
    const createKey = crypto.randomUUID()
    const createParams = { title: "Plans", participants: [human(xia, "Xia"), human(yan)] }
    const created = (await run(testEnv as never, "conversation.create", createParams, createKey)).frames.find((f) => f.t === "result") as { value: { conversation: { id: string } } }
    await retry("conversation.create", createParams, createKey, "conversation.create")
    // participants.add
    const addKey = crypto.randomUUID()
    const addParams = { conversation: created.value.conversation.id, participant: human(zed) }
    expect((await run(testEnv as never, "participants.add", addParams, addKey)).frames.some((f) => f.t === "result")).toBe(true)
    await retry("participants.add", addParams, addKey, "participants.add")
    // dm.open: the retry comes after the DM reached the inbox, so the normal path would send the reopen shape.
    const dmKey = crypto.randomUUID()
    const dm = ((await run(testEnv as never, "dm.open", { peer: yan.user }, dmKey)).frames.find((f) => f.t === "result") as { value: { conversation: { id: string } } }).value.conversation.id
    const peerOf = () => inDO(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(xia.user)), async (i) => (await i.readInbox(xia.user, sessionPrincipal(xia), "inbox.dm_peer", { peer: yan.user })).value?.conversation)
    for (let n = 0; n < 100 && (await peerOf()) !== dm; n++) {
      await fireAlarm(testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(dm)))
      await new Promise((r) => setTimeout(r, 20))
    }
    expect(await peerOf()).toBe(dm)
    await retry("dm.open", { peer: yan.user }, dmKey, "conversation.create")
  })

  it("with the budget spent, dm.open reopens an invite-born DM (its id is not the pair id) with no charge", async () => {
    const ann = await signIn("rate-invdm-ann", "Ann")
    const bea = await signIn("rate-invdm-bea", "Bea")
    const dm = await inviteDm(ann, bea, "rate-invdm-bea")
    expect(dm).not.toBe(homeConversation.dmConversationId(ann.user, bea.user))
    await spend(ann, ann.user, "conversation.create", 60)
    const before = await spent(ann, ann.user, "conversation.create")
    const res = await conversationMutate(testEnv as never, sessionPrincipal(ann), { t: "op", op: "dm.open", params: { peer: bea.user }, idempotency_key: crypto.randomUUID() })
    expect(rejectOf(res)).toBeUndefined()
    expect(res.frames.find((f) => f.t === "result")).toMatchObject({ value: { conversation: { id: dm } } })
    expect(await spent(ann, ann.user, "conversation.create")).toBe(before)
  })
})
