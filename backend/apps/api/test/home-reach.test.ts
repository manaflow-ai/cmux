import { env, exports } from "cloudflare:workers"
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
import { conversation as homeConversation, invites } from "@cmux/home-core"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"

/**
 * Human reach through the public API (home-messaging.md sections 4.1 and 16): dm.open by user
 * id, conversation.create with other humans and participants.add of a human are allowed when
 * the two share a team or already have a DM, narrowed by the target's `allow_dm_from`
 * (home.settings.set). Every refusal is `not_reachable`, the same answer as for an unknown
 * account.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; HOME_ADDRESS_KEY: string; ADDRESS_DO: DurableObjectNamespace; TEAM_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace }
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
}
const signIn = async (sub: string, name: string): Promise<Person> => {
  const token = await sessionToken(sub, `${sub}@example.com`, name)
  const ensured = await op(token, "user.ensure", {})
  expect(ensured.ok).toBe(true)
  return { token, user: userIdFor(testEnv.STACK_PROJECT_ID, sub), team: ensured.value.personal_team as string, name }
}
/** Seeds `member` into `owner`'s team (TeamDO knows personal teams only; team invites are not built yet). */
const joinTeam = async (owner: Person, member: Person) => {
  await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(owner.team)), async (instance) => {
    const engine = instance.boundEngine
    engine.state = { ...engine.currentState, members: { ...engine.currentState.members, [member.user]: { user: member.user, role: "member", display_name: member.name } } }
  })
}
const human = (p: Person | string, name = "anything") => ({ id: typeof p === "string" ? p : p.user, kind: "human", display_name: name })
/** `inviter` invites `invitee` by email in a DM and `invitee` accepts; waits until the outbox drain put the DM into the inviter's inbox. */
const becomeContacts = async (inviter: Person, invitee: Person, email: string) => {
  const invited = await op(inviter.token, "dm.open", { peer: { email } })
  expect(invited.value.invite).toEqual({ ok: true })
  const dm = invited.value.conversation.id as string
  const address = invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizeEmail(email) as invites.Address)
  const secret = await inDO(testEnv.ADDRESS_DO.get(testEnv.ADDRESS_DO.idFromName(address)), async (_i, state) => String(state.storage.sql.exec("SELECT secret FROM address_secrets").toArray()[0]!.secret))
  expect((await op(invitee.token, "invite.accept", { code: invites.linkCode(dm), secret })).ok).toBe(true)
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(dm))
  for (let attempt = 0; attempt < 100; attempt++) {
    if ((await read(inviter.token, "inbox.dm_peer", { peer: invitee.user })).value?.conversation === dm) return dm
    await runDurableObjectAlarm(conv)
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
  throw new Error("the accepted DM never reached the inviter's inbox")
}

describe("Home human reach", { timeout: 60_000 }, () => {
  it("dm.open by user id between two users who share a team; the peer's name comes from the team", async () => {
    const alice = await signIn("reach-dm-alice", "Alice")
    const bob = await signIn("reach-dm-bob", "Bob")
    await joinTeam(alice, bob)
    const opened = await op(alice.token, "dm.open", { peer: bob.user }, "dm-1")
    expect(opened.error).toBeUndefined()
    const id = homeConversation.dmConversationId(alice.user, bob.user)
    expect(opened.value.conversation.id).toBe(id)
    const snap = await read(bob.token, "conversation.snapshot", { conversation: id, tail: 0 })
    expect(snap.value.state.participants.map((p: { id: string; display_name: string }) => [p.id, p.display_name])).toEqual([
      [alice.user, "Alice"],
      [bob.user, "Bob"]
    ])
    // The team is symmetric: Bob opens the same DM from his side.
    const back = await op(bob.token, "dm.open", { peer: alice.user }, "dm-2")
    expect(back.value.conversation.id).toBe(id)
  })

  it("a stranger is refused; with allow_dm_from=teams a contact is refused too; an unknown account gets the same answer", async () => {
    const carol = await signIn("reach-set-carol", "Carol")
    const dave = await signIn("reach-set-dave", "Dave")
    const set = await op(carol.token, "home.settings.set", { allow_dm_from: "teams" })
    expect(set.value).toEqual({ discoverable_by_email: false, discoverable_by_phone: false, allow_dm_from: "teams" })
    const stranger = await op(dave.token, "dm.open", { peer: carol.user })
    expect(stranger.error.code).toBe("not_reachable")
    const unknown = await op(dave.token, "dm.open", { peer: "user_00000000000000000000" })
    expect(unknown.error).toEqual(stranger.error)
    // Dave and Carol get a DM through an email invite (a contact), but Carol accepts DMs from teams only.
    await becomeContacts(dave, carol, "reach-set-carol@example.com")
    const group = await op(dave.token, "conversation.create", { title: "Plans", participants: [human(dave, "Dave")] })
    const conversation = group.value.conversation.id as string
    const added = await op(dave.token, "participants.add", { conversation, participant: human(carol) })
    expect(added.error.code).toBe("not_reachable")
    // With allow_dm_from=anyone the contact may add her.
    expect((await op(carol.token, "home.settings.set", { allow_dm_from: "anyone" })).value.allow_dm_from).toBe("anyone")
    expect((await op(dave.token, "participants.add", { conversation, participant: human(carol) })).error).toBeUndefined()
  })

  it("a group with two humans, and participants.add of a team member, a contact and a stranger", async () => {
    const erin = await signIn("reach-group-erin", "Erin")
    const frank = await signIn("reach-group-frank", "Frank")
    const gina = await signIn("reach-group-gina", "Gina")
    const hank = await signIn("reach-group-hank", "Hank")
    await joinTeam(erin, frank)
    const created = await op(erin.token, "conversation.create", { title: "Launch", participants: [human(erin, "Erin"), human(frank, "Mallory")] })
    expect(created.error).toBeUndefined()
    const id = created.value.conversation.id as string
    const snap = await read(frank.token, "conversation.snapshot", { conversation: id, tail: 0 })
    expect(snap.value.state.participants.find((p: { id: string }) => p.id === frank.user).display_name).toBe("Frank")
    expect((await op(erin.token, "conversation.create", { title: "No", participants: [human(erin), human(hank)] })).error.code).toBe("not_reachable")

    // Gina becomes Erin's contact through an accepted email invite; dm.open by her user id then finds that DM.
    const dm = await becomeContacts(erin, gina, "reach-group-gina@example.com")
    const reopened = await op(erin.token, "dm.open", { peer: gina.user }, "dm-gina-user")
    expect(reopened.value.conversation.id).toBe(dm)

    expect((await op(erin.token, "participants.add", { conversation: id, participant: human(gina) })).error).toBeUndefined()
    expect((await op(erin.token, "participants.add", { conversation: id, participant: human(hank) })).error.code).toBe("not_reachable")
    // Frank shares a team with Erin only; he has no relationship with Hank.
    expect((await op(frank.token, "participants.add", { conversation: id, participant: human(hank) })).error.code).toBe("not_reachable")
    const after = await read(erin.token, "conversation.snapshot", { conversation: id, tail: 0 })
    expect(after.value.state.participants.map((p: { id: string }) => p.id).sort()).toEqual([erin.user, frank.user, gina.user].sort())
  })
})
