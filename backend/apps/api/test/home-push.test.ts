import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import type { Principal } from "@cmux/ownership"
import type { PushTarget } from "@cmux/protocol"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import type { ApnsMessage, SendResult } from "../src/push/apns.ts"

/**
 * Home push (home-messaging.md section 5 step 3, home-scale.md B10): the user's UserDO decides
 * push from each delivered `inbox.bump`, queues it once per conversation and seq, and sends
 * through the APNs sender FeedDO uses. A fake sender replaces APNs inside the object.
 */

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; FEED_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const call = async (path: string, token: string | undefined, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) })
  return { status: res.status, json: (await res.json()) as any }
}
const b64u = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

const stackToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))

interface Sent {
  readonly tokens: ReadonlyArray<string>
  readonly message: ApnsMessage
}

type UserStub = DurableObjectStub & {
  systemDeliver(entity: string, source: string, items: ReadonlyArray<{ id: number; op: string; params: unknown; key: string }>): Promise<{ done: ReadonlyArray<number> }>
  submitInbox(entity: string, principal: Principal, frame: unknown): Promise<{ frames: Array<{ t: string }> }>
  pushTargets(entity: string): Promise<ReadonlyArray<PushTarget>>
}

/** A signed-in user with one iPhone install that registered a push token, and a fake APNs sender in the object. */
const pushUser = async (sub: string) => {
  const session = await stackToken(sub)
  const op = (t: string, name: string, params: unknown) => call("/v1/ops", t, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
  const user = (await op(session, "user.ensure", {})).json.value.id as string
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const install = (await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "ios", name: "iPhone", device_name: "iPhone", platform: "ios" })).json.value.id as string
  const ch = await call("/v1/auth/challenge", undefined, { user, install })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
  const token = (await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig) })).json.access_token as string
  const pushToken = "ab".repeat(32)
  const reg = await op(token, "push.target.register", { token: pushToken, topic: "dev.cmux.ios", environment: "production", device_name: "iPhone" })
  expect(reg.json).toMatchObject({ ok: true })
  const stub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user)) as UserStub
  const sent: Array<Sent> = []
  /** APNs outcomes the fake returns for the next sends, in order; "sent" when empty. */
  const outcomes: Array<SendResult["outcome"]> = []
  await runInDurableObject(stub, (instance: unknown) => {
    ;(instance as { homePushSender: unknown }).homePushSender = async (targets: ReadonlyArray<PushTarget>, message: ApnsMessage): Promise<ReadonlyArray<SendResult>> => {
      sent.push({ tokens: targets.map((t) => t.token), message })
      const outcome = outcomes.shift() ?? "sent"
      return targets.map((t) => ({ token: t.token, outcome, status: outcome === "sent" ? 200 : outcome === "drop_target" ? 410 : 503, ...(outcome === "drop_target" ? { reason: "Unregistered" } : {}) }))
    }
  })
  const me: Principal = { kind: "session", identity: `session:${user}`, user }
  return { user, stub, sent, session, me, pushToken, token, outcomes }
}

const OTHER = "user_bbbbbbbbbbbbbbbbbbbbbbbbbb"
const CHIEF = "agent_cccccccccccccccccccccccccc"
let nextId = 1
let nextConv = 0
const convId = () => `conv_01J00000000000000PUSH${String(nextConv++).padStart(4, "0")}`

/** One `inbox.bump` as a ConversationDO outbox drain delivers it. */
const bump = (user: string, conversation: string, over: Record<string, unknown> = {}) => {
  const params = {
    user,
    conversation,
    rev: 2,
    kind: "dm",
    title: "",
    last_seq: 1,
    last_at: "2026-10-03T10:00:00.000Z",
    preview: "Bob: are you there?",
    dm_peer: OTHER,
    last_author: OTHER,
    last_author_kind: "human",
    joined_seq: 0,
    ...over
  }
  return { id: nextId++, op: "inbox.bump", params, key: `bump:${conversation}:${params.rev}` }
}

