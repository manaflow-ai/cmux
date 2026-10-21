import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Pruning pi-durable's entry log (chief-brain/pi-prune.ts, CHIEF_BRAIN_PRUNE_PI): after several
 * turns the brain object keeps only the entries of the latest pi context, so storage stops growing
 * with the turn count; and a turn whose object restarts in the middle (state.abort) resumes and
 * answers. Fake model, real Worker boundary.
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

describe("a Cloud Chief brain prunes old pi entries", { timeout: 180_000 }, () => {
  it("keeps only the latest context's entries across turns, and a turn restarted mid-way still answers", async () => {
    const token = await sessionToken("brain-prune")
    const user = (await op(token, "user.ensure", {})).value.id as string
    const chief = (await op(token, "chief.create", { display_name: "Prune Chief" }, "chief-prune")).value as { id: string; main_conversation: string }
    const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
    let on = { status: 0, json: {} as any }
    for (let i = 0; i < 20 && on.status !== 200; i++) [await fireAlarm(userDO), (on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true }))]
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(chief.main_conversation))
    // A stub is broken after its object resets: take a new one each time.
    const brainStub = () => testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${chief.id}/${chief.main_conversation}`))
    let brain = brainStub()
    const entries = () => runInDurableObject(brain, async (_i: unknown, s: DurableObjectState) => Number(s.storage.sql.exec(`SELECT COUNT(*) AS n FROM pi_entries`).one().n))
    const answered = async (n: number) => {
      for (let i = 0; i < 400 && (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id).length < n; i++) [await fireAlarm(conv), i % 10 === 9 && (await fireAlarm(brain).catch(() => (brain = brainStub()))), await new Promise((r) => setTimeout(r, 25))]
      return (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)
    }
    const counts: Array<number> = []
    for (let n = 1; n <= 5; n++) {
      expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: `p${n}`, parts: [{ type: "text", text: `question ${n}` }] }, `p${n}`)).ok).toBe(true)
      expect((await answered(n)).length).toBe(n)
      counts.push(await entries())
    }
    // Bounded: the log no longer grows with every turn (two contexts at most stay: the previous and the current).
    expect(counts[4], JSON.stringify(counts)).toBeLessThanOrEqual(counts[1]! + 2)
    // A turn restarted in the middle (the object is reset while the model streams) resumes and answers.
    expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: "p6", parts: [{ type: "text", text: `SLOW question six ${"word ".repeat(30)}` }] }, "p6")).ok).toBe(true)
    for (let i = 0; i < 200; i++) {
      const running = await runInDurableObject(brain, async (_i: unknown, s: DurableObjectState) => s.storage.sql.exec(`SELECT COUNT(*) AS n FROM cb_turn WHERE status = 'running' AND submitted = 1`).one().n)
      if (Number(running) > 0) break
      await fireAlarm(conv)
      await new Promise((r) => setTimeout(r, 20))
    }
    await runInDurableObject(brain, async (_i: unknown, s: DurableObjectState) => {
      try {
        s.abort("test: restart mid-turn")
      } catch {}
    }).catch(() => undefined)
    brain = brainStub()
    await new Promise((r) => setTimeout(r, 50))
    const after = await answered(6)
    expect(after.at(-1)!.parts[0].text).toContain("question six")
    const run = (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, token)).json.value.runs[0]
    expect(run.status).toBe("done")
  })
})
