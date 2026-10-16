import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { afterAll, describe, expect, it } from "vitest"
import { ChiefBrainDO } from "../src/chief-brain/brain-do.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Wake delivery from MuxDO to the Chief's brain, through the product boundary (POST /v1/ops, /v1/read):
 * - a cloud-run Chief's brain object is evicted WHILE MuxDO's wake RPC is in flight (the RPC fails): the
 *   wake stays undelivered in MuxDO, its alarm sends it again with backoff, and the Chief answers the
 *   message exactly once (the brain takes the repeated wake idempotently);
 * - a local-run Chief (mux.configure brain "local", read by a local host with --conversation-source cloud):
 *   its wakes never go to ChiefBrainDO, stay in the queue (not lost), and the host's mux.ack clears them.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace; CHIEF_BRAIN_DO: DurableObjectNamespace; MUX_DO: DurableObjectNamespace }
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
  const chief = (await op(token, "chief.create", { display_name: "Wake Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
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
  const key = `wake-${text.replace(/[^a-z0-9]+/g, "-")}`
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

// ChiefBrainDO.wake calls by agent; `evictNext` makes the next call evict the object inside the RPC.
const wakes: Array<string> = []
const evictNext = new Set<string>()
const realWake = ChiefBrainDO.prototype.wake
ChiefBrainDO.prototype.wake = async function (this: ChiefBrainDO, w) {
  wakes.push(w.agent)
  if (evictNext.delete(w.agent)) (this as unknown as { ctx: DurableObjectState }).ctx.abort("test: evicted during the wake RPC")
  return realWake.call(this, w)
}
afterAll(() => void (ChiefBrainDO.prototype.wake = realWake))

describe("Chief wake delivery", { timeout: 120_000 }, () => {
  it("a wake whose brain is evicted during the wake RPC is sent again and answered exactly once", async () => {
    const { token, chief } = await ownerWithChief("wake-evict")
    const mux = testEnv.MUX_DO.get(testEnv.MUX_DO.idFromName(chief.id))
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(chief.main_conversation))
    evictNext.add(chief.id)
    const key = "wake-evicted"
    expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: key, parts: [{ type: "text", text: "lost wake check" }] }, key)).ok).toBe(true)
    let replies: Array<any> = []
    for (let i = 0; i < 200 && replies.length === 0; i++) {
      replies = (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)
      // The first resend is due 1 s after the failed send; MuxDO's alarm sends it.
      if (replies.length === 0) [await fireAlarm(conv), i % 5 === 4 && (await fireAlarm(mux)), await new Promise((r) => setTimeout(r, 50))]
    }
    expect(evictNext.has(chief.id), "the eviction never happened").toBe(false)
    expect(wakes.filter((a) => a === chief.id).length, "the wake was not sent again").toBeGreaterThanOrEqual(2)
    for (let i = 0; i < 10; i++) [await fireAlarm(conv), await fireAlarm(mux), await new Promise((r) => setTimeout(r, 50))]
    replies = (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)
    expect(replies).toHaveLength(1)
    expect(replies[0].parts[0].text).toContain("lost wake check")
    // Nothing is left to deliver.
    const left = await runInDurableObject(mux, async (_i: unknown, st: DurableObjectState) => Number(st.storage.sql.exec(`SELECT COUNT(*) AS n FROM mux_wake_delivery`).one().n))
    expect(left).toBe(0)
  })

  it("a local-run Chief's wakes never go to the cloud brain, stay queued, and the local ack clears them", async () => {
    const { token, chief } = await ownerWithChief("wake-local")
    const mux = testEnv.MUX_DO.get(testEnv.MUX_DO.idFromName(chief.id))
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(chief.main_conversation))
    const local = await op(token, "mux.configure", { agent: chief.id, brain: "local", brain_host: "mac-test" })
    expect(local.ok, JSON.stringify(local)).toBe(true)
    const before = wakes.filter((a) => a === chief.id).length
    const key = "wake-local-1"
    expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: key, parts: [{ type: "text", text: "for the local host" }] }, key)).ok).toBe(true)
    let pending = 0
    for (let i = 0; i < 100 && pending === 0; i++) {
      const q = await http("POST", "/v1/read", token, { op: "mux.queue", params: { agent: chief.id } })
      pending = q.json.value?.pending ?? 0
      if (pending === 0) [await fireAlarm(conv), await new Promise((r) => setTimeout(r, 25))]
    }
    expect(pending, "the wake was lost").toBe(1)
    for (let i = 0; i < 5; i++) [await fireAlarm(mux), await new Promise((r) => setTimeout(r, 25))]
    expect(wakes.filter((a) => a === chief.id).length - before, "a local Chief's wake reached the cloud brain").toBe(0)
    expect((await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)).toHaveLength(0)
    const left = await runInDurableObject(mux, async (_i: unknown, st: DurableObjectState) => st.storage.sql.exec(`SELECT name FROM sqlite_master WHERE name = 'mux_wake_delivery'`).toArray().length ? Number(st.storage.sql.exec(`SELECT COUNT(*) AS n FROM mux_wake_delivery`).one().n) : 0)
    expect(left).toBe(0)
    // The local host acks (mux.ack, the same op it sends through the cloud proxy): the queue clears.
    const msg = (await history(token, chief.main_conversation)).find((m) => m.client_msg_id === key)
    const acked = await op(token, "mux.ack", { agent: chief.id, conversation: chief.main_conversation, seq: msg.seq })
    expect(acked.ok, JSON.stringify(acked)).toBe(true)
    expect((await http("POST", "/v1/read", token, { op: "mux.queue", params: { agent: chief.id } })).json.value.pending).toBe(0)
  })
})
