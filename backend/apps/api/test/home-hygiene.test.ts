import { env, exports } from "cloudflare:workers"
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
import { conversation as homeConversation, invites } from "@cmux/home-core"
import type { Principal } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import type { Env } from "../src/env.ts"

/**
 * ConversationDO hygiene (home-messaging.md sections 3, 10 and 20 row 7): typing is an ephemeral
 * broadcast on the conversation socket (never stored, rate limited per participant), and the
 * object's alarm deletes expired messages and expires pending invites through `conversation.sweep`.
 */
const testEnv = env as unknown as Env & { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; HOME_ADDRESS_KEY: string }
const worker = (exports as unknown as { default: Fetcher }).default
type Stub = DurableObjectStub & { submit(e: string, p: Principal, f: unknown): Promise<{ frames: Array<{ t: string; code?: string }> }>; readOp(e: string, p: Principal, op: string, params: unknown): Promise<any>; readInbox(e: string, p: Principal, op: string, params: unknown): Promise<unknown>; homeDmLink(e: string, adder: string, target: string): Promise<{ peer: string | null; consented: boolean } | null> }
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const stub = (ns: any, name: string): Stub => ns.get(ns.idFromName(name))
const DAY = 24 * 3600_000

const sessionToken = async (sub: string, email: string, name: string) =>
  new SignJWT({ email, email_verified: true, name })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const op = async (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => {
  const res = await worker.fetch("https://api.test/v1/ops", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ op: name, params, idempotency_key: key, origin: "user" }) })
  return (await res.json()) as any
}
const signIn = async (sub: string, email: string, name: string) => {
  const token = await sessionToken(sub, email, name)
  expect((await op(token, "user.ensure", {})).ok).toBe(true)
  return { token, user: userIdFor(testEnv.STACK_PROJECT_ID, sub) }
}
const session = (user: string): Principal => ({ kind: "session", identity: `session:${user}`, user, team: personalTeamIdFor(user), display_name: "Alice Example", email: "a@example.com", email_verified: true })

/** Alice's group with Bob, who joined through a group email invite to his verified address. */
const twoPersonGroup = async (tag: string) => {
  const alice = await signIn(`home-hy-${tag}-alice`, `hy-alice-${tag}@example.com`, "Alice Example")
  const bob = await signIn(`home-hy-${tag}-bob`, `hy-bob-${tag}@example.com`, "Bob Example")
  const created = await op(alice.token, "conversation.create", { title: "Plans", participants: [{ id: alice.user, kind: "human", display_name: "Alice Example" }] })
  const id = created.value.conversation.id as string
  expect((await op(alice.token, "invite.create", { conversation: id, address: { email: `hy-bob-${tag}@example.com` }, display_name: "Bob" })).ok).toBe(true)
  const address = invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizeEmail(`hy-bob-${tag}@example.com`) as invites.Address)
  const secret = await runInDurableObject(stub(testEnv.ADDRESS_DO, address), async (_i, state) => String(state.storage.sql.exec("SELECT secret FROM address_secrets").toArray()[0]!.secret))
  expect((await op(bob.token, "invite.accept", { code: invites.linkCode(id), secret })).ok).toBe(true)
  return { alice, bob, id }
}

/** A conversation socket with a frame log and a wait for the next frame that matches. */
const connect = async (id: string, token: string) => {
  const res = await worker.fetch(`https://api.test/v1/wire/conv/${id}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}` } })
  expect(res.status).toBe(101)
  const ws = res.webSocket!
  const frames: Array<any> = []
  let wake: (() => void) | undefined
  ws.addEventListener("message", (e) => {
    frames.push(JSON.parse(e.data as string))
    wake?.()
  })
  ws.accept()
  const until = async (match: (f: any) => boolean, from = 0) => {
    for (;;) {
      const i = frames.findIndex((f, n) => n >= from && match(f))
      if (i >= 0) return i
      await new Promise<void>((r) => (wake = r))
    }
  }
  ws.send(JSON.stringify({ t: "subscribe" }))
  await until((f) => f.t === "snapshot")
  return { ws, frames, until, send: (frame: unknown) => ws.send(JSON.stringify(frame)) }
}
const isTyping = (f: any) => f.t === "conversation-typing"

