import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { afterEach, describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * A turn never waits on the compactor (parity run 2026-10-16: 48 of 52 turns waited the full 60 s
 * while a rate-limited compactor failed). With the compactor hanging on every call, a person's
 * messages are still answered at once, on the frozen view plus the delta (OptChat 5a): each run's
 * wake path (admitted -> settled) stays under a second. Fake model, real Worker boundary.
 */
const testEnv = env as unknown as Record<string, any>
const worker = (exports as unknown as { default: Fetcher }).default
const sessionToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const http = async (method: string, path: string, token: string, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method, headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  return { status: res.status, json: (await res.json()) as any }
}
const op = async (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => (await http("POST", "/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })).json
const history = async (token: string, conversation: string) => (await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation, limit: 50 } })).json.value.messages as Array<any>
afterEach(() => void delete testEnv.CHIEF_BRAIN_VIEW_BUDGET)

describe("a Cloud Chief turn never waits on the compactor", { timeout: 120_000 }, () => {
  it("answers each message at once while the compactor hangs", async () => {
    // The compactor hangs on these notes (the fake's HANG_COMPACT: 45 s per call, as a rate-limited one).
    // A small view budget (test only): every turn's view needs the compactor to fold, as a view near 128 KB does.
    testEnv.CHIEF_BRAIN_VIEW_BUDGET = "400"
    const token = await sessionToken("brain-nowait")
    const user = (await op(token, "user.ensure", {})).value.id as string
    const chief = (await op(token, "chief.create", { display_name: "Fast Chief" }, "chief-nowait")).value as { id: string; main_conversation: string }
    const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
    let on = { status: 0, json: {} as any }
    for (let i = 0; i < 20 && on.status !== 200; i++) [await fireAlarm(userDO), (on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true }))]
    expect(on.status).toBe(200)
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(chief.main_conversation))
    for (const [n, text] of ["first: HANG_COMPACT a long team note ".repeat(30), "second: HANG_COMPACT another long note ".repeat(30), "third question"].entries()) {
      const t0 = Date.now()
      expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: `nw-${n}`, parts: [{ type: "text", text }] }, `nw-${n}`)).ok).toBe(true)
      for (let i = 0; i < 300 && (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id).length <= n; i++) [await fireAlarm(conv), await new Promise((r) => setTimeout(r, 20))]
      expect((await history(token, chief.main_conversation)).filter((m) => m.author === chief.id).length, `reply ${n}`).toBe(n + 1)
      // Before: the second and third turns waited SETTLE_MS (60 s) for the failing compactor.
      expect(Date.now() - t0).toBeLessThan(20_000)
    }
    const runs = (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, token)).json.value.runs as Array<any>
    expect(runs).toHaveLength(3)
    for (const r of runs) expect(r.timing.settled_at - r.timing.admitted_at, JSON.stringify(r.timing)).toBeLessThan(1_000)
  })
})
