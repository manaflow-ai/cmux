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
type Message = { id: string; seq: number; author: string; parts: Array<{ type: string; text?: string }>; reactions: Array<{ author: string; part_index: number; kind: unknown }>; edited_at?: string; retracted_at?: string; thread_root?: string }
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
    // A send moves the sender's own cursor (cx-59n8.4): Alice has read her two messages.
    expect(state.read_cursors[alice.user]).toBe(2)
  })

  it("threads: thread_root over HTTP, nested replies, the sender's cursor, and no root below the since_join floor (cx-59n8.4)", async () => {
    const send = (token: string, conversation: string, key: string, extra: Record<string, unknown> = {}) =>
      op(token, "message.send", { conversation, client_msg_id: key, parts: [{ type: "text", text: key }], ...extra }, key)
    const { alice, bob, id } = await twoPersonGroup("threads")
    const root = (await send(alice.token, id, "root")).json.value.message_id as string
    expect((await op(bob.token, "read_cursor.set", { conversation: id, seq: 1 }, "bob-read")).json.ok).toBe(true)
    const reply = await send(bob.token, id, "reply", { thread_root: root })
    expect(reply.json.ok).toBe(true)
    const replyId = reply.json.value.message_id as string
    expect((await history(alice.token, id)).find((m) => m.id === replyId)?.thread_root).toBe(root)
    expect(refused(await send(bob.token, id, "nested", { thread_root: replyId }))).toBe("invalid_thread_root")
    // Nested threads (conversation-tree-v1): a reply to a thread reply with no thread_root joins the root's thread.
    const deep = await send(alice.token, id, "deep", { reply_to: { message_id: replyId, part_index: 0 } })
    expect(deep.json.ok).toBe(true)
    expect((await history(alice.token, id)).find((m) => m.id === deep.json.value.message_id)?.thread_root).toBe(root)
    expect(refused(await send(bob.token, id, "nowhere", { thread_root: `msg_${"0".repeat(26)}` }))).toBe("invalid_thread_root")
    // Alice is behind (Bob's reply is unread to her): her send keeps her cursor; Bob was caught up: his moves.
    await send(alice.token, id, "behind")
    const state = await head(alice.token, id)
    expect(state.read_cursors[alice.user]).toBe(1)
    expect(state.read_cursors[bob.user]).toBe(2)

    // since_join: a member who joined after the root cannot reply in its thread (as if it did not exist).
    const carol = await signIn("home-ops-threads-carol", "carol-threads@example.com", "Carol Example")
    expect((await op(alice.token, "conversation.settings.set", { conversation: id, history_visible: "since_join" })).json.ok).toBe(true)
    const invited = await op(alice.token, "invite.create", { conversation: id, address: { email: "carol-threads@example.com" }, display_name: "Carol" })
    expect(invited.json.ok).toBe(true)
    const address = invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizeEmail("carol-threads@example.com") as invites.Address)
    const stash = testEnv.ADDRESS_DO.get(testEnv.ADDRESS_DO.idFromName(address))
    const secret = await runInDurableObject(stash, async (_i, st) => String(st.storage.sql.exec("SELECT secret FROM address_secrets").toArray()[0]!.secret))
    expect((await op(carol.token, "invite.accept", { code: invites.linkCode(id), secret })).json.ok).toBe(true)
    expect(refused(await send(carol.token, id, "late", { thread_root: root }))).toBe("invalid_thread_root")
    // A reply Carol can see whose root she cannot: replying to it does not derive the hidden root.
    const later = (await send(alice.token, id, "later", { thread_root: root })).json.value.message_id as string
    expect(refused(await send(carol.token, id, "late-deep", { reply_to: { message_id: later, part_index: 0 } }))).toBe("invalid_thread_root")
    const fresh = (await send(alice.token, id, "fresh")).json.value.message_id as string
    expect((await send(carol.token, id, "in-fresh", { thread_root: fresh })).json.ok).toBe(true)
  })

  it("conversation.thread: the whole thread, paging, root stats on history and snapshot, and refusals (cx-59n8.6)", async () => {
    const send = (token: string, conversation: string, key: string, extra: Record<string, unknown> = {}) =>
      op(token, "message.send", { conversation, client_msg_id: key, parts: [{ type: "text", text: key }], ...extra }, key)
    const thread = (token: string, conversation: string, root: string, extra: Record<string, unknown> = {}) => read(token, "conversation.thread", { conversation, root, ...extra })
    // A refused read is an HttpApi error body: {_tag, code, message} at the top level.
    const readRefused = (r: { status: number; json: any }) => [r.status, r.json?.code as string | undefined]
    const { alice, bob, id } = await twoPersonGroup("thread-read")
    const root = (await send(alice.token, id, "tr-root")).json.value.message_id as string
    const lonely = (await send(alice.token, id, "tr-lonely")).json.value.message_id as string
    const r1 = (await send(bob.token, id, "tr-1", { thread_root: root })).json.value.message_id as string
    const r2 = (await send(alice.token, id, "tr-2", { thread_root: root })).json.value.message_id as string
    const r3 = (await send(bob.token, id, "tr-3", { thread_root: root })).json.value.message_id as string

    const all = await thread(alice.token, id, root)
    expect(all.status).toBe(200)
    const v = all.json.value as { root: Message; replies: Array<Message & { created_at: string }>; has_more: boolean; thread: unknown }
    expect(v.root.id).toBe(root)
    expect(v.replies.map((m) => m.id)).toEqual([r1, r2, r3])
    expect(v.replies.every((m) => m.thread_root === root)).toBe(true)
    expect(v.has_more).toBe(false)
    const last = v.replies[2]!
    const summary = { root, reply_count: 3, last_reply_seq: last.seq, last_reply_at: last.created_at, authors: [bob.user, alice.user], status: "open" }
    expect(v.thread).toEqual(summary)

    // Paging: after_seq is exclusive; has_more is exact (a page that ends at the last reply says false).
    const page1 = (await thread(alice.token, id, root, { limit: 2 })).json.value
    expect(page1.replies.map((m: Message) => m.id)).toEqual([r1, r2])
    expect(page1.has_more).toBe(true)
    const page2 = (await thread(alice.token, id, root, { limit: 2, after_seq: page1.replies[1].seq })).json.value
    expect(page2.replies.map((m: Message) => m.id)).toEqual([r3])
    expect(page2.has_more).toBe(false)
    expect((await thread(alice.token, id, root, { limit: 3 })).json.value.has_more).toBe(false)
    expect(page2.thread).toEqual(summary)

    // A root with no replies answers with an empty thread.
    expect((await thread(bob.token, id, lonely)).json.value).toMatchObject({ replies: [], has_more: false, thread: { root: lonely, reply_count: 0, last_reply_seq: null, last_reply_at: null, authors: [], status: "open" } })

    // history and snapshot carry the stats of the roots in their page only (exact, not over the loaded window).
    expect((await read(bob.token, "conversation.history", { conversation: id, limit: 50 })).json.value.threads).toEqual([summary])
    expect((await read(bob.token, "conversation.snapshot", { conversation: id, tail: 50 })).json.value.threads).toEqual([summary])
    expect((await read(bob.token, "conversation.history", { conversation: id, before_seq: v.root.seq, limit: 50 })).json.value.threads ?? []).toEqual([])

    // Refusals: a reply as root, an unknown id, a stranger.
    expect(readRefused(await thread(alice.token, id, r1))).toEqual([400, "unknown_message"])
    expect(readRefused(await thread(alice.token, id, `msg_${"0".repeat(26)}`))).toEqual([400, "unknown_message"])
    const dana = await signIn("home-ops-thread-read-dana", "dana-thread-read@example.com", "Dana Example")
    expect((await thread(dana.token, id, root)).status).toBe(403)

    // since_join: a member who joined later cannot read a root below its floor (same code as unknown).
    const carol = await signIn("home-ops-thread-read-carol", "carol-thread-read@example.com", "Carol Example")
    expect((await op(alice.token, "conversation.settings.set", { conversation: id, history_visible: "since_join" })).json.ok).toBe(true)
    expect((await op(alice.token, "invite.create", { conversation: id, address: { email: "carol-thread-read@example.com" }, display_name: "Carol" })).json.ok).toBe(true)
    const address = invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizeEmail("carol-thread-read@example.com") as invites.Address)
    const stash = testEnv.ADDRESS_DO.get(testEnv.ADDRESS_DO.idFromName(address))
    const secret = await runInDurableObject(stash, async (_i, st) => String(st.storage.sql.exec("SELECT secret FROM address_secrets").toArray()[0]!.secret))
    expect((await op(carol.token, "invite.accept", { code: invites.linkCode(id), secret })).json.ok).toBe(true)
    expect(readRefused(await thread(carol.token, id, root))).toEqual([400, "unknown_message"])
    // The same root is hidden from thread.update: no probe, no change.
    expect(refused(await op(carol.token, "thread.update", { conversation: id, root, title: "x" }))).toBe("unknown_message")
    const fresh = (await send(alice.token, id, "tr-fresh")).json.value.message_id as string
    const freshReply = (await send(carol.token, id, "tr-fresh-1", { thread_root: fresh })).json.value.message_id as string
    expect((await thread(carol.token, id, fresh)).json.value.replies.map((m: Message) => m.id)).toEqual([freshReply])
  })

  it("conversation.thread: a retracted reply stays in the thread but not in the stats (cx-59n8.9)", async () => {
    const send = (token: string, conversation: string, key: string, extra: Record<string, unknown> = {}) =>
      op(token, "message.send", { conversation, client_msg_id: key, parts: [{ type: "text", text: key }], ...extra }, key)
    const retract = async (token: string, conversation: string, message: string) => expect((await op(token, "message.retract", { conversation, message_id: message })).json.ok).toBe(true)
    const thread = async (token: string, conversation: string, root: string) =>
      (await read(token, "conversation.thread", { conversation, root })).json.value as { replies: Array<Message & { created_at: string }>; thread: unknown }
    const stats = async (token: string, conversation: string) => [
      (await read(token, "conversation.history", { conversation, limit: 50 })).json.value.threads ?? [],
      (await read(token, "conversation.snapshot", { conversation, tail: 50 })).json.value.threads ?? []
    ]
    const { alice, bob, id } = await twoPersonGroup("thread-retract")
    const root = (await send(alice.token, id, "rr-root")).json.value.message_id as string
    const r1 = (await send(bob.token, id, "rr-1", { thread_root: root })).json.value.message_id as string
    const r2 = (await send(alice.token, id, "rr-2", { thread_root: root })).json.value.message_id as string
    const r3 = (await send(bob.token, id, "rr-3", { thread_root: root })).json.value.message_id as string
    const before = await thread(alice.token, id, root)
    const [m1] = before.replies

    // A middle reply retracted: its author leaves the authors, the count drops, the last reply stays.
    await retract(alice.token, id, r2)
    const middle = { root, reply_count: 2, last_reply_seq: before.replies[2]!.seq, last_reply_at: before.replies[2]!.created_at, authors: [bob.user], status: "open" }
    const afterMiddle = await thread(bob.token, id, root)
    expect(afterMiddle.replies.map((m) => m.id)).toEqual([r1, r2, r3])
    expect(afterMiddle.replies[1]!.retracted_at).toBeDefined()
    expect(afterMiddle.thread).toEqual(middle)
    expect(await stats(bob.token, id)).toEqual([[middle], [middle]])

    // The last reply retracted: the last reply is the newest one that is not retracted.
    await retract(bob.token, id, r3)
    const last = { root, reply_count: 1, last_reply_seq: m1!.seq, last_reply_at: m1!.created_at, authors: [bob.user], status: "open" }
    expect((await thread(alice.token, id, root)).thread).toEqual(last)
    expect(await stats(alice.token, id)).toEqual([[last], [last]])

    // Every reply retracted: the root has no stats entry, and the thread read reports none.
    await retract(bob.token, id, r1)
    const none = await thread(alice.token, id, root)
    expect(none.replies.map((m) => m.id)).toEqual([r1, r2, r3])
    expect(none.thread).toEqual({ root, reply_count: 0, last_reply_seq: null, last_reply_at: null, authors: [], status: "open" })
    expect(await stats(alice.token, id)).toEqual([[], []])
  })

  it("thread.update: a title, an owner and a status on a thread root; a new reply reopens a resolved thread", async () => {
    const send = (token: string, conversation: string, key: string, extra: Record<string, unknown> = {}) =>
      op(token, "message.send", { conversation, client_msg_id: key, parts: [{ type: "text", text: key }], ...extra }, key)
    const update = (token: string, conversation: string, fields: Record<string, unknown>, key?: string) => op(token, "thread.update", { conversation, ...fields }, key)
    const thread = async (token: string, conversation: string, root: string) =>
      (await read(token, "conversation.thread", { conversation, root })).json.value as { root: Message & { thread?: unknown }; thread: Record<string, unknown> }
    const { alice, bob, id } = await twoPersonGroup("thread-objects")
    const root = (await send(alice.token, id, "to-root")).json.value.message_id as string
    const r1 = (await send(bob.token, id, "to-1", { thread_root: root })).json.value.message_id as string
    expect((await thread(alice.token, id, root)).thread.status).toBe("open")

    // Alice titles it and gives it to Bob: the change is message-updated with the root.
    const titled = await update(alice.token, id, { root, title: "Ship 1.0", owner: bob.user }, "to-t1")
    expect(titled.json.ok).toBe(true)
    expect(titled.json.value.change.kind).toBe("message-updated")
    expect(titled.json.value.change.message.thread).toEqual({ title: "Ship 1.0", owner: bob.user })
    // Bob resolves it; every read carries the object and the derived status.
    expect((await update(bob.token, id, { root, status: "resolved" })).json.ok).toBe(true)
    const resolved = await thread(alice.token, id, root)
    expect(resolved.thread).toMatchObject({ root, reply_count: 1, status: "resolved", title: "Ship 1.0", owner: bob.user, resolved_by: bob.user })
    expect((await read(bob.token, "conversation.snapshot", { conversation: id, tail: 50 })).json.value.threads).toEqual([resolved.thread])
    // A new reply reopens it; the stored resolution stays on the root.
    await send(alice.token, id, "to-2", { thread_root: root })
    const reopened = await thread(bob.token, id, root)
    expect(reopened.thread.status).toBe("open")
    expect(reopened.thread.resolved_by).toBeUndefined()
    expect((reopened.root.thread as { resolved?: unknown }).resolved).toBeDefined()

    // Refusals: a reply as root, nothing to set, an owner outside the conversation, a stranger.
    expect(refused(await update(alice.token, id, { root: r1, title: "x" }))).toBe("invalid_thread_root")
    expect(refused(await update(alice.token, id, { root }))).toBe("invalid_thread_update")
    expect(refused(await update(alice.token, id, { root, owner: "user_nobody" }))).toBe("invalid_thread_owner")
    const dana = await signIn("home-ops-thread-objects-dana", "dana-thread-objects@example.com", "Dana Example")
    expect((await update(dana.token, id, { root, title: "x" })).json.ok).toBe(false)
    // Empty title and owner clear the object.
    expect((await update(bob.token, id, { root, title: "", owner: "", status: "open" })).json.ok).toBe(true)
    expect((await thread(alice.token, id, root)).root.thread).toBeUndefined()
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