describe("Home typing: ephemeral broadcast on the conversation socket", { timeout: 20_000 }, () => {
  it("reaches the other participant's socket, not the sender's, and is never stored", async () => {
    const { alice, bob, id } = await twoPersonGroup("typing")
    const conv = stub(testEnv.CONVERSATION_DO, id)
    const counts = () => runInDurableObject(conv, async (_i, state) => ({
      events: Number(state.storage.sql.exec("SELECT COUNT(*) AS n FROM own_events").toArray()[0]!.n),
      ledger: Number(state.storage.sql.exec("SELECT COUNT(*) AS n FROM own_ledger").toArray()[0]!.n),
      outbox: Number(state.storage.sql.exec("SELECT COUNT(*) AS n FROM own_outbox").toArray()[0]!.n)
    }))
    const a = await connect(id, alice.token)
    const b = await connect(id, bob.token)
    const before = await counts()
    a.send({ t: "typing", on: true })
    const got = b.frames[await b.until(isTyping)]
    expect(got).toEqual({ t: "conversation-typing", conversation: id, participant: alice.user, on: true })
    // The sender's own socket gets no echo (a later snapshot proves the order).
    a.send({ t: "snapshot.request" })
    const snap = await a.until((f) => f.t === "snapshot", 1)
    expect(a.frames.slice(0, snap).some(isTyping)).toBe(false)
    a.send({ t: "typing", on: false })
    const off = await b.until((f) => isTyping(f) && f.on === false)
    expect(b.frames[off].participant).toBe(alice.user)
    expect(await counts()).toEqual(before)
    // A typing frame with no boolean `on` is refused on the socket.
    a.send({ t: "typing", on: "yes" })
    expect(a.frames[await a.until((f) => f.t === "error")].code).toBe("validation.invalid")
    a.ws.close()
    b.ws.close()
  })

  it("is rate limited per participant: repeated `on` collapses, and at most 5 `on` broadcasts per 10 s", async () => {
    const { alice, bob, id } = await twoPersonGroup("typing-rate")
    const a = await connect(id, alice.token)
    const b = await connect(id, bob.token)
    // Repeats of the same state within the refresh interval are dropped.
    for (let i = 0; i < 4; i++) a.send({ t: "typing", on: true })
    a.send({ t: "typing", on: false })
    await b.until((f) => isTyping(f) && f.on === false)
    expect(b.frames.filter(isTyping).map((f) => f.on)).toEqual([true, false])
    // Fast toggles: `on` is capped; an `off` passes only after a broadcast `on`.
    for (let i = 0; i < 10; i++) {
      a.send({ t: "typing", on: true })
      a.send({ t: "typing", on: false })
    }
    // A message frame after the burst: everything Bob gets before its event was sent before it.
    a.send({ t: "op", op: "message.send", params: { client_msg_id: "after", parts: [{ type: "text", text: "after" }] }, idempotency_key: "after" })
    const sent = await b.until((f) => f.t === "event" && f.op === "message.send")
    const typing = b.frames.slice(0, sent).filter(isTyping).map((f) => f.on)
    // 1 on in the first round (plus its off), then 4 more ons before the cap of 5.
    expect(typing).toEqual([true, false, true, false, true, false, true, false, true, false])
    a.ws.close()
    b.ws.close()
  })

  it("a sender whose socket closes while typing is turned off for the others", async () => {
    const { alice, bob, id } = await twoPersonGroup("typing-close")
    const a = await connect(id, alice.token)
    const b = await connect(id, bob.token)
    a.send({ t: "typing", on: true })
    await b.until((f) => isTyping(f) && f.on === true)
    a.ws.close(1000, "bye")
    const off = await b.until((f) => isTyping(f) && f.on === false)
    expect(b.frames[off]).toEqual({ t: "conversation-typing", conversation: id, participant: alice.user, on: false })
    b.ws.close()
  })
})

let n = 0
const convId = () => `conv_01J0000000000000000HYGN${String(n++).padStart(2, "0")}`.slice(0, 31)

