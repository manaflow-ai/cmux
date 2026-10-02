import { env, exports } from "cloudflare:workers"
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
import { conversation, invites } from "@cmux/home-core"
import type { Principal } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import type { Env } from "../src/env.ts"

const testEnv = env as unknown as Env & { STACK_TEST_PRIVATE_JWK: string }
const worker = (exports as unknown as { default: Fetcher }).default
/** DO RPC stubs erase method types; these tests call the methods the classes define. */
type Stub = { submit(e: string, p: Principal, f: unknown): Promise<{ frames: Array<{ t: string }> }>; readOp(e: string, p: Principal, op: string, params: unknown): Promise<unknown>; readInbox(e: string, p: Principal, op: string, params: unknown): Promise<unknown>; card(e: string): Promise<{ first_name: string } | null> }
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const stub = (ns: any, name: string): Stub & DurableObjectStub => ns.get(ns.idFromName(name))

const stackToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: "Alice Example" })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))

const session = (user: string): Principal => ({ kind: "session", identity: `session:${user}`, user, team: personalTeamIdFor(user), display_name: "Alice Example", email: "a@example.com", email_verified: true })

let n = 0
const convId = () => `conv_01J0000000000000000HOME${String(n++).padStart(2, "0")}`.slice(0, 31)

describe("Home objects: ConversationDO fan-out to the UserDO inbox stream (E2, E4)", () => {
  it("a send in a conversation reaches the participant's inbox through the outbox drain", async () => {
    const user = userIdFor(testEnv.STACK_PROJECT_ID, "home-fanout")
    const id = convId()
    const conv = stub(testEnv.CONVERSATION_DO, id)
    const me = session(user)
    const created = await conv.submit(id, me, { t: "op", op: "conversation.create", params: { id, kind: "group", title: "Plans", participants: [{ id: user, kind: "human", display_name: "Alice Example" }] }, idempotency_key: "create-1" })
    expect(created.frames.find((f) => f.t === "result" || f.t === "reject")).toMatchObject({ t: "result" })
    const sent = await conv.submit(id, me, { t: "op", op: "message.send", params: { client_msg_id: "cm-1", parts: [{ type: "text", text: "hello inbox" }] }, idempotency_key: "cm-1" })
    expect(sent.frames.find((f) => f.t === "result" || f.t === "reject")).toMatchObject({ t: "result" })

    // The alarm drains the outbox: projection rows fail (no database in tests) without blocking the UserDO channel.
    await runDurableObjectAlarm(conv)
    const userDO = stub(testEnv.USER_DO, user)
    const list = (await userDO.readInbox(user, me, "inbox.list", { limit: 10 })) as { ok: boolean; value: { entries: Array<{ conversation: string; preview?: string }> } }
    expect(list.ok).toBe(true)
    expect(list.value.entries.map((e) => e.conversation)).toEqual([id])
    expect(list.value.entries[0]!.preview).toContain("hello inbox")

    // History read through the conversation's row table.
    const history = (await conv.readOp(id, me, "conversation.history", { limit: 10 })) as { ok: boolean; value: { messages: Array<{ parts: Array<{ text?: string }> }> } }
    expect(history.ok).toBe(true)
    expect(history.value.messages.at(-1)!.parts[0]!.text).toBe("hello inbox")

    // A second drain does not deliver again (the inbox ledger and max-merge make redelivery a no-op).
    await runDurableObjectAlarm(conv)
    await runInDurableObject(userDO, async (_i, state) => {
      const seq = state.storage.sql.exec("SELECT MAX(seq) AS s FROM inbox_events").toArray()[0]!.s
      expect(seq).toBe(1)
    })
  })

  it("an outsider cannot read the conversation or someone else's inbox", async () => {
    const owner = userIdFor(testEnv.STACK_PROJECT_ID, "home-owner")
    const other = userIdFor(testEnv.STACK_PROJECT_ID, "home-other")
    const id = convId()
    const conv = stub(testEnv.CONVERSATION_DO, id)
    await conv.submit(id, session(owner), { t: "op", op: "conversation.create", params: { id, kind: "group", title: "x", participants: [{ id: owner, kind: "human", display_name: "O" }] }, idempotency_key: "c" })
    expect(((await conv.readOp(id, session(other), "conversation.history", {})) as { ok: boolean }).ok).toBe(false)
    const ownerInbox = stub(testEnv.USER_DO, owner)
    expect(((await ownerInbox.readInbox(owner, session(other), "inbox.list", {})) as { ok: boolean }).ok).toBe(false)
  })

  it("the inbox stream works on the user socket: subscribe gets a snapshot, a bump arrives as an event", async () => {
    const sub = "home-wire"
    const user = userIdFor(testEnv.STACK_PROJECT_ID, sub)
    const token = await stackToken(sub)
    await worker.fetch("https://api.test/v1/ops", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ op: "user.ensure", params: {}, idempotency_key: "ensure" }) })
    const res = await worker.fetch("https://api.test/v1/wire/user", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}` } })
    const ws = res.webSocket!
    const frames: Array<any> = []
    let wake: (() => void) | undefined
    ws.addEventListener("message", (e) => {
      frames.push(JSON.parse(e.data as string))
      wake?.()
    })
    ws.accept()
    const until = async (pred: () => boolean) => {
      while (!pred()) await new Promise<void>((r) => (wake = r))
    }
    ws.send(JSON.stringify({ t: "subscribe", stream: `inbox:${user}`, pending: [] }))
    await until(() => frames.some((f) => f.t === "snapshot" && f.stream === `inbox:${user}`))

    const id = convId()
    const conv = stub(testEnv.CONVERSATION_DO, id)
    await conv.submit(id, session(user), { t: "op", op: "conversation.create", params: { id, kind: "group", title: "Wire", participants: [{ id: user, kind: "human", display_name: "Alice Example" }] }, idempotency_key: "c" })
    await conv.submit(id, session(user), { t: "op", op: "message.send", params: { client_msg_id: "w1", parts: [{ type: "text", text: "over the wire" }] }, idempotency_key: "w1" })
    await runDurableObjectAlarm(conv)
    await until(() => frames.some((f) => f.t === "event" && f.stream === `inbox:${user}` && f.op === "inbox.bump"))
    // The primary stream's events never leak into the inbox subscription and vice versa.
    expect(frames.filter((f) => f.t === "event").every((f) => f.stream === `inbox:${user}`)).toBe(true)
    ws.close()
  })
})

describe("Home objects: the anonymous invite card (ConversationDO.card)", () => {
  const inviteParams = (address: string, n: string) => ({ invite_id: `inv_${"0".repeat(25)}${n}`, address, channel: "email", display_name: "Dana", token_hash: "A".repeat(43), locale: "en", copy_variant: "A" })
  const result = (r: { frames: Array<{ t: string }> }) => r.frames.find((f) => f.t === "result" || f.t === "reject")

  it("answers the inviter's first name while a DM's address peer has an open invite", async () => {
    const user = userIdFor(testEnv.STACK_PROJECT_ID, "home-card-dm")
    const address = `addr_${"0".repeat(25)}7`
    const id = conversation.dmConversationId(user, address)
    const conv = stub(testEnv.CONVERSATION_DO, id)
    const me = session(user)
    const participants = [{ id: user, kind: "human", display_name: "Alice Example" }, { id: address, kind: "address", display_name: "Dana" }]
    expect(result(await conv.submit(id, me, { t: "op", op: "dm.open", params: { id, participants }, idempotency_key: "o" }))).toMatchObject({ t: "result" })
    expect(await conv.card(id)).toBeNull()
    expect(result(await conv.submit(id, me, { t: "op", op: "invite.create", params: inviteParams(address, "7"), idempotency_key: "i" }))).toMatchObject({ t: "result" })
    expect(await conv.card(id)).toEqual({ first_name: "Alice", avatar_url: null })
    // Another conversation's id never answers from this object.
    expect(await conv.card(convId())).toBeNull()
  })

  it("stops answering once the invite is accepted and the DM becomes user-to-user", async () => {
    const a = userIdFor(testEnv.STACK_PROJECT_ID, "home-card-a")
    const b = userIdFor(testEnv.STACK_PROJECT_ID, "home-card-b")
    const address = `addr_${"0".repeat(25)}8`
    const id = conversation.dmConversationId(a, address)
    const conv = stub(testEnv.CONVERSATION_DO, id)
    const participants = [{ id: a, kind: "human", display_name: "Alice Example" }, { id: address, kind: "address", display_name: "Bob" }]
    expect(result(await conv.submit(id, session(a), { t: "op", op: "dm.open", params: { id, participants }, idempotency_key: "o" }))).toMatchObject({ t: "result" })
    const proof = invites.hashInviteSecret("card-secret")
    const create = { ...inviteParams(address, "8"), channel: "sms", token_hash: invites.hashInviteSecret(proof) }
    expect(result(await conv.submit(id, session(a), { t: "op", op: "invite.create", params: create, idempotency_key: "i" }))).toMatchObject({ t: "result" })
    expect(await conv.card(id)).toEqual({ first_name: "Alice", avatar_url: null })
    const bob = { ...session(b), display_name: "Bob" }
    const accepted = result(await conv.submit(id, bob, { t: "op", op: "invite.accept", params: { proof }, idempotency_key: "a" }))
    expect(accepted).toMatchObject({ t: "result" })
    expect(await conv.card(id)).toBeNull()
  })

})

describe("Home objects: ConversationDO subscribers (membership and history_visible)", () => {
  const result = (r: { frames: Array<{ t: string }> }) => r.frames.find((f) => f.t === "result" || f.t === "reject")

  it("a since_join member's snapshot starts at its join, and removal closes its socket", async () => {
    const a = userIdFor(testEnv.STACK_PROJECT_ID, "home-sub-a")
    const b = userIdFor(testEnv.STACK_PROJECT_ID, "home-sub-b")
    const address = `addr_${"0".repeat(25)}9`
    const id = convId()
    const conv = stub(testEnv.CONVERSATION_DO, id)
    const owner = session(a)
    const ok = async (op: string, params: unknown, key: string, who: Principal = owner) =>
      expect(result(await conv.submit(id, who, { t: "op", op, params, idempotency_key: key }))).toMatchObject({ t: "result" })
    await ok("conversation.create", { id, kind: "group", title: "Floor", participants: [{ id: a, kind: "human", display_name: "Alice Example" }] }, "c")
    await ok("conversation.settings.set", { history_visible: "since_join" }, "s")
    await ok("message.send", { client_msg_id: "m1", parts: [{ type: "text", text: "before 1" }] }, "m1")
    await ok("message.send", { client_msg_id: "m2", parts: [{ type: "text", text: "before 2" }] }, "m2")
    const proof = invites.hashInviteSecret("sub-secret")
    await ok("invite.create", { invite_id: `inv_${"0".repeat(25)}9`, address, channel: "sms", display_name: "Bob", token_hash: invites.hashInviteSecret(proof), locale: "en", copy_variant: "A" }, "i")
    const bob = { ...session(b), display_name: "Bob" }
    // A group link used by a user asks the inviter to approve the join.
    await ok("invite.accept", { proof }, "a", bob)
    await ok("invite.approve_join", { invite_id: `inv_${"0".repeat(25)}9` }, "ap")
    await ok("message.send", { client_msg_id: "m3", parts: [{ type: "text", text: "after" }] }, "m3")

    const res = await conv.fetch("https://do/", { headers: { Upgrade: "websocket", "x-cmux-entity": id, "x-cmux-principal": JSON.stringify(bob) } })
    expect(res.status).toBe(101)
    const ws = res.webSocket!
    const frames: Array<any> = []
    let closed: number | undefined
    let wake: (() => void) | undefined
    ws.addEventListener("message", (e) => {
      frames.push(JSON.parse(e.data as string))
      wake?.()
    })
    ws.addEventListener("close", (e) => {
      closed = e.code
      wake?.()
    })
    ws.accept()
    const until = async (pred: () => boolean) => {
      while (!pred()) await new Promise<void>((r) => (wake = r))
    }
    ws.send(JSON.stringify({ t: "subscribe", pending: [] }))
    await until(() => frames.some((f) => f.t === "snapshot"))
    const snap = frames.find((f) => f.t === "snapshot")
    expect(snap.rows.rows.map((r: { row: { parts: Array<{ text: string }> } }) => r.row.parts[0]!.text)).toEqual(["after"])
    // History reads use the same floor (no message at or before the join).
    const history = (await conv.readOp(id, bob, "conversation.history", { limit: 10 })) as { value: { messages: Array<{ parts: Array<{ text: string }> }> } }
    expect(history.value.messages.map((m) => m.parts[0]!.text)).toEqual(["after"])

    // The owner removes Bob: his socket closes, so no later message reaches him.
    await ok("participants.remove", { participant: b }, "r")
    await until(() => closed !== undefined)
    expect(closed).toBe(4401)
  })
})
