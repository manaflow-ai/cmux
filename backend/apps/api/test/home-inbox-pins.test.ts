import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { invites } from "@cmux/home-core"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * The person's own pins and "marked unread" in the Home list over HTTP (`inbox.pin`,
 * `inbox.mark_unread` on the caller's UserDO inbox, read back by `inbox.list`): the Channels view's
 * Cloud path (the daemon's `cloud-inbox-op` forwards these ops). Two people in one group: each one's
 * pins and marks are their own; pinned entries list first in pin order; nobody else's change shows.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; HOME_ADDRESS_KEY: string; ADDRESS_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace }
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
/** An inbox op exactly as the daemon's `cloud-inbox-op` sends it: `{op, params, idempotency_key}`, no origin. */
const inboxOp = (token: string, name: string, params: unknown) => call("/v1/ops", token, { op: name, params, idempotency_key: crypto.randomUUID() })
const signIn = async (sub: string, email: string, name: string) => {
  const token = await sessionToken(sub, email, name)
  expect((await op(token, "user.ensure", {})).json.ok).toBe(true)
  return { token, user: userIdFor(testEnv.STACK_PROJECT_ID, sub) }
}
const conversationDO = (id: string) => testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id))

type Entry = { conversation: string; pinned: boolean; pin_position?: number; marked_unread: boolean }
const list = async (token: string) => (await read(token, "inbox.list", { limit: 50 })).json.value.entries as Array<Entry>
/** The caller's inbox once every conversation in `ids` has its entry (the ConversationDO outbox drain). */
const inboxWith = async (token: string, ids: ReadonlyArray<string>) => {
  for (let attempt = 0; attempt < 50; attempt++) {
    const entries = await list(token)
    if (ids.every((id) => entries.some((e) => e.conversation === id))) return entries
    for (const id of ids) await fireAlarm(conversationDO(id))
  }
  throw new Error(`inbox never listed ${ids.join(", ")}`)
}

describe("Home list pins and marks over HTTP (the person's own inbox)", { timeout: 60_000 }, () => {
  it("each person's pins and marks are their own; pinned entries list first in pin order", async () => {
    const alice = await signIn("home-pins-alice", "alice-pins@example.com", "Alice Example")
    const bob = await signIn("home-pins-bob", "bob-pins@example.com", "Bob Example")
    // A group with Bob (he joins through a group email invite), and a room only Alice is in.
    const created = await op(alice.token, "conversation.create", { title: "Plans", participants: [{ id: alice.user, kind: "human", display_name: "Alice Example" }] })
    expect(created.json.ok).toBe(true)
    const shared = created.json.value.conversation.id as string
    expect((await op(alice.token, "invite.create", { conversation: shared, address: { email: "bob-pins@example.com" }, display_name: "Bob" })).json.ok).toBe(true)
    const address = invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizeEmail("bob-pins@example.com") as invites.Address)
    const stash = testEnv.ADDRESS_DO.get(testEnv.ADDRESS_DO.idFromName(address))
    const secret = await runInDurableObject(stash, async (_i, state) => String(state.storage.sql.exec("SELECT secret FROM address_secrets").toArray()[0]!.secret))
    expect((await op(bob.token, "invite.accept", { code: invites.linkCode(shared), secret })).json.ok).toBe(true)
    const solo = (await op(alice.token, "conversation.create", { title: "Notes", participants: [{ id: alice.user, kind: "human", display_name: "Alice Example" }] })).json.value.conversation.id as string
    expect((await op(alice.token, "message.send", { conversation: shared, client_msg_id: "m1", parts: [{ type: "text", text: "hi" }] }, "m1")).json.ok).toBe(true)
    await inboxWith(alice.token, [shared, solo])
    await inboxWith(bob.token, [shared])

    // Alice pins both at the pin times her client chose: the later pin lists second.
    const t = 1_791_970_000_000
    const pinned = await inboxOp(alice.token, "inbox.pin", { conversation: solo, pinned: true, position: t })
    expect(pinned.json.ok, JSON.stringify(pinned.json)).toBe(true)
    expect(pinned.json.value).toMatchObject({ conversation: solo, pinned: true, pin_position: t })
    expect((await inboxOp(alice.token, "inbox.pin", { conversation: shared, pinned: true, position: t + 1 })).json.ok).toBe(true)
    let mine = await list(alice.token)
    expect(mine.slice(0, 2).map((e) => [e.conversation, e.pinned, e.pin_position])).toEqual([
      [solo, true, t],
      [shared, true, t + 1]
    ])
    // Bob shares the group but not Alice's pin.
    const bobs = (await list(bob.token)).find((e) => e.conversation === shared)!
    expect(bobs.pinned).toBe(false)
    expect(bobs.pin_position).toBeUndefined()

    // Marked unread: Alice's flag only; the read cursor stays.
    const marked = await inboxOp(alice.token, "inbox.mark_unread", { conversation: shared, unread: true })
    expect(marked.json.value).toMatchObject({ conversation: shared, marked_unread: true, pinned: true })
    expect((await list(bob.token)).find((e) => e.conversation === shared)!.marked_unread).toBe(false)

    // Unpinned: no position, and it falls back among the unpinned entries.
    expect((await inboxOp(alice.token, "inbox.pin", { conversation: solo, pinned: false })).json.value).toMatchObject({ conversation: solo, pinned: false })
    mine = await list(alice.token)
    expect(mine[0]!.conversation).toBe(shared)
    const unpinned = mine.find((e) => e.conversation === solo)!
    expect(unpinned.pinned).toBe(false)
    expect(unpinned.pin_position).toBeUndefined()

    // A conversation Bob is not in has no entry in his inbox; a negative position is refused.
    expect((await inboxOp(bob.token, "inbox.pin", { conversation: solo, pinned: true })).json.ok).toBe(false)
    expect((await inboxOp(alice.token, "inbox.pin", { conversation: shared, pinned: true, position: -1 })).json.ok).toBe(false)
  })
})
