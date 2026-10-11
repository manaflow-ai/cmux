import { env, exports } from "cloudflare:workers"
import { runInDurableObject as runIn } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"

/**
 * home-scale review P2 (shipped bug): a client could name any conversation id, and OwnerDO.bind()
 * wrote storage for it, so a client could make an unlimited number of empty objects. Ids are
 * validated in the Worker, and a read or a refused op on an object that does not exist writes nothing.
 */
const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; CONVERSATION_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const token = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const post = async (path: string, t: string, body: unknown) =>
  (await (await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) })).json()) as any
const tables = (stub: unknown) =>
  runInDurableObject(stub, async (_i, state) => (state.storage.sql.exec(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE '\\_cf\\_%' ESCAPE '\\' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'`).toArray() as Array<{ name: string }>).map((r) => r.name))

describe("no storage for objects that do not exist", { timeout: 60_000 }, () => {
  it("refuses a malformed conversation id in the Worker", async () => {
    const t = await token("unbound-1")
    await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: "e", origin: "user" })
    const read = await post("/v1/read", t, { op: "conversation.history", params: { conversation: "anything-at-all" } })
    expect(read.error?.code ?? read.code).toBe("validation.invalid")
    const send = await post("/v1/ops", t, { op: "message.send", params: { conversation: "conv_lowercase_is_not_crockford_x", body: "hi" }, idempotency_key: "s", origin: "user" })
    expect(JSON.stringify(send)).toContain("validation.invalid")
  })

  it("a read or a refused op on a well-formed unknown id writes nothing", async () => {
    const t = await token("unbound-2")
    await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: "e", origin: "user" })
    const id = "conv_0000000000000000000000ZZZZ"
    await post("/v1/read", t, { op: "conversation.history", params: { conversation: id } })
    await post("/v1/ops", t, { op: "message.send", params: { conversation: id, body: "hi" }, idempotency_key: "s2", origin: "user" })
    const stub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id))
    expect(await tables(stub)).toEqual([])
  })

  it("an invite code for an unknown conversation and a stranger's invite.create write nothing (security review P2)", async () => {
    const t = await token("unbound-3")
    await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: "e", origin: "user" })
    const accept = await post("/v1/ops", t, { op: "invite.accept", params: { code: "g0000000000000000000000ZZZZ", secret: "A".repeat(26) }, idempotency_key: "a", origin: "user" })
    expect(JSON.stringify(accept)).toContain("unknown_invite")
    const id = "conv_1111111111111111111111ZZZZ"
    const invite = await post("/v1/ops", t, { op: "invite.create", params: { conversation: id, address: { email: "someone@example.com" }, display_name: "Someone" }, idempotency_key: "i", origin: "user" })
    expect(JSON.stringify(invite)).toContain("forbidden")
    expect(await tables(testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id)))).toEqual([])
  })

  it("attachment intents and URL mints on an unknown conversation write nothing", async () => {
    const t = await token("unbound-4")
    await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: "e", origin: "user" })
    const id = "conv_2222222222222222222222ZZZZ"
    const intent = await post("/v1/home/attachments/intent", t, { conversation: id, sha256: "a".repeat(64), byte_count: 10, mime_type: "image/png", name: "a.png" })
    expect(intent.error.code).toBe("auth.forbidden")
    const url = await post("/v1/home/attachments/url", t, { conversation: id, hash: "a".repeat(64) })
    expect(url.error.code).toBe("auth.forbidden")
    expect(await tables(testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id)))).toEqual([])
  })
})
