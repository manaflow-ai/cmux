import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"

/**
 * conversation.history paging: `has_more` is true only when older messages exist. A page that is
 * exactly full and holds the oldest message says there is no more (no empty round trip).
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
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
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify(body) })
  return { status: res.status, json: (await res.json().catch(() => null)) as any }
}
const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })
const read = (token: string, name: string, params: unknown) => call("/v1/read", token, { op: name, params })

describe("conversation.history paging", () => {
  it("has_more is false on an exactly full last page and true while older messages exist", async () => {
    const token = await sessionToken("home-history-alice", "alice-history@example.com", "Alice Example")
    expect((await op(token, "user.ensure", {})).json.ok).toBe(true)
    const me = userIdFor(testEnv.STACK_PROJECT_ID, "home-history-alice")
    const created = await op(token, "conversation.create", { title: "Pages", participants: [{ id: me, kind: "human", display_name: "Alice Example" }] })
    expect(created.json.ok).toBe(true)
    const conversation = created.json.value.conversation.id as string
    for (let i = 0; i < 4; i++) {
      const key = crypto.randomUUID()
      expect((await op(token, "message.send", { conversation, client_msg_id: key, parts: [{ type: "text", text: `m${i}` }] }, key)).json.ok).toBe(true)
    }
    const all = await read(token, "conversation.history", { conversation, limit: 4 })
    expect(all.json.value.messages).toHaveLength(4)
    expect(all.json.value.has_more).toBe(false)
    const newest = await read(token, "conversation.history", { conversation, limit: 2 })
    expect(newest.json.value.messages.map((m: { parts: Array<{ text: string }> }) => m.parts[0]!.text)).toEqual(["m2", "m3"])
    expect(newest.json.value.has_more).toBe(true)
    const older = await read(token, "conversation.history", { conversation, limit: 2, before_seq: newest.json.value.messages[0].seq })
    expect(older.json.value.messages.map((m: { parts: Array<{ text: string }> }) => m.parts[0]!.text)).toEqual(["m0", "m1"])
    expect(older.json.value.has_more).toBe(false)
  })
})
