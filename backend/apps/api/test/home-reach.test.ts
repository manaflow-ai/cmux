import { env, exports } from "cloudflare:workers"
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
import { conversation as homeConversation, invites } from "@cmux/home-core"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"
import { conversationMutate } from "../src/home-routes.ts"

/**
 * Human reach through the public API (home-messaging.md sections 4.1 and 16): dm.open by user
 * id, conversation.create with other humans and participants.add of a human are allowed when
 * the two share a team or are connected (a consented DM; a shared group is no connection),
 * narrowed by the target's `allow_requests_from` (anyone|teams|nobody, home.settings.set). A
 * chief acts under its owner's reach. Every refusal is `not_reachable`, the same answer as for
 * an unknown account.
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
/** Removes `member` from `owner`'s team (a departure from the team). */
const leaveTeam = async (owner: Person, member: Person) => {
  await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(owner.team)), async (instance) => {
    const engine = instance.boundEngine
    const { [member.user]: _gone, ...members } = engine.currentState.members
    engine.state = { ...engine.currentState, members }
  })
}
const send = (p: Person, conversation: string, text: string) => {
  const key = crypto.randomUUID()
  return op(p.token, "message.send", { conversation, client_msg_id: key, parts: [{ type: "text", text }] }, key)
}
/** Waits until the outbox drain put `dm` into `who`'s inbox `peer` index for `peer`. */
const waitPeer = async (who: Person, peer: Person, dm: string) => {
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(dm))
  for (let attempt = 0; attempt < 100; attempt++) {
    if ((await read(who.token, "inbox.dm_peer", { peer: peer.user })).value?.conversation === dm) return
    await runDurableObjectAlarm(conv)
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
  throw new Error("the DM never reached the inbox")
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

  it("a stranger is refused; with allow_requests_from=teams a contact with no shared team still reaches her; nobody refuses the contact; an unknown account gets the same answer", async () => {
    const carol = await signIn("reach-set-carol", "Carol")
    const dave = await signIn("reach-set-dave", "Dave")
    const set = await op(carol.token, "home.settings.set", { allow_requests_from: "teams" })
    expect(set.value).toEqual({ discoverable_by_email: false, discoverable_by_phone: false, allow_requests_from: "teams", email_requests: true })
    // The pre-16.7 name and value are refused.
    expect((await op(carol.token, "home.settings.set", { allow_requests_from: "contacts" })).error).toBeDefined()
    const stranger = await op(dave.token, "dm.open", { peer: carol.user })
    expect(stranger.error.code).toBe("not_reachable")
    const unknown = await op(dave.token, "dm.open", { peer: "user_00000000000000000000" })
    expect(unknown.error).toEqual(stranger.error)
    // Dave and Carol get a DM through an email invite (a contact); they share no team.
    await becomeContacts(dave, carol, "reach-set-carol@example.com")
    const group = await op(dave.token, "conversation.create", { title: "Plans", participants: [human(dave, "Dave")] })
    const conversation = group.value.conversation.id as string
    // nobody: the contact is refused like a stranger.
    expect((await op(carol.token, "home.settings.set", { allow_requests_from: "nobody" })).value.allow_requests_from).toBe("nobody")
    expect((await op(dave.token, "participants.add", { conversation, participant: human(carol) })).error?.code).toBe("not_reachable")
    // teams (16.3): a connected contact reaches her under every value except nobody, with no shared team.
    expect((await op(carol.token, "home.settings.set", { allow_requests_from: "teams" })).value.allow_requests_from).toBe("teams")
    expect((await op(dave.token, "participants.add", { conversation, participant: human(carol) })).error).toBeUndefined()
    // A stranger to Carol is still refused under teams.
    const ellen = await signIn("reach-set-ellen", "Ellen")
    expect((await op(ellen.token, "dm.open", { peer: carol.user })).error?.code).toBe("not_reachable")
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

  it("a DM only one side wrote in is no connection; it becomes one when both have written (16.8)", async () => {
    const ivy = await signIn("reach-consent-ivy", "Ivy")
    const jack = await signIn("reach-consent-jack", "Jack")
    await joinTeam(ivy, jack)
    const dm = (await op(ivy.token, "dm.open", { peer: jack.user })).value.conversation.id as string
    expect((await send(ivy, dm, "hello")).error).toBeUndefined()
    await waitPeer(ivy, jack, dm)
    const conversation = (await op(ivy.token, "conversation.create", { title: "Plans", participants: [human(ivy, "Ivy")] })).value.conversation.id as string
    // Ivy leaves the team: the one-sided DM gives her no reach.
    await leaveTeam(ivy, jack)
    expect((await op(ivy.token, "participants.add", { conversation, participant: human(jack) })).error?.code).toBe("not_reachable")
    // Jack answers: both have written, so they are connected.
    expect((await send(jack, dm, "hi")).error).toBeUndefined()
    expect((await op(ivy.token, "participants.add", { conversation, participant: human(jack) })).error).toBeUndefined()
  })

  it("consent markers: a DM where both wrote stays connected after its messages are deleted; one where only one side wrote is not", async () => {
    const ada = await signIn("reach-marker-ada", "Ada")
    const bo = await signIn("reach-marker-bo", "Bo")
    const cy = await signIn("reach-marker-cy", "Cy")
    await joinTeam(ada, bo)
    await joinTeam(ada, cy)
    const both = (await op(ada.token, "dm.open", { peer: bo.user })).value.conversation.id as string
    const one = (await op(ada.token, "dm.open", { peer: cy.user })).value.conversation.id as string
    expect((await send(ada, both, "hello")).error).toBeUndefined()
    expect((await send(bo, both, "hi")).error).toBeUndefined()
    expect((await send(ada, one, "hello")).error).toBeUndefined()
    await waitPeer(ada, bo, both)
    await waitPeer(ada, cy, one)
    // Retention deletes every message and its msgkey row (home-core sweep.ts); markers stay.
    for (const dm of [both, one])
      await inDO(testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(dm)), async (_i, state) => {
        state.storage.sql.exec("DELETE FROM own_rows WHERE tbl IN ('msg', 'msgkey')")
      })
    await leaveTeam(ada, bo)
    await leaveTeam(ada, cy)
    const conversation = (await op(ada.token, "conversation.create", { title: "Plans", participants: [human(ada, "Ada")] })).value.conversation.id as string
    expect((await op(ada.token, "participants.add", { conversation, participant: human(bo) })).error).toBeUndefined()
    expect((await op(ada.token, "participants.add", { conversation, participant: human(cy) })).error?.code).toBe("not_reachable")
  })

  it("a human who left a group is added back only by someone with a current link to them", async () => {
    const kim = await signIn("reach-left-kim", "Kim")
    const leo = await signIn("reach-left-leo", "Leo")
    await joinTeam(kim, leo)
    const conversation = (await op(kim.token, "conversation.create", { title: "Plans", participants: [human(kim, "Kim"), human(leo, "Leo")] })).value.conversation.id as string
    expect((await op(leo.token, "participants.remove", { conversation, participant: leo.user })).error).toBeUndefined()
    await leaveTeam(kim, leo)
    expect((await op(kim.token, "participants.add", { conversation, participant: human(leo) })).error?.code).toBe("not_reachable")
    await joinTeam(kim, leo)
    expect((await op(kim.token, "participants.add", { conversation, participant: human(leo) })).error).toBeUndefined()
  })

  it("a caller who is not in the conversation learns nothing about the target's setting", async () => {
    const nora = await signIn("reach-probe-nora", "Nora")
    const owen = await signIn("reach-probe-owen", "Owen")
    const pat = await signIn("reach-probe-pat", "Pat")
    const quinn = await signIn("reach-probe-quinn", "Quinn")
    await joinTeam(owen, pat)
    await joinTeam(owen, quinn)
    expect((await op(pat.token, "home.settings.set", { allow_requests_from: "nobody" })).value.allow_requests_from).toBe("nobody")
    const conversation = (await op(nora.token, "conversation.create", { title: "Private", participants: [human(nora, "Nora")] })).value.conversation.id as string
    const refused = await op(owen.token, "participants.add", { conversation, participant: human(pat) })
    const allowed = await op(owen.token, "participants.add", { conversation, participant: human(quinn) })
    expect(refused.error?.code).toBeDefined()
    expect(refused.error?.code).toBe(allowed.error?.code)
  })

  it("allow_requests_from=nobody refuses new reach, also into groups; a shared team does not override it", async () => {
    const rae = await signIn("reach-nobody-rae", "Rae")
    const sam = await signIn("reach-nobody-sam", "Sam")
    await joinTeam(rae, sam)
    expect((await op(sam.token, "home.settings.set", { allow_requests_from: "nobody" })).value.allow_requests_from).toBe("nobody")
    expect((await op(rae.token, "dm.open", { peer: sam.user })).error?.code).toBe("not_reachable")
    expect((await op(rae.token, "conversation.create", { title: "Launch", participants: [human(rae, "Rae"), human(sam)] })).error?.code).toBe("not_reachable")
    const conversation = (await op(rae.token, "conversation.create", { title: "Launch", participants: [human(rae, "Rae")] })).value.conversation.id as string
    expect((await op(rae.token, "participants.add", { conversation, participant: human(sam) })).error?.code).toBe("not_reachable")
    // teams: the shared team reaches him again.
    expect((await op(sam.token, "home.settings.set", { allow_requests_from: "teams" })).value.allow_requests_from).toBe("teams")
    expect((await op(rae.token, "participants.add", { conversation, participant: human(sam) })).error).toBeUndefined()
  })

  it("a shared group is no connection (16.3)", async () => {
    const tia = await signIn("reach-group-tia", "Tia")
    const uma = await signIn("reach-group-uma", "Uma")
    const vic = await signIn("reach-group-vic", "Vic")
    await joinTeam(tia, uma)
    await joinTeam(tia, vic)
    // Uma and Vic share Tia's group (each shares a team with Tia, not with each other).
    expect((await op(tia.token, "conversation.create", { title: "All", participants: [human(tia, "Tia"), human(uma), human(vic)] })).error).toBeUndefined()
    const own = (await op(uma.token, "conversation.create", { title: "Side", participants: [human(uma, "Uma")] })).value.conversation.id as string
    expect((await op(uma.token, "participants.add", { conversation: own, participant: human(vic) })).error?.code).toBe("not_reachable")
    expect((await op(uma.token, "dm.open", { peer: vic.user })).error?.code).toBe("not_reachable")
  })
})

