import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { afterEach, describe, expect, it } from "vitest"
import { Memory } from "../src/chief-brain/memory.ts"
import { compactTimes, resetFakeCompacts } from "../src/chief-brain/fake.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Two staging faults of the Cloud Chief's memory (parity run 2026-10-16), at the Worker boundary:
 * - a rate-limited compactor (Workers AI "rate limiting ... rate reached", 12-16k failures per hour)
 *   was retried every 10 s forever; now each failed node backs off exponentially with full jitter
 *   (or waits the Retry-After the error names) and the node is built once the provider answers;
 * - every start folded the whole log (Memory.load, "Worker exceeded memory limit"); now a start
 *   resumes from the saved checkpoint, with the same view, and folds only without one.
 * Fake model; the compactor's first retry delay is small in tests (CHIEF_BRAIN_COMPACT_RETRY_BASE_MS).
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
afterEach(() => [delete testEnv.CHIEF_BRAIN_COMPACT_RETRY_BASE_MS, resetFakeCompacts()])

/** A Chief with its brain on, and a helper that sends one message and waits for the reply. */
const chiefWith = async (sub: string) => {
  const token = await sessionToken(sub)
  const user = (await op(token, "user.ensure", {})).value.id as string
  const chief = (await op(token, "chief.create", { display_name: "Memory Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  let on = { status: 0, json: {} as any }
  for (let i = 0; i < 20 && on.status !== 200; i++) [await fireAlarm(userDO), (on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true }))]
  expect(on.status).toBe(200)
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(chief.main_conversation))
  let sent = 0
  const say = async (text: string) => {
    const n = sent++
    expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: `${sub}-${n}`, parts: [{ type: "text", text }] }, `${sub}-${n}`)).ok).toBe(true)
    for (let i = 0; i < 300 && (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id).length <= n; i++) [await fireAlarm(conv), await new Promise((r) => setTimeout(r, 20))]
  }
  const brain = testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${chief.id}/${chief.main_conversation}`))
  return { say, brain }
}
const built = (brain: unknown, marker: string) =>
  runInDurableObject(brain as DurableObjectStub, async (_i, s) => s.storage.sql.exec(`SELECT COUNT(*) AS n FROM oc_message m JOIN oc_node n ON n.l = 0 AND n.i = m.i WHERE m.kind = 'user' AND m.text LIKE ?`, `%${marker}%`).one().n as number)
const waitBuilt = async (brain: unknown, marker: string, ms: number) => {
  const end = Date.now() + ms
  while (Date.now() < end && (await built(brain, marker)) === 0) await new Promise((r) => setTimeout(r, 50))
  return built(brain, marker)
}

describe("Cloud Chief memory under load", { timeout: 120_000 }, () => {
  it("backs a rate-limited compactor off exponentially with jitter, then builds the node", async () => {
    testEnv.CHIEF_BRAIN_COMPACT_RETRY_BASE_MS = "200"
    const { say, brain } = await chiefWith("mem-ratelimit")
    await say(`RATE_LIMIT_COMPACT a long team note ${"with many details ".repeat(60)}`)
    const done = await waitBuilt(brain, "RATE_LIMIT_COMPACT", 60_000)
    const at = compactTimes.filter((c) => c.marker === "RATE_LIMIT_COMPACT").map((c) => c.at)
    const leaf = await runInDurableObject(brain as DurableObjectStub, async (_i, s) => JSON.stringify(s.storage.sql.exec(`SELECT m.i, m.size, n.l, substr(n.text, 1, 120) AS t FROM oc_message m LEFT JOIN oc_node n ON n.l = 0 AND n.i = m.i ORDER BY m.i`).toArray()))
    expect(done, `compactor calls seen: ${compactTimes.length} ${leaf}`).toBe(1)
    expect(at.length, `calls seen ${compactTimes.length} ${leaf}`).toBeGreaterThanOrEqual(5)
    // 4 refused calls, then the one that built the node (checked above).
    const gaps = at.slice(1, 5).map((t, k) => t - at[k]!)
    // Full jitter: each wait is in [0, 200 * 2^(n-1)] (plus scheduling slack), never the old fixed 10 s.
    gaps.forEach((g, k) => expect(g, JSON.stringify(gaps)).toBeLessThan(200 * 2 ** k + 1_500))
    expect(Math.max(...gaps)).toBeLessThan(10_000)
  })

  it("waits the Retry-After a rate limit names", async () => {
    testEnv.CHIEF_BRAIN_COMPACT_RETRY_BASE_MS = "50"
    const { say, brain } = await chiefWith("mem-retryafter")
    await say(`RETRY_AFTER_COMPACT a long team note ${"with many details ".repeat(60)}`)
    const done = await waitBuilt(brain, "RETRY_AFTER_COMPACT", 60_000)
    const at = compactTimes.filter((c) => c.marker === "RETRY_AFTER_COMPACT").map((c) => c.at)
    expect(done, `compactor calls seen: ${compactTimes.length}`).toBe(1)
    expect(at.length).toBeGreaterThanOrEqual(3)
    // "retry after 1 s": both waits at least about a second, though the base delay is 50 ms.
    // ... and no longer than it said (not the old fixed 10 s).
    for (let k = 1; k < 3; k++) [expect(at[k]! - at[k - 1]!).toBeGreaterThanOrEqual(900), expect(at[k]! - at[k - 1]!).toBeLessThan(5_000)]
  })

  it("resumes the memory from its checkpoint at a start, with the same view; folds only without one", async () => {
    const { say, brain } = await chiefWith("mem-resume")
    for (let k = 0; k < 6; k++) await say(`note ${k}: ${"the build ran on eleven hosts ".repeat(12)}`)
    const result = await (runInDurableObject as any)(brain, async (instance: any, s: DurableObjectState) => {
      const live = instance.memory as Memory
      const view = live.render().text
      // A start (a new object on the same storage): resumed, not folded, and the same view.
      const started = new Memory(s.storage.sql, Number(testEnv.CHIEF_BRAIN_VIEW_BUDGET ?? "0") || 0)
      const resumed = { loaded: started.loaded, same: started.render().text === view, len: started.len() === live.len() }
      // An older store with no checkpoint: folded once, and the checkpoint saved for the next start.
      s.storage.sql.exec(`DELETE FROM oc_checkpoint`)
      const folded = new Memory(s.storage.sql, Number(testEnv.CHIEF_BRAIN_VIEW_BUDGET ?? "0") || 0)
      const again = new Memory(s.storage.sql, Number(testEnv.CHIEF_BRAIN_VIEW_BUDGET ?? "0") || 0)
      return { resumed, folded: folded.loaded, foldedSame: folded.render().text === view, again: again.loaded }
    })
    expect(result.resumed).toEqual({ loaded: "resumed", same: true, len: true })
    expect(result.folded).toBe("folded")
    expect(result.foldedSame).toBe(true)
    expect(result.again).toBe("resumed")
    // The brain still answers after the restart path (its memory appends lazily).
    await say("after the start: one more question")
  })
})