describe("Home retention and invite expiry: the ConversationDO alarm sweeps", { timeout: 60_000 }, () => {
  it("deletes messages older than retention_days in the alarm and projects one delete_through row", async () => {
    const user = userIdFor(testEnv.STACK_PROJECT_ID, "home-retention")
    const id = convId()
    const conv = stub(testEnv.CONVERSATION_DO, id)
    const me = session(user)
    const created = await conv.submit(id, me, { t: "op", op: "conversation.create", params: { id, kind: "group", title: "Kept 30 days", retention_days: 30, participants: [{ id: user, kind: "human", display_name: "Alice Example" }] }, idempotency_key: "create" })
    expect(created.frames.find((f) => f.t === "result" || f.t === "reject")).toMatchObject({ t: "result" })
    for (const key of ["old-1", "old-2", "new-1"]) await conv.submit(id, me, { t: "op", op: "message.send", params: { client_msg_id: key, parts: [{ type: "text", text: key }] }, idempotency_key: key })
    // Age the first two messages past the window (the reducer reads created_at from the rows).
    const aged = new Date(Date.now() - 40 * DAY).toISOString()
    await runInDurableObject(conv, async (_i, state) => {
      for (const row of state.storage.sql.exec<{ k: string; json: string }>("SELECT k, json FROM own_rows WHERE tbl = 'msg'").toArray()) {
        const message = JSON.parse(row.json) as homeConversation.Message
        if (message.client_msg_id.startsWith("old-")) state.storage.sql.exec("UPDATE own_rows SET json = ? WHERE tbl = 'msg' AND k = ?", JSON.stringify({ ...message, created_at: aged }), row.k)
      }
    })
    await runDurableObjectAlarm(conv)
    const history = await conv.readOp(id, me, "conversation.history", { limit: 10 })
    expect(history.value.messages.map((m: homeConversation.Message) => m.client_msg_id)).toEqual(["new-1"])
    await runInDurableObject(conv, async (_i, state) => {
      const rows = state.storage.sql.exec<{ kind: string; payload: string }>("SELECT kind, payload FROM own_outbox WHERE kind LIKE 'home.message.delete%'").toArray()
      expect(rows.map((r) => [r.kind, JSON.parse(r.payload)])).toEqual([["home.message.delete_through", { conversation_id: id, seq: 2 }]])
      const keys = state.storage.sql.exec<{ k: string }>("SELECT k FROM own_rows WHERE tbl = 'msgkey'").toArray().map((r) => r.k)
      expect(keys).toEqual([`${user}:new-1`])
      // The sweep is an event like any commit, so mirrors drop the rows too.
      const sweep = state.storage.sql.exec<{ effects: string }>("SELECT effects FROM own_events WHERE op = 'conversation.sweep'").toArray()
      expect(sweep).toHaveLength(1)
      const writes = (JSON.parse(sweep[0]!.effects) as { writes: Array<{ table: string; op: string }> }).writes
      expect(writes.filter((w) => w.table === "msg" && w.op === "delete")).toHaveLength(2)
    })
  })

  it("lowered counts reach the person's inbox: the sweep's bump replaces the stored entry's unread and mentions", async () => {
    const tag = "lowered"
    const alice = await signIn(`home-hy-${tag}-alice`, `hy-alice-${tag}@example.com`, "Alice Example")
    const bob = await signIn(`home-hy-${tag}-bob`, `hy-bob-${tag}@example.com`, "Bob Example")
    const created = await op(alice.token, "conversation.create", { title: "Kept 30 days", retention_days: 30, participants: [{ id: alice.user, kind: "human", display_name: "Alice Example" }] })
    const id = created.value.conversation.id as string
    expect((await op(alice.token, "invite.create", { conversation: id, address: { email: `hy-bob-${tag}@example.com` }, display_name: "Bob" })).ok).toBe(true)
    const address = invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizeEmail(`hy-bob-${tag}@example.com`) as invites.Address)
    const secret = await runInDurableObject(stub(testEnv.ADDRESS_DO, address), async (_i, state) => String(state.storage.sql.exec("SELECT secret FROM address_secrets").toArray()[0]!.secret))
    expect((await op(bob.token, "invite.accept", { code: invites.linkCode(id), secret })).ok).toBe(true)
    const mention = { type: "text", text: "hey Bob", runs: [{ start: 4, length: 3, mention: bob.user }] }
    expect((await op(alice.token, "message.send", { conversation: id, client_msg_id: "old-1", parts: [mention] }, "old-1")).ok).toBe(true)
    expect((await op(alice.token, "message.send", { conversation: id, client_msg_id: "new-1", parts: [{ type: "text", text: "still here" }] }, "new-1")).ok).toBe(true)
    const conv = stub(testEnv.CONVERSATION_DO, id)
    const inboxEntry = async () => {
      const list = (await stub(testEnv.USER_DO, bob.user).readInbox(bob.user, session(bob.user), "inbox.list", { limit: 10 })) as { ok: boolean; value: { entries: Array<{ conversation: string; unread: number; mentions: number; preview?: string }> } }
      expect(list.ok).toBe(true)
      return list.value.entries.find((e) => e.conversation === id)
    }
    // The runtime may also fire the alarm on its own: drain until the entry shows the counts (bounded).
    const drainUntil = async (match: (e: { unread: number; mentions: number } | undefined) => boolean) => {
      for (let i = 0; i < 50; i++) {
        await runDurableObjectAlarm(conv)
        const entry = await inboxEntry()
        if (match(entry)) return entry
        await new Promise((r) => setTimeout(r, 20))
      }
      return inboxEntry()
    }
    expect(await drainUntil((e) => e?.unread === 2)).toMatchObject({ unread: 2, mentions: 1 })
    // Age the mention past the window; the alarm sweeps it and drains the bump to Bob's UserDO.
    const aged = new Date(Date.now() - 40 * DAY).toISOString()
    await runInDurableObject(conv, async (_i, state) => {
      for (const row of state.storage.sql.exec<{ k: string; json: string }>("SELECT k, json FROM own_rows WHERE tbl = 'msg'").toArray()) {
        const message = JSON.parse(row.json) as homeConversation.Message
        if (message.client_msg_id === "old-1") state.storage.sql.exec("UPDATE own_rows SET json = ? WHERE tbl = 'msg' AND k = ?", JSON.stringify({ ...message, created_at: aged }), row.k)
      }
    })
    expect(await drainUntil((e) => e?.unread !== 2)).toMatchObject({ unread: 1, mentions: 0, preview: expect.stringContaining("still here") })
  })

  it("a DM from before the consent markers keeps the pair connected after the sweep deletes its msgkey rows", async () => {
    const alice = userIdFor(testEnv.STACK_PROJECT_ID, "home-hy-consent-alice")
    const bob = userIdFor(testEnv.STACK_PROJECT_ID, "home-hy-consent-bob")
    const id = homeConversation.dmConversationId(alice, bob)
    const conv = stub(testEnv.CONVERSATION_DO, id)
    const reach: homeConversation.HumanReach = { user: bob, display_name: "Bob Example", shared_team: true, connected: false, allow_requests_from: "anyone" }
    const asAlice: Principal = { ...session(alice), home_reach: [reach] }
    const asBob: Principal = { ...session(bob), display_name: "Bob Example", email: "b@example.com" }
    const opened = await conv.submit(id, asAlice, { t: "op", op: "dm.open", params: { id, retention_days: 30, participants: [{ id: alice, kind: "human", display_name: "Alice Example" }, { id: bob, kind: "human", display_name: "Bob Example" }] }, idempotency_key: "open" })
    expect(opened.frames.find((f) => f.t === "result" || f.t === "reject")).toMatchObject({ t: "result" })
    for (const [who, key] of [[asAlice, "a-old"], [asBob, "b-old"]] as const) {
      const sent = await conv.submit(id, who, { t: "op", op: "message.send", params: { client_msg_id: key, parts: [{ type: "text", text: key }] }, idempotency_key: key })
      expect(sent.frames.find((f) => f.t === "result" || f.t === "reject")).toMatchObject({ t: "result" })
    }
    // A DM from before the markers: msgkey rows only. Age both messages past the window.
    const aged = new Date(Date.now() - 40 * DAY).toISOString()
    await runInDurableObject(conv, async (_i, state) => {
      state.storage.sql.exec("DELETE FROM own_rows WHERE tbl = 'consent'")
      for (const row of state.storage.sql.exec<{ k: string; json: string }>("SELECT k, json FROM own_rows WHERE tbl = 'msg'").toArray()) {
        state.storage.sql.exec("UPDATE own_rows SET json = ? WHERE tbl = 'msg' AND k = ?", JSON.stringify({ ...(JSON.parse(row.json) as homeConversation.Message), created_at: aged }), row.k)
      }
    })
    // The runtime may already have fired the alarm on its own; this runs any sweep still due.
    await runDurableObjectAlarm(conv)
    await runInDurableObject(conv, async (_i, state) => {
      expect(state.storage.sql.exec("SELECT k FROM own_rows WHERE tbl = 'msgkey'").toArray()).toEqual([])
      expect(state.storage.sql.exec<{ k: string }>("SELECT k FROM own_rows WHERE tbl = 'consent' ORDER BY k").toArray().map((r) => r.k)).toEqual([alice, bob].sort())
    })
    expect(await conv.homeDmLink(id, alice, bob)).toMatchObject({ consented: true })
  })

  it("schedules the alarm for the earliest due work: an open invite's expiry", async () => {
    const alice = await signIn("home-hy-expiry-alice", "hy-expiry@example.com", "Alice Example")
    const opened = await op(alice.token, "dm.open", { peer: { email: "hy-expiry-dana@example.com" } }, "dm-expiry")
    const id = opened.value.conversation.id as string
    const conv = stub(testEnv.CONVERSATION_DO, id)
    await runInDurableObject(conv, async (instance, _state) => {
      const engine = (instance as any).boundEngine
      const head = engine.currentState as homeConversation.ConversationHead
      const invite = head.invites!.find((i) => i.status === "pending")!
      expect((instance as any).nextWakeAt(head, Date.now())).toBe(Date.parse(invite.expires_at))
    })
  })
})
