import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { conversation as homeConversation, invites } from "@cmux/home-core"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"

/**
 * The conversation ops of home-messaging.md section 4.1 through POST /v1/ops, with two signed-in
 * people in one group: participants.add/remove, reactions, edit and retract, read cursors and
 * title. The second person joins through a group email invite (the only human add path that needs
 * no reach facts), so the test runs without team or contact records.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; HOME_ADDRESS_KEY: string; ADDRESS_DO: DurableObjectNamespace; TEAM_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
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
  const res = await worker.fetch(`https://api.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(body)
  })
  return { status: res.status, json: (await res.json().catch(() => null)) as any }
}
const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })
const read = (token: string, name: string, params: unknown) => call("/v1/read", token, { op: name, params })
const signIn = async (sub: string, email: string, name: string) => {
  const token = await sessionToken(sub, email, name)
  expect((await op(token, "user.ensure", {})).json.ok).toBe(true)
  return { token, user: userIdFor(testEnv.STACK_PROJECT_ID, sub) }
}
const refused = (r: { json: any }) => r.json.error?.code as string | undefined
type Message = { id: string; seq: number; author: string; parts: Array<{ type: string; text?: string }>; reactions: Array<{ author: string; part_index: number; kind: unknown }>; edited_at?: string; retracted_at?: string }
const history = async (token: string, conversation: string) => (await read(token, "conversation.history", { conversation, limit: 50 })).json.value.messages as Array<Message>
const head = async (token: string, conversation: string) => (await read(token, "conversation.snapshot", { conversation, tail: 0 })).json.value.state as homeConversation.ConversationHead

/** Alice's group with Bob, who joined through a group email invite to his verified address. */
const twoPersonGroup = async (tag: string) => {
  const alice = await signIn(`home-ops-${tag}-alice`, `alice-${tag}@example.com`, "Alice Example")
  const bob = await signIn(`home-ops-${tag}-bob`, `bob-${tag}@example.com`, "Bob Example")
  const created = await op(alice.token, "conversation.create", { title: "Plans", participants: [{ id: alice.user, kind: "human", display_name: "Alice Example" }] })
  expect(created.json.ok).toBe(true)
  const id = created.json.value.conversation.id as string
  const invited = await op(alice.token, "invite.create", { conversation: id, address: { email: `bob-${tag}@example.com` }, display_name: "Bob" })
  expect(invited.json.ok).toBe(true)
  const address = invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizeEmail(`bob-${tag}@example.com`) as invites.Address)
  const stash = testEnv.ADDRESS_DO.get(testEnv.ADDRESS_DO.idFromName(address))
  const secret = await runInDurableObject(stash, async (_i, state) => String(state.storage.sql.exec("SELECT secret FROM address_secrets").toArray()[0]!.secret))
  const accepted = await op(bob.token, "invite.accept", { code: invites.linkCode(id), secret })
  expect(accepted.json.ok).toBe(true)
  return { alice, bob, id }
}

