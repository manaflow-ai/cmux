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

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace }
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
  await runInDurableObject(stub, (instance: unknown) => {
    ;(instance as { homePushSender: unknown }).homePushSender = async (targets: ReadonlyArray<PushTarget>, message: ApnsMessage): Promise<ReadonlyArray<SendResult>> => {
      sent.push({ tokens: targets.map((t) => t.token), message })
      return targets.map((t) => ({ token: t.token, outcome: "sent" as const, status: 200 }))
    }
  })
  const me: Principal = { kind: "session", identity: `session:${user}`, user }
  return { user, stub, sent, session, me, pushToken }
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

  it("does not notify while the user has a foreground socket", async () => {
    const { user, stub, sent, session } = await pushUser("home-push-foreground")
    const res = await worker.fetch("https://api.test/v1/wire/user", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${session}` } })
    const ws = res.webSocket!
    ws.accept()
    /** Waits until the object recorded the socket's presence (socket frames and RPCs are separate inputs). */
    const presence = async (active: boolean) => {
      ws.send(JSON.stringify({ t: "presence.set", state: { active, client: "ios" } }))
      for (;;) {
        const seen = await runInDurableObject(stub, (_i, state) => state.getWebSockets().some((s) => (s.deserializeAttachment() as { presence?: { active: boolean } } | null)?.presence?.active === active))
        if (seen) return
        await new Promise((r) => setTimeout(r, 5))
      }
    }
    await presence(true)
    await deliver(stub, user, [bump(user, convId())])
    expect(sent).toEqual([])
    // Backgrounded: the next message notifies.
    await presence(false)
    await deliver(stub, user, [bump(user, convId())])
    expect(sent).toHaveLength(1)
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
    await runInDurableObject(none.stub, (instance: unknown) => {
      // The only target is gone (for example dropped after APNs refused it).
      ;(instance as { dropPushTarget(u: string, t: string, r: string): Promise<void> }).dropPushTarget(none.user, none.pushToken, "Unregistered")
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
})