/** A chief created by `owner`, with the principal its cloud connection would carry (an agent install of the owner). */
const chiefOf = async (owner: Person, key: string) => {
  const chief = (await op(owner.token, "chief.create", {}, key)).value as { id: string }
  const principal = { identity: `inst_${key}`, kind: "agent" as const, agent: chief.id, user: owner.user, team: owner.team, display_name: "Chief", grant_classes: ["read", "mutate-own", "mutate-shared", "execute"] }
  const submit = async (name: string, params: Record<string, unknown>) => {
    const res = await conversationMutate(env as never, principal, { t: "op", op: name, params, idempotency_key: crypto.randomUUID() })
    const reply = res.frames.find((f) => f.t === "result" || f.t === "reject") as { t: string; code?: string } | undefined
    return reply?.t === "reject" ? { error: { code: reply.code } } : { error: undefined }
  }
  return { id: chief.id, submit, participant: { id: chief.id, kind: "agent", display_name: "Chief", agent_class: "mux" } }
}

describe("a chief adds humans under its owner's reach (CHIEF-DONE autonomy rule)", { timeout: 60_000 }, () => {
  it("adds a person its owner shares a team with; a stranger to its owner is not_reachable", async () => {
    const wes = await signIn("reach-chief-wes", "Wes")
    const xia = await signIn("reach-chief-xia", "Xia")
    const yan = await signIn("reach-chief-yan", "Yan")
    await joinTeam(wes, xia)
    const chief = await chiefOf(wes, "chief-wes")
    const created = await op(wes.token, "conversation.create", { title: "Work", participants: [human(wes, "Wes"), chief.participant] })
    expect(created.error).toBeUndefined()
    const conversation = created.value.conversation.id as string
    expect((await chief.submit("participants.add", { conversation, participant: human(xia) })).error).toBeUndefined()
    expect((await chief.submit("participants.add", { conversation, participant: human(yan) })).error?.code).toBe("not_reachable")
    // The target's setting is checked against the owner.
    const zed = await signIn("reach-chief-zed", "Zed")
    await joinTeam(wes, zed)
    expect((await op(zed.token, "home.settings.set", { allow_requests_from: "nobody" })).value.allow_requests_from).toBe("nobody")
    expect((await chief.submit("participants.add", { conversation, participant: human(zed) })).error?.code).toBe("not_reachable")
    const snap = await read(wes.token, "conversation.snapshot", { conversation, tail: 0 })
    expect(snap.value.state.participants.map((p: { id: string }) => p.id).sort()).toEqual([wes.user, chief.id, xia.user].sort())
  })

  it("never re-adds a departed human its owner has no link to", async () => {
    const abe = await signIn("reach-chief-abe", "Abe")
    const bea = await signIn("reach-chief-bea", "Bea")
    await joinTeam(abe, bea)
    const chief = await chiefOf(abe, "chief-abe")
    const conversation = (await op(abe.token, "conversation.create", { title: "Work", participants: [human(abe, "Abe"), human(bea, "Bea"), chief.participant] })).value.conversation.id as string
    expect((await op(bea.token, "participants.remove", { conversation, participant: bea.user })).error).toBeUndefined()
    await leaveTeam(abe, bea)
    expect((await chief.submit("participants.add", { conversation, participant: human(bea) })).error?.code).toBe("not_reachable")
    await joinTeam(abe, bea)
    expect((await chief.submit("participants.add", { conversation, participant: human(bea) })).error).toBeUndefined()
  })

  it("under nobody a connected contact keeps the existing DM, but a new group add and a chief dm.open are refused", async () => {
    const eli = await signIn("reach-chief-eli", "Eli")
    const fay = await signIn("reach-chief-fay", "Fay")
    // A connected pair with no shared team: an accepted email invite.
    const dm = await becomeContacts(eli, fay, "reach-chief-fay@example.com")
    expect((await op(fay.token, "home.settings.set", { allow_requests_from: "nobody" })).value.allow_requests_from).toBe("nobody")
    // The existing DM is reused as is.
    expect((await op(eli.token, "dm.open", { peer: fay.user })).value.conversation.id).toBe(dm)
    const chief = await chiefOf(eli, "chief-eli")
    const conversation = (await op(eli.token, "conversation.create", { title: "Work", participants: [human(eli, "Eli"), chief.participant] })).value.conversation.id as string
    expect((await op(eli.token, "participants.add", { conversation, participant: human(fay) })).error?.code).toBe("not_reachable")
    expect((await chief.submit("participants.add", { conversation, participant: human(fay) })).error?.code).toBe("not_reachable")
    // A chief never opens a DM (DMs are between humans): refused for every target, so it learns nothing.
    expect((await chief.submit("dm.open", { peer: fay.user })).error?.code).toBe("forbidden")
    // Under teams the chief adds its owner's contact.
    expect((await op(fay.token, "home.settings.set", { allow_requests_from: "teams" })).value.allow_requests_from).toBe("teams")
    expect((await chief.submit("participants.add", { conversation, participant: human(fay) })).error).toBeUndefined()
  })

  it("only the mux class acts under its owner's reach: an automation principal with a chief's id gets none", async () => {
    const gil = await signIn("reach-chief-gil", "Gil")
    const hal = await signIn("reach-chief-hal", "Hal")
    await joinTeam(gil, hal)
    const chief = await chiefOf(gil, "chief-gil")
    const conversation = (await op(gil.token, "conversation.create", { title: "Work", participants: [human(gil, "Gil"), chief.participant] })).value.conversation.id as string
    // An automation run principal (automation-caps.ts shape) that carries the chief's agent id and the owner's user.
    const automation = { identity: `automation:${chief.id}`, kind: "agent" as const, agent: chief.id, run: "run_1", user: gil.user, team: gil.team, grant_classes: ["read", "mutate-own", "mutate-shared", "execute"] }
    const res = await conversationMutate(env as never, automation, { t: "op", op: "participants.add", params: { conversation, participant: human(hal) }, idempotency_key: crypto.randomUUID() })
    expect(res.frames.find((f) => f.t === "reject")).toMatchObject({ code: "not_reachable" })
    // The chief itself (class mux) adds him.
    expect((await chief.submit("participants.add", { conversation, participant: human(hal) })).error).toBeUndefined()
  })

  it("an agent that is not one of the claimed owner's chiefs gets no reach, also not for a departed human", async () => {
    const cal = await signIn("reach-chief-cal", "Cal")
    const dee = await signIn("reach-chief-dee", "Dee")
    await joinTeam(cal, dee)
    const chief = await chiefOf(cal, "chief-cal")
    const conversation = (await op(cal.token, "conversation.create", { title: "Work", participants: [human(cal, "Cal"), human(dee, "Dee"), chief.participant] })).value.conversation.id as string
    expect((await op(dee.token, "participants.remove", { conversation, participant: dee.user })).error).toBeUndefined()
    // The same chief claiming another owner: that owner has no such chief, so no facts at all.
    const res = await conversationMutate(env as never, { identity: "inst_forged", kind: "agent", agent: chief.id, user: dee.user, team: dee.team, grant_classes: ["read", "mutate-own", "mutate-shared", "execute"] }, {
      t: "op",
      op: "participants.add",
      params: { conversation, participant: human(dee) },
      idempotency_key: crypto.randomUUID()
    })
    expect(res.frames.find((f) => f.t === "reject")).toMatchObject({ code: "not_reachable" })
  })
})