describe("Home conversation ops over HTTP (two people)", { timeout: 60_000 }, () => {
  it("a two-person group: both are current human participants, both send, both read the same history", async () => {
    const { alice, bob, id } = await twoPersonGroup("pair")
    const state = await head(alice.token, id)
    const humans = state.participants.filter((p) => p.kind === "human" && p.left_at === undefined).map((p) => p.id)
    expect(humans.sort()).toEqual([alice.user, bob.user].sort())
    // The invited address is gone once Bob holds its place.
    expect(state.participants.some((p) => p.kind === "address" && p.left_at === undefined)).toBe(false)
    expect((await op(alice.token, "message.send", { conversation: id, client_msg_id: "a1", parts: [{ type: "text", text: "hi Bob" }] }, "a1")).json.ok).toBe(true)
    expect((await op(bob.token, "message.send", { conversation: id, client_msg_id: "b1", parts: [{ type: "text", text: "hi Alice" }] }, "b1")).json.ok).toBe(true)
    for (const token of [alice.token, bob.token]) {
      const messages = await history(token, id)
      expect(messages.map((m) => [m.author, m.parts[0]!.text])).toEqual([
        [alice.user, "hi Bob"],
        [bob.user, "hi Alice"]
      ])
    }
  })

  it("reaction.add and reaction.remove: one per (author, part, kind); the other person's reaction stays", async () => {
    const { alice, bob, id } = await twoPersonGroup("react")
    const sent = await op(alice.token, "message.send", { conversation: id, client_msg_id: "m1", parts: [{ type: "text", text: "lunch?" }] }, "m1")
    const message = sent.json.value.message_id as string
    const love = { conversation: id, message_id: message, part_index: 0, reaction: { tapback: "love" } }
    expect((await op(bob.token, "reaction.add", love)).json.ok).toBe(true)
    expect(refused(await op(bob.token, "reaction.add", love))).toBe("duplicate_reaction")
    expect((await op(alice.token, "reaction.add", love)).json.ok).toBe(true)
    expect(refused(await op(bob.token, "reaction.add", { ...love, part_index: 3 }))).toBe("invalid_part_index")
    expect(refused(await op(bob.token, "reaction.add", { ...love, reaction: { tapback: "nope" } }))).toBe("invalid_reaction")
    expect((await op(bob.token, "reaction.remove", love)).json.ok).toBe(true)
    const [stored] = await history(alice.token, id)
    expect(stored!.reactions.map((r) => r.author)).toEqual([alice.user])
  })

  it("message.edit and message.retract: author only; a retraction clears parts and reactions and ends edits", async () => {
    const { alice, bob, id } = await twoPersonGroup("edit")
    const sent = await op(alice.token, "message.send", { conversation: id, client_msg_id: "m1", parts: [{ type: "text", text: "draft" }] }, "m1")
    const message = sent.json.value.message_id as string
    expect(refused(await op(bob.token, "message.edit", { conversation: id, message_id: message, parts: [{ type: "text", text: "hijack" }] }))).toBe("not_author")
    expect((await op(alice.token, "message.edit", { conversation: id, message_id: message, parts: [{ type: "text", text: "final" }] })).json.ok).toBe(true)
    let [stored] = await history(bob.token, id)
    expect(stored!.parts[0]!.text).toBe("final")
    expect(stored!.edited_at).toBeDefined()
    expect((await op(bob.token, "reaction.add", { conversation: id, message_id: message, part_index: 0, reaction: { tapback: "like" } })).json.ok).toBe(true)
    expect(refused(await op(bob.token, "message.retract", { conversation: id, message_id: message }))).toBe("not_author")
    expect((await op(alice.token, "message.retract", { conversation: id, message_id: message })).json.ok).toBe(true)
    ;[stored] = await history(bob.token, id)
    expect(stored!.parts).toEqual([])
    expect(stored!.reactions).toEqual([])
    expect(stored!.retracted_at).toBeDefined()
    expect(refused(await op(alice.token, "message.edit", { conversation: id, message_id: message, parts: [{ type: "text", text: "again" }] }))).toBe("retracted")
    expect(refused(await op(alice.token, "message.retract", { conversation: id, message_id: `msg_${"0".repeat(26)}` }))).toBe("unknown_message")
  })

  it("read_cursor.set: each person's own cursor, monotonic and at most last_seq", async () => {
    const { alice, bob, id } = await twoPersonGroup("cursor")
    for (const n of [1, 2]) await op(alice.token, "message.send", { conversation: id, client_msg_id: `m${n}`, parts: [{ type: "text", text: `m${n}` }] }, `m${n}`)
    expect((await op(bob.token, "read_cursor.set", { conversation: id, seq: 2 }, "read:2")).json.ok).toBe(true)
    expect(refused(await op(bob.token, "read_cursor.set", { conversation: id, seq: 1 }, "read:1"))).toBe("cursor_regression")
    expect((await op(bob.token, "read_cursor.set", { conversation: id, seq: 3 }, "read:3")).json.ok).toBe(false)
    const state = await head(alice.token, id)
    expect(state.read_cursors[bob.user]).toBe(2)
    expect(state.read_cursors[alice.user] ?? 0).toBe(0)
  })

  it("title.set: any member of a group; refused in a DM", async () => {
    const { alice, bob, id } = await twoPersonGroup("title")
    expect((await op(bob.token, "title.set", { conversation: id, title: "Friday plans" })).json.ok).toBe(true)
    expect((await head(alice.token, id)).title).toBe("Friday plans")
    expect(refused(await op(alice.token, "title.set", { conversation: id, title: "" }))).toBe("invalid_title")
    const dm = await op(alice.token, "dm.open", { peer: { email: "title-dm@example.com" } }, "dm-title")
    expect(refused(await op(alice.token, "title.set", { conversation: dm.json.value.conversation.id, title: "x" }))).toBe("kind_forbids")
  })

  it("participants.remove and participants.add: leave, rejoin by a member, removal by the owner only", async () => {
    const { alice, bob, id } = await twoPersonGroup("members")
    // Bob is not the owner: he cannot remove Alice.
    expect(refused(await op(bob.token, "participants.remove", { conversation: id, participant: alice.user }))).toBe("forbidden")
    // Bob leaves; he can no longer read or send.
    expect((await op(bob.token, "participants.remove", { conversation: id, participant: bob.user })).json.ok).toBe(true)
    expect((await read(bob.token, "conversation.history", { conversation: id })).status).toBe(403)
    expect(refused(await op(bob.token, "message.send", { conversation: id, client_msg_id: "late", parts: [{ type: "text", text: "late" }] }, "late"))).toBe("not_participant")
    // A departed human comes back only through someone with a current link (16.7): with none, Alice is refused.
    expect(refused(await op(alice.token, "participants.add", { conversation: id, participant: { id: bob.user, kind: "human", display_name: "Bob" } }))).toBe("not_reachable")
    // Bob joins Alice's team (a shared team is a current link; members are TeamDO rows).
    await runInDurableObject(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(personalTeamIdFor(alice.user))), async (_i, state) => {
      state.storage.sql.exec("INSERT OR REPLACE INTO own_rows (tbl, k, n, json) VALUES ('member', ?, NULL, ?)", bob.user, JSON.stringify({ user: bob.user, role: "member", display_name: "Bob Example" }))
    })
    // Alice adds him back (a former participant of this conversation); he reads again.
    const back = await op(alice.token, "participants.add", { conversation: id, participant: { id: bob.user, kind: "human", display_name: "Bobby Tables" } })
    expect(back.json.ok).toBe(true)
    expect((await read(bob.token, "conversation.history", { conversation: id })).status).toBe(200)
    // The stored name is kept, never the caller's value.
    expect((await head(alice.token, id)).participants.find((p) => p.id === bob.user)?.display_name).toBe("Bob Example")
    expect(refused(await op(alice.token, "participants.add", { conversation: id, participant: { id: bob.user, kind: "human", display_name: "Bob" } }))).toBe("duplicate_participant")
    // A stranger with no link to Alice cannot be added by HTTP.
    const stranger = userIdFor(testEnv.STACK_PROJECT_ID, "home-ops-members-stranger")
    expect((await op(alice.token, "participants.add", { conversation: id, participant: { id: stranger, kind: "human", display_name: "S" } })).json.ok).toBe(false)
    // The owner removes Bob; the last human leaving archives the conversation.
    expect((await op(alice.token, "participants.remove", { conversation: id, participant: bob.user })).json.ok).toBe(true)
    expect((await op(alice.token, "participants.remove", { conversation: id, participant: alice.user })).json.ok).toBe(true)
    expect(refused(await op(alice.token, "participants.remove", { conversation: id, participant: alice.user }))).toBe("not_participant")
  })
})