/** Runs the object's alarm now (the drain), whether or not the scheduled alarm was set yet. */
const drain = (stub: UserStub) => runInDurableObject(stub, (instance: unknown) => (instance as { alarm(): Promise<void> }).alarm())
/** Runs the Home push drain as if the clock read `at` (collapse window, backoff and hourly budget tests). */
const drainAt = (stub: UserStub, at: number) => runInDurableObject(stub, (instance: unknown) => (instance as { drainHomePush(now: number): Promise<void> }).drainHomePush(at))
const HOUR = 3600_000

const deliver = async (stub: UserStub, user: string, items: ReadonlyArray<ReturnType<typeof bump>>) => {
  const r = await stub.systemDeliver(user, "conv:test", items)
  expect(r.done).toHaveLength(items.length)
  await drain(stub)
}

describe("Home push: UserDO decides from each inbox.bump", () => {
  it("a message from someone else reaches the user's iPhone once, collapsed by conversation", async () => {
    const { user, stub, sent, pushToken } = await pushUser("home-push-basic")
    const conv = convId()
    await deliver(stub, user, [bump(user, conv)])
    expect(sent).toHaveLength(1)
    expect(sent[0]!.tokens).toEqual([pushToken])
    expect(sent[0]!.message.collapseId).toBe(conv)
    const body = JSON.parse(sent[0]!.message.body)
    expect(body.aps.alert.body).toBe("Bob: are you there?")
    expect(body.aps["thread-id"]).toBe(conv)
    expect(body.cmux).toEqual({ home_conversation: conv, seq: 1 })
  })

  it("never notifies the author of the message", async () => {
    const { user, stub, sent } = await pushUser("home-push-author")
    await deliver(stub, user, [bump(user, convId(), { last_author: user })])
    expect(sent).toEqual([])
  })

  it("a muted conversation does not notify", async () => {
    const { user, stub, sent, me } = await pushUser("home-push-muted")
    const conv = convId()
    // The entry exists (an earlier bump the user wrote), then the user mutes it.
    await deliver(stub, user, [bump(user, conv, { rev: 1, last_seq: 1, last_author: user })])
    const muted = await stub.submitInbox(user, me, { t: "op", op: "inbox.mute", params: { conversation: conv, muted: true }, idempotency_key: "mute-1" })
    expect(muted.frames.find((f) => f.t === "result" || f.t === "reject")).toMatchObject({ t: "result" })
    await deliver(stub, user, [bump(user, conv, { rev: 2, last_seq: 2 })])
    expect(sent).toEqual([])
  })

  it("an approval part notifies even when the conversation is muted", async () => {
    const { user, stub, sent, me } = await pushUser("home-push-approval")
    const conv = convId()
    await deliver(stub, user, [bump(user, conv, { rev: 1, last_seq: 1, last_author: user, kind: "chief", title: "Chief", dm_peer: undefined })])
    await stub.submitInbox(user, me, { t: "op", op: "inbox.mute", params: { conversation: conv, muted: true }, idempotency_key: "mute-1" })
    await deliver(stub, user, [bump(user, conv, { rev: 2, last_seq: 2, kind: "chief", title: "Chief", dm_peer: undefined, last_author: CHIEF, last_author_kind: "agent", last_approval: true, preview: "Chief: may I deploy?" })])
    expect(sent).toHaveLength(1)
    expect(JSON.parse(sent[0]!.message.body).aps.category).toBe("HOME_APPROVAL")
  })

  it("waits while the user's Mac is active (FeedDO presence, push_skip_when_mac_active) and notifies once the Mac goes idle", async () => {
    const { user, stub, sent, token } = await pushUser("home-push-foreground")
    const res = await worker.fetch("https://api.test/v1/wire/feed", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}` } })
    const ws = res.webSocket!
    ws.accept()
    const feed = testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName(user))
    /** Waits until FeedDO recorded the socket's presence (socket frames and RPCs are separate inputs). */
    const presence = async (active: boolean, client = "mac") => {
      ws.send(JSON.stringify({ t: "presence.set", stream: `feed:${user}`, state: { active, client } }))
      for (;;) {
        const seen = await runInDurableObject(feed, (_i, state) =>
          state.getWebSockets().some((s) => {
            const p = (s.deserializeAttachment() as { presence?: { active: boolean; client: string } } | null)?.presence
            return p?.active === active && p.client === client
          })
        )
        if (seen) return
        await new Promise((r) => setTimeout(r, 5))
      }
    }
    // An active phone does not hold back the push (only an active Mac, as FeedDO).
    await presence(true, "ios")
    await deliver(stub, user, [bump(user, convId())])
    expect(sent).toHaveLength(1)
    await presence(true)
    const conv = convId()
    await deliver(stub, user, [bump(user, conv)])
    expect(sent).toHaveLength(1)
    // The row waits rather than settling: once the Mac is idle, the same message notifies.
    await presence(false)
    await drainAt(stub, Date.now() + HOUR)
    expect(sent).toHaveLength(2)
    expect(JSON.parse(sent[1]!.message.body).cmux).toEqual({ home_conversation: conv, seq: 1 })
    ws.close()
  })

  it("a retried drain and a coalesced redelivery never notify twice", async () => {
    const { user, stub, sent } = await pushUser("home-push-retry")
    const conv = convId()
    const first = bump(user, conv, { rev: 3, last_seq: 2 })
    await deliver(stub, user, [first])
    // The same item again (the source did not see the ack) and a newer rev of the same message (a coalesced edit).
    await deliver(stub, user, [first])
    await deliver(stub, user, [bump(user, conv, { rev: 4, last_seq: 2, preview: "Bob: are you there? (edited)" })])
    // An older message arriving late changes nothing either.
    await deliver(stub, user, [bump(user, conv, { rev: 2, last_seq: 1 })])
    await drain(stub)
    expect(sent).toHaveLength(1)
  })

  it("skips a user without a push token, a message from before the user joined, and a message already read", async () => {
    const { user, stub, sent } = await pushUser("home-push-skips")
    await deliver(stub, user, [bump(user, convId(), { last_seq: 5, joined_seq: 5, kind: "group", title: "Team", dm_peer: undefined })])
    await deliver(stub, user, [bump(user, convId(), { unread: 0, mentions: 0 })])
    expect(sent).toEqual([])
    const none = await pushUser("home-push-no-token")
    await runInDurableObject(none.stub, async (instance: unknown) => {
      // The only target is gone (for example dropped after APNs refused it).
      await (instance as { dropPushTarget(u: string, t: string, r: string): Promise<void> }).dropPushTarget(none.user, none.pushToken, "Unregistered")
    })
    expect(await none.stub.pushTargets(none.user)).toEqual([])
    await deliver(none.stub, none.user, [bump(none.user, convId())])
    expect(none.sent).toEqual([])
  })

  it("a chief's streamed message does not notify; a mention of the user does (B10)", async () => {
    const { user, stub, sent } = await pushUser("home-push-chief")
    const conv = convId()
    const chief = { kind: "chief", title: "Chief", dm_peer: undefined, last_author: CHIEF, last_author_kind: "agent" }
    await deliver(stub, user, [bump(user, conv, { ...chief, rev: 2, last_seq: 1 })])
    expect(sent).toEqual([])
    await deliver(stub, user, [bump(user, conv, { ...chief, rev: 3, last_seq: 2, last_mention: true })])
    expect(sent).toHaveLength(1)
  })

  it("an approval from a human never notifies through mute (only an agent asks for approval)", async () => {
    const { user, stub, sent, me } = await pushUser("home-push-approval-human")
    const conv = convId()
    await deliver(stub, user, [bump(user, conv, { rev: 1, last_seq: 1, last_author: user })])
    await stub.submitInbox(user, me, { t: "op", op: "inbox.mute", params: { conversation: conv, muted: true }, idempotency_key: "mute-1" })
    await deliver(stub, user, [bump(user, conv, { rev: 2, last_seq: 2, last_approval: true })])
    expect(sent).toEqual([])
  })

  it("the alert shows the queued message, not a later one skipped by the mute", async () => {
    const { user, stub, sent, me } = await pushUser("home-push-approval-text")
    const conv = convId()
    const chief = { kind: "chief", title: "Chief", dm_peer: undefined }
    await deliver(stub, user, [bump(user, conv, { ...chief, rev: 1, last_seq: 1, last_author: user })])
    await stub.submitInbox(user, me, { t: "op", op: "inbox.mute", params: { conversation: conv, muted: true }, idempotency_key: "mute-1" })
    // The approval is queued, then (before the drain) a newer message arrives and is skipped by the mute.
    await stub.systemDeliver(user, "conv:test", [bump(user, conv, { ...chief, rev: 2, last_seq: 2, last_author: CHIEF, last_author_kind: "agent", last_approval: true, preview: "Chief: may I deploy?" })])
    await stub.systemDeliver(user, "conv:test", [bump(user, conv, { ...chief, rev: 3, last_seq: 3, last_author: OTHER, last_author_kind: "human", preview: "Bob: later" })])
    await drain(stub)
    expect(sent).toHaveLength(1)
    const body = JSON.parse(sent[0]!.message.body)
    expect(body.aps.category).toBe("HOME_APPROVAL")
    expect(body.aps.alert.body).toBe("Chief: may I deploy?")
    expect(body.cmux.seq).toBe(2)
  })

  it("a message skipped by the mute stays skipped: a later row change for the same seq after unmute does not notify", async () => {
    const { user, stub, sent, me } = await pushUser("home-push-mute-settles")
    const conv = convId()
    await deliver(stub, user, [bump(user, conv, { rev: 1, last_seq: 1, last_author: user })])
    await stub.submitInbox(user, me, { t: "op", op: "inbox.mute", params: { conversation: conv, muted: true }, idempotency_key: "mute-1" })
    await deliver(stub, user, [bump(user, conv, { rev: 2, last_seq: 2 })])
    await stub.submitInbox(user, me, { t: "op", op: "inbox.mute", params: { conversation: conv, muted: false }, idempotency_key: "mute-2" })
    // A title change bumps the row again; it still describes message 2.
    await deliver(stub, user, [bump(user, conv, { rev: 3, last_seq: 2, title: "Renamed" })])
    expect(sent).toEqual([])
  })

  it("collapses a conversation for 10 s after a push, then sends the newest message", async () => {
    const { user, stub, sent } = await pushUser("home-push-collapse")
    const conv = convId()
    await deliver(stub, user, [bump(user, conv, { rev: 2, last_seq: 1 })])
    expect(sent).toHaveLength(1)
    await deliver(stub, user, [bump(user, conv, { rev: 3, last_seq: 2 }), bump(user, conv, { rev: 4, last_seq: 3, preview: "Bob: third" })])
    expect(sent).toHaveLength(1)
    await drainAt(stub, Date.now() + 5_000)
    expect(sent).toHaveLength(1)
    await drainAt(stub, Date.now() + 10_001)
    expect(sent).toHaveLength(2)
    expect(JSON.parse(sent[1]!.message.body).cmux.seq).toBe(3)
  })

  it("the user's own reply or a full read clears a pending push", async () => {
    const { user, stub, sent } = await pushUser("home-push-clear")
    const replied = convId()
    const read = convId()
    await deliver(stub, user, [bump(user, replied, { rev: 2, last_seq: 1 }), bump(user, read, { rev: 2, last_seq: 1 })])
    expect(sent).toHaveLength(2)
    // Both conversations now have a pending row inside the collapse window.
    await deliver(stub, user, [bump(user, replied, { rev: 3, last_seq: 2 }), bump(user, read, { rev: 3, last_seq: 2, unread: 1, mentions: 0 })])
    await deliver(stub, user, [bump(user, replied, { rev: 4, last_seq: 3, last_author: user }), bump(user, read, { rev: 4, last_seq: 2, unread: 0, mentions: 0 })])
    await drainAt(stub, Date.now() + 60_000)
    expect(sent).toHaveLength(2)
  })

  it("drops a token APNs refuses", async () => {
    const { user, stub, sent, outcomes } = await pushUser("home-push-drop")
    outcomes.push("drop_target")
    await deliver(stub, user, [bump(user, convId())])
    expect(sent).toHaveLength(1)
    expect(await stub.pushTargets(user)).toEqual([])
  })

  it("an APNs retry_later puts the row back with a backoff and sends it once", async () => {
    const { user, stub, sent, outcomes } = await pushUser("home-push-retry-later")
    outcomes.push("retry_later")
    const conv = convId()
    await deliver(stub, user, [bump(user, conv)])
    expect(sent).toHaveLength(1)
    await drainAt(stub, Date.now() + 60_000)
    expect(sent).toHaveLength(2)
    expect(JSON.parse(sent[1]!.message.body).cmux).toEqual({ home_conversation: conv, seq: 1 })
    await drainAt(stub, Date.now() + HOUR)
    expect(sent).toHaveLength(2)
  })

  it("sends at most 60 pushes per hour per user; approvals are exempt; the rest wait for the window (B10)", async () => {
    const { user, stub, sent } = await pushUser("home-push-cap")
    const convs = Array.from({ length: 61 }, () => convId())
    await deliver(stub, user, convs.map((c) => bump(user, c)))
    await drain(stub)
    expect(sent).toHaveLength(60)
    const approval = convId()
    await deliver(stub, user, [bump(user, approval, { kind: "chief", title: "Chief", dm_peer: undefined, last_author: CHIEF, last_author_kind: "agent", last_approval: true })])
    expect(sent).toHaveLength(61)
    expect(JSON.parse(sent[60]!.message.body).aps.category).toBe("HOME_APPROVAL")
    await drainAt(stub, Date.now() + HOUR + 1_000)
    expect(sent).toHaveLength(62)
    expect(JSON.parse(sent[61]!.message.body).cmux.home_conversation).toBe(convs[60])
  })

  it("a throwing Home push drain does not skip the socket-close flush or the KRL notices, and the next wake is still scheduled", async () => {
    const { user, stub } = await pushUser("home-push-wake-isolation")
    // A queued push (delivered, not drained) keeps the object's next wake due.
    expect((await stub.systemDeliver(user, "conv:test", [bump(user, convId())])).done).toHaveLength(1)
    type WakeSteps = { flushCloses(now: number): Promise<void>; deliverKrlNotices(now: number): Promise<void>; drainHomePush(now: number): Promise<void>; alarm(): Promise<void> }
    const ran: Array<string> = []
    let alarm: number | null = 0
    await runInDurableObject(stub, async (instance: unknown, state: DurableObjectState) => {
      const o = instance as WakeSteps
      const flush = o.flushCloses.bind(o)
      const krl = o.deliverKrlNotices.bind(o)
      o.flushCloses = async (now) => (ran.push("flushCloses"), flush(now))
      o.deliverKrlNotices = async (now) => (ran.push("deliverKrlNotices"), krl(now))
      o.drainHomePush = async () => {
        ran.push("drainHomePush")
        throw new Error("drain failed")
      }
      await state.storage.deleteAlarm()
      await o.alarm()
      alarm = await state.storage.getAlarm()
    })
    expect(ran).toEqual(["flushCloses", "drainHomePush", "deliverKrlNotices"])
    expect(alarm).not.toBeNull()
  })
})
