import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { conversation as homeConversation, invites } from "@cmux/home-core"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { memberUpsert } from "../src/domains/team-members.ts"
import { userIdFor } from "../src/domains/user.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Reaching a person by email (plans/cmux-next/home-messaging-invites/DESIGN.md):
 * - a signed-in user's verified email is linked to its address, so `dm.open` by the email of a
 *   person the caller can reach opens the real user DM (the person sees it at once);
 * - a person the caller cannot reach gets the same answer as an unknown address (an invite), and
 *   the invite shows in that person's Home as a message request (`home.requests.list`), which
 *   they can accept without the email link (`invite.accept_verified`) or dismiss and block;
 * - nobody else can see or accept it.
 */
const testEnv = env as unknown as {
  STACK_PROJECT_ID: string
  STACK_TEST_PRIVATE_JWK: string
  HOME_ADDRESS_KEY: string
  ADDRESS_DO: DurableObjectNamespace
  TEAM_DO: DurableObjectNamespace
  CONVERSATION_DO: DurableObjectNamespace
}
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const sessionToken = async (sub: string, email: string, name: string) =>
  new SignJWT({ email, email_verified: true, name })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const call = async (path: string, token: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify(body) })
  return (await res.json().catch(() => null)) as any
}
const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })
const read = (token: string, name: string, params: unknown) => call("/v1/read", token, { op: name, params })
interface Person {
  readonly token: string
  readonly user: string
  readonly team: string
  readonly name: string
  readonly email: string
}
const signIn = async (sub: string, email: string, name: string): Promise<Person> => {
  const token = await sessionToken(sub, email, name)
  const ensured = await op(token, "user.ensure", {})
  expect(ensured.ok).toBe(true)
  return { token, user: userIdFor(testEnv.STACK_PROJECT_ID, sub), team: ensured.value.personal_team as string, name, email }
}
const joinTeam = async (owner: Person, member: Person) => {
  await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(owner.team)), async (instance) => {
    instance.boundEngine.rows.apply([memberUpsert({ user: member.user, role: "member", display_name: member.name })])
  })
}
const send = (p: Person, conversation: string, text: string) => {
  const key = crypto.randomUUID()
  return op(p.token, "message.send", { conversation, client_msg_id: key, parts: [{ type: "text", text }] }, key)
}
const addressOf = (email: string) => invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizeEmail(email) as invites.Address)
/** A /v1/read answer has `value` or `error`, never `ok`. Drains the conversation's outbox (the invite delivery reaches the AddressDO) until `who` lists `count` requests. */
const waitRequests = async (who: Person, conversations: ReadonlyArray<string>, count: number) => {
  for (let attempt = 0; attempt < 100; attempt++) {
    const listed = await read(who.token, "home.requests.list", {})
    if (listed.error === undefined && listed.value?.requests?.length === count) return listed.value.requests as Array<any>
    for (const id of conversations) await fireAlarm(testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id)))
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
  throw new Error(`never saw ${count} requests`)
}

