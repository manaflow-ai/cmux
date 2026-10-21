import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Crash in the middle of a turn (test-only fault hooks, chief-fault.ts), through the product boundary: the
 * owner's DM starts a SLOW turn, the pi brain object of that conversation is evicted while the model streams, and the
 * Chief still answers exactly once (pi-durable resumes the turn; the reply's client_msg_id keeps it single).
 * The opencode target answers 409 where no container runs; only the owner may use the hook.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace; CHIEF_BRAIN_DO: DurableObjectNamespace }
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

const ownerWithChief = async (sub: string) => {
  const token = await sessionToken(sub)
  const user = (await op(token, "user.ensure", {})).value.id as string
  const chief = (await op(token, "chief.create", { display_name: "Fault Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  for (let i = 0; i < 20; i++) {
    await fireAlarm(userDO)
    if ((await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation: chief.main_conversation, limit: 1 } })).status === 200) break
  }
  expect((await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true })).status).toBe(200)
  return { token, chief }
}

/** Sends one DM and waits (bounded) for the Chief's n-th reply. */
const dmAndReply = async (token: string, chief: { id: string; main_conversation: string }, text: string, n: number) => {
  const key = `fault-${text.replace(/[^a-z0-9]+/g, "-")}`
  const sent = await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: key, parts: [{ type: "text", text }] }, key)
  expect(sent.ok, JSON.stringify(sent)).toBe(true)
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(chief.main_conversation))
  for (let i = 0; i < 200; i++) {
    if ((await history(token, chief.main_conversation)).filter((m) => m.author === chief.id).length >= n) return
    await fireAlarm(conv)
    await new Promise((r) => setTimeout(r, 50))
  }
  throw new Error(`no reply ${n} from ${chief.id}`)
}

describe("Chief crash in the middle of a turn", { timeout: 120_000 }, () => {
  it("an evicted pi brain resumes its turn and posts the reply exactly once", async () => {
    const { token, chief } = await ownerWithChief("fault-evict")
    // A SLOW turn (the fake model streams it over a few seconds): fault while it runs, before any reply.
    const key = "fault-mid-turn"
    expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: key, parts: [{ type: "text", text: `SLOW evict me mid turn ${"word ".repeat(30)}` }] }, key)).ok).toBe(true)
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(chief.main_conversation))
    const brainStub = () => testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${chief.id}/${chief.main_conversation}`))
    let brain = brainStub()
    let running = 0
    for (let i = 0; i < 200 && running === 0; i++) {
      running = Number(await runInDurableObject(brain, async (_i: unknown, st: DurableObjectState) => (st.storage.sql.exec(`SELECT name FROM sqlite_master WHERE name = 'cb_turn'`).toArray().length ? st.storage.sql.exec(`SELECT COUNT(*) AS n FROM cb_turn WHERE status = 'running' AND submitted = 1`).one().n : 0)))
      if (running === 0) [await fireAlarm(conv), await new Promise((r) => setTimeout(r, 20))]
    }
    expect(running, "the turn never ran").toBe(1)
    expect((await history(token, chief.main_conversation)).filter((m) => m.author === chief.id), "replied before the fault").toHaveLength(0)
    const f = await http("POST", `/v1/chiefs/${chief.id}/fault`, token, { conversation: chief.main_conversation, target: "brain" })
    expect(f.status, JSON.stringify(f.json)).toBe(200)
    // A reset object takes a new stub; its alarm (lifecycle jobs) resumes the turn.
    brain = brainStub()
    let replies: Array<any> = []
    for (let i = 0; i < 400 && replies.length === 0; i++) {
      replies = (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)
      if (replies.length === 0) [await fireAlarm(conv), i % 10 === 9 && (await fireAlarm(brain).catch(() => (brain = brainStub()))), await new Promise((r) => setTimeout(r, 25))]
    }
    // Let any duplicate land, then count: exactly one reply, one run, done and posted under the run's key.
    for (let i = 0; i < 20; i++) [await fireAlarm(conv), await fireAlarm(brain).catch(() => (brain = brainStub())), await new Promise((r) => setTimeout(r, 25))]
    replies = (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)
    expect(replies, JSON.stringify(replies.map((m) => m.parts[0]?.text))).toHaveLength(1)
    expect(replies[0].parts[0].text).toContain("evict me mid turn")
    const runs = (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, token)).json.value.runs
    expect(runs).toHaveLength(1)
    expect(runs[0]).toMatchObject({ status: "done", reply: { state: "posted" } })
    expect(replies[0].client_msg_id ?? runs[0].turn).toBe(runs[0].turn)
    // The next message is answered as usual.
    await dmAndReply(token, chief, "after the fault", 2)

    // The opencode target: no container runs here.
    const c = await http("POST", `/v1/chiefs/${chief.id}/fault`, token, { conversation: chief.main_conversation, target: "container" })
    expect(c.status).toBe(409)
    // Only the owner may use the hook.
    const other = await sessionToken("fault-other")
    await op(other, "user.ensure", {})
    expect((await http("POST", `/v1/chiefs/${chief.id}/fault`, other, { conversation: chief.main_conversation, target: "brain" })).status).toBe(403)
  })
})
