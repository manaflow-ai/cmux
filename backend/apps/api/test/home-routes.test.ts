import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { conversation as homeConversation, invites } from "@cmux/home-core"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"

/** Home ops through the public API (stage B): routing by conversation, Worker-derived invites, the anonymous card and preview, accept with its lock, and the conversation socket. */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; HOME_ADDRESS_KEY: string; ADDRESS_DO: DurableObjectNamespace }
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
const call = async (path: string, token: string | undefined, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })
  return { status: res.status, headers: res.headers, json: (await res.json().catch(() => null)) as any }
}
const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })
const read = (token: string, name: string, params: unknown) => call("/v1/read", token, { op: name, params })
const signIn = async (sub: string, email: string, name: string) => {
  const token = await sessionToken(sub, email, name)
  expect((await op(token, "user.ensure", {})).json.ok).toBe(true)
  return { token, user: userIdFor(testEnv.STACK_PROJECT_ID, sub) }
}

describe("Home HTTP routes (stage B)", { timeout: 60_000 }, () => {
  it("create, send and read a group conversation by its id; a retried create reaches the same conversation", async () => {
    const alice = await signIn("home-http-alice", "alice@example.com", "Alice Example")
    const params = { title: "Plans", participants: [{ id: alice.user, kind: "human", display_name: "Alice Example" }] }
    const created = await op(alice.token, "conversation.create", params, "create-1")
    expect(created.json.error).toBeUndefined()
    const id = created.json.value.conversation.id as string
    expect(id).toMatch(/^conv_[0-9A-HJKMNP-TV-Z]{26}$/)
    expect((await op(alice.token, "conversation.create", params, "create-1")).json).toMatchObject({ ok: true, replayed: true })
    expect((await op(alice.token, "message.send", { conversation: id, client_msg_id: "m1", parts: [{ type: "text", text: "hello" }] }, "m1")).json.error).toBeUndefined()
    const history = await read(alice.token, "conversation.history", { conversation: id, limit: 10 })
    expect(history.status).toBe(200)
    expect(history.json.value.messages.map((m: { parts: Array<{ text: string }> }) => m.parts[0]!.text)).toEqual(["hello"])
    const snap = await read(alice.token, "conversation.snapshot", { conversation: id, tail: 1 })
    expect(snap.json.value.rows.rows).toHaveLength(1)
    // Another user is not a participant.
    const bob = await signIn("home-http-bob", "bob@example.com", "Bob")
    expect((await read(bob.token, "conversation.history", { conversation: id })).status).toBe(403)
    expect((await op(bob.token, "message.send", { conversation: id, client_msg_id: "x", parts: [{ type: "text", text: "hi" }] }, "x")).json.ok).toBe(false)
    // Inbox reads go to the caller's own inbox stream.
    const inbox = await read(alice.token, "inbox.list", { limit: 10 })
    expect(inbox.status).toBe(200)
    expect(inbox.json.stream).toBe(`inbox:${alice.user}`)
  })

  it("dm.open with an email invites the address; card, preview and accept work from the link", async () => {
    const alice = await signIn("home-http-dm-alice", "alice2@example.com", "Alice Example")
    const opened = await op(alice.token, "dm.open", { peer: { email: "Dana@Example.com" } }, "dm-1")
    expect(opened.json.ok).toBe(true)
    expect(opened.json.value.invite).toEqual({ ok: true })
    const address = invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizeEmail("dana@example.com") as invites.Address)
    const id = homeConversation.dmConversationId(alice.user, address)
    expect(opened.json.value.conversation.id).toBe(id)
    const code = invites.linkCode(id)

    // The secret exists only in the address's AddressDO stash.
    const stub = testEnv.ADDRESS_DO.get(testEnv.ADDRESS_DO.idFromName(address))
    const secret = await runInDurableObject(stub, async (_i, state) => String(state.storage.sql.exec("SELECT secret FROM address_secrets").toArray()[0]!.secret))
    expect(secret).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/)
    expect(JSON.stringify(opened.json)).not.toContain(secret)

    const card = await call(`/v1/invites/card/${code}`, undefined)
    expect(card.status).toBe(200)
    expect(card.json).toEqual({ first_name: "Alice", avatar_url: null })
    expect((await call(`/v1/invites/card/g${"0".repeat(26)}`, undefined)).status).toBe(404)
    const preview = await call("/v1/invites/preview", undefined, { code, secret })
    expect(preview.json).toMatchObject({ state: "ok", inviter: "Alice", kind: "dm" })
    expect(preview.headers.get("cache-control")).toBe("private, no-store")
    expect((await call("/v1/invites/preview", undefined, { code, secret: "0".repeat(26) })).json).toEqual({ state: "invalid" })

    // Dana signs in with the invited, verified email and accepts; the DM becomes user-to-user and the card stops answering.
    const dana = await signIn("home-http-dana", "dana@example.com", "Dana")
    const accepted = await op(dana.token, "invite.accept", { code, secret })
    expect(accepted.json.ok).toBe(true)
    expect((await call(`/v1/invites/card/${code}`, undefined)).status).toBe(404)
    expect((await read(dana.token, "conversation.history", { conversation: id })).status).toBe(200)

    // The conversation socket admits Dana, refuses an outsider.
    const wire = (token: string) => worker.fetch(`https://api.test/v1/wire/conv/${id}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}` } })
    const ok = await wire(dana.token)
    expect(ok.status).toBe(101)
    ok.webSocket!.accept()
    ok.webSocket!.close()
    const eve = await signIn("home-http-eve", "eve@example.com", "Eve")
    expect((await wire(eve.token)).status).toBe(403)
  })

  it("accept locks after 10 wrong links in an hour", async () => {
    const alice = await signIn("home-http-lock-alice", "alice3@example.com", "Alice Example")
    const opened = await op(alice.token, "dm.open", { peer: { email: "lock@example.com" } }, "dm-lock")
    const code = invites.linkCode(opened.json.value.conversation.id)
    const mallory = await signIn("home-http-mallory", "mallory@example.com", "Mallory")
    for (let i = 0; i < 10; i++) {
      const r = await op(mallory.token, "invite.accept", { code, secret: invites.crockford(crypto.getRandomValues(new Uint8Array(17)), 26) })
      expect(r.json.error.code).toBe("unknown_invite")
    }
    const locked = await op(mallory.token, "invite.accept", { code, secret: invites.crockford(crypto.getRandomValues(new Uint8Array(17)), 26) })
    expect(locked.json.error.code).toBe("accept_locked")
  })
})