describe("Home: reaching people by email", { timeout: 60_000 }, () => {
  it("dm.open by a teammate's email opens the real DM with them, not an invite", async () => {
    const alice = await signIn("req-team-alice", "alice@acme.test", "Alice")
    const bob = await signIn("req-team-bob", "bob@acme.test", "Bob")
    await joinTeam(alice, bob)
    const opened = await op(alice.token, "dm.open", { peer: { email: "Bob@ACME.test" } })
    expect(opened.error).toBeUndefined()
    const id = homeConversation.dmConversationId(alice.user, bob.user)
    expect(opened.value.conversation.id).toBe(id)
    expect(opened.value.invite).toBeUndefined()
    // Bob is a participant at once: he can read it.
    const snap = await read(bob.token, "conversation.snapshot", { conversation: id, tail: 0 })
    expect(snap.error).toBeUndefined()
    expect(snap.value.state.participants.map((p: { id: string }) => p.id).sort()).toEqual([alice.user, bob.user].sort())
  })

  it("dm.open by your own email is refused, and opens no conversation", async () => {
    const solo = await signIn("req-self", "solo@self.test", "Solo")
    const opened = await op(solo.token, "dm.open", { peer: { email: "solo@self.test" } })
    expect(opened.ok).toBe(false)
    expect(opened.error.code).toBe("invalid_participant")
  })

  it("a stranger's DM by email is a message request: listed for the address owner only, accepted without the link", async () => {
    const carol = await signIn("req-carol", "carol@carol.test", "Carol Jones")
    const dave = await signIn("req-dave", "dave@dave.test", "Dave")
    const eve = await signIn("req-eve", "eve@eve.test", "Eve")
    const opened = await op(carol.token, "dm.open", { peer: { email: "dave@dave.test" } })
    // The same answer an unknown address gets: Carol cannot tell that Dave has an account.
    expect(opened.value.invite).toEqual({ ok: true })
    const id = homeConversation.dmConversationId(carol.user, addressOf("dave@dave.test"))
    expect(opened.value.conversation.id).toBe(id)
    expect((await send(carol, id, "hi Dave, it's Carol")).error).toBeUndefined()

    const [request] = await waitRequests(dave, [id], 1)
    expect(request).toMatchObject({ conversation: id, inviter: "Carol Jones", kind: "dm", trusted: false })
    expect(request.preview).toBe("hi Dave, it's Carol")
    expect(JSON.stringify(request)).not.toContain("addr_")

    // Nobody else sees or accepts it.
    expect((await read(eve.token, "home.requests.list", {})).value.requests).toEqual([])
    const stolen = await op(eve.token, "invite.accept_verified", { conversation: id })
    expect(stolen.ok).toBe(false)
    expect(stolen.error.code).toBe("unknown_invite")

    const accepted = await op(dave.token, "invite.accept_verified", { conversation: id })
    expect(accepted.error).toBeUndefined()
    const snap = await read(dave.token, "conversation.snapshot", { conversation: id, tail: 5 })
    expect(snap.error).toBeUndefined()
    const people = snap.value.state.participants.filter((p: { left_at?: string }) => p.left_at === undefined)
    expect(people.map((p: { id: string }) => p.id).sort()).toEqual([carol.user, dave.user].sort())
    expect((await read(dave.token, "home.requests.list", {})).value.requests).toEqual([])
  })

  it("dismiss hides a request silently; block also hides later invites from that sender, not from others", async () => {
    const frank = await signIn("req-frank", "frank@frank.test", "Frank")
    const hal = await signIn("req-hal", "hal@hal.test", "Hal")
    const gina = await signIn("req-gina", "gina@gina.test", "Gina")
    const fromFrank = (await op(frank.token, "dm.open", { peer: { email: "gina@gina.test" } })).value.conversation.id as string
    const [request] = await waitRequests(gina, [fromFrank], 1)
    const dismissed = await op(gina.token, "request.dismiss", { conversation: request.conversation, block: true })
    expect(dismissed.error).toBeUndefined()
    expect((await read(gina.token, "home.requests.list", {})).value.requests).toEqual([])
    // The sender still sees an open invite (decline and block are silent).
    const frankView = await read(frank.token, "conversation.snapshot", { conversation: fromFrank, tail: 0 })
    expect(frankView.value.state.invites.some((i: { status: string }) => i.status === "pending")).toBe(true)

    // A new invite from Frank (a group) stays hidden; Hal's shows.
    const group = (await op(frank.token, "conversation.create", { title: "Lunch", participants: [{ id: frank.user, kind: "human", display_name: "Frank" }] })).value.conversation.id as string
    expect((await op(frank.token, "invite.create", { conversation: group, address: { email: "gina@gina.test" }, display_name: "Gina" })).error).toBeUndefined()
    const fromHal = (await op(hal.token, "dm.open", { peer: { email: "gina@gina.test" } })).value.conversation.id as string
    const listed = await waitRequests(gina, [group, fromHal], 1)
    expect(listed.map((r) => r.conversation)).toEqual([fromHal])
  })

  it("same company domain: the DM opens at once by default; with trust_same_domain off it is a trusted request; a public domain never is trusted", async () => {
    const ivy = await signIn("req-ivy", "ivy@initech.test", "Ivy")
    const jon = await signIn("req-jon", "jon@initech.test", "Jon")
    const opened = await op(ivy.token, "dm.open", { peer: { email: jon.email } })
    expect(opened.error).toBeUndefined()
    expect(opened.value.invite).toBeUndefined()
    const direct = homeConversation.dmConversationId(ivy.user, jon.user)
    expect(opened.value.conversation.id).toBe(direct)
    const seen = await read(jon.token, "conversation.snapshot", { conversation: direct, tail: 0 })
    expect(seen.error).toBeUndefined()

    const uma = await signIn("req-uma", "uma@globex.test", "Uma")
    const val = await signIn("req-val", "val@globex.test", "Val")
    const off = await op(uma.token, "home.settings.set", { trust_same_domain: false })
    expect(off.error).toBeUndefined()
    expect(off.value.trust_same_domain).toBe(false)
    const asked = (await op(val.token, "dm.open", { peer: { email: uma.email } })).value
    expect(asked.invite).toEqual({ ok: true })
    expect((await waitRequests(uma, [asked.conversation.id], 1))[0].trusted).toBe(true)

    const kim = await signIn("req-kim", "kim@gmail.com", "Kim")
    const lee = await signIn("req-lee", "lee@gmail.com", "Lee")
    const b = (await op(kim.token, "dm.open", { peer: { email: lee.email } })).value
    expect(b.invite).toEqual({ ok: true })
    expect((await waitRequests(lee, [b.conversation.id], 1))[0].trusted).toBe(false)
  })
})
