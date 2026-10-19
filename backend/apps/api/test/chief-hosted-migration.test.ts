import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Home's move of a Mac Chief to the Hosted Chief, at the product boundary: the owner copies the Mac
 * Chief's memory export into the hosted Chief's brain (PUT /v1/chiefs/<agent>/memory) and its history
 * into the Chief's empty main conversation (conversation.import fill), then turns the brain on; the
 * hosted Chief then reads the copied memory in a turn (fake model, zoom tool). Fake model only.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace; MUX_DO: DurableObjectNamespace }
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

/** An owner with one chief whose MuxDO is bound and whose main conversation exists. */
const ownerWithChief = async (sub: string) => {
  const token = await sessionToken(sub)
  const user = (await op(token, "user.ensure", {})).value.id as string
  const chief = (await op(token, "chief.create", { display_name: "Release Chief" }, `chief-${sub}`)).value
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  for (let i = 0; i < 20; i++) {
    await fireAlarm(userDO)
    if ((await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation: chief.main_conversation, limit: 1 } })).status === 200) break
  }
  return { token, user, chief: chief as { id: string; main_conversation: string } }
}

/** Drives the conversation's outbox (wake to MuxDO, which forwards to the brain) until the chief has answered `n` times. */
const chiefReplies = async (token: string, conversation: string, chief: string, n: number) => {
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conversation))
  // The chief's brain for this conversation (its own alarm runs post retries after the loop guard's 2 s gap).
  const brains = (env as unknown as { CHIEF_BRAIN_DO: DurableObjectNamespace }).CHIEF_BRAIN_DO
  const brain = brains.get(brains.idFromName(`${chief}/${conversation}`))
  for (let i = 0; i < 200; i++) {
    const mine = (await history(token, conversation)).filter((m) => m.author === chief)
    if (mine.length >= n) return mine
    await fireAlarm(conv)
    if (i % 10 === 9) await fireAlarm(brain)
    await new Promise((r) => setTimeout(r, 50))
  }
  const dump = await runInDurableObject(brain, async (_i, state) => ({
    turns: state.storage.sql.exec("SELECT id, status, reason, post, post_tries, last_seq FROM cb_turn").toArray(),
    inbox: state.storage.sql.exec("SELECT n, seq, state, turn FROM cb_inbox").toArray(),
    cursor: state.storage.sql.exec("SELECT * FROM cb_cursor").toArray()
  }))
  throw new Error(`the chief did not answer ${n} time(s) in ${conversation}: ${JSON.stringify(dump)}`)
}

const memory = (token: string, chief: { id: string; main_conversation: string }, body?: unknown) =>
  http(body === undefined ? "GET" : "PUT", `/v1/chiefs/${chief.id}/memory?conversation=${chief.main_conversation}`, token, body)
const line = (o: unknown) => JSON.stringify(o)
const day = "2026-10-07T07:08:31.479Z"

describe("Hosted Chief migration from a Mac Chief", { timeout: 120_000 }, () => {
  it("copies the memory and the history once, in order, only while the brain is off; the Chief then remembers", async () => {
    const { token, user, chief } = await ownerWithChief("hosted-move")
    const other = await sessionToken("hosted-move-other")
    await op(other, "user.ensure", {})
    expect((await memory(token, chief)).json.value).toEqual({ count: 0, nodes: 0, state: "empty" })
    expect((await memory(other, chief, { after: 0, main: [], tree: [] })).status).toBe(403)

    // Memory: four messages and their summaries, in two batches (main first, then tree with done).
    const texts = ["remember the blue door", "noted: blue door", "the release is friday", "noted: friday"]
    const main = texts.map((text, i) => line({ i, kind: i % 2 === 0 ? "user" : "talk", text, size: 0, date: day }))
    expect((await memory(token, chief, { after: 0, main: main.slice(0, 2), tree: [] })).json.value).toMatchObject({ count: 2, state: "importing" })
    const late = await memory(token, chief, { after: 0, main: main.slice(2), tree: [] })
    expect([late.status, late.json.error.code, late.json.error.count]).toEqual([409, "out_of_order", 2])
    const tree = [line({ l: 1, i: 0, text: "user asked to remember the blue door", size: 0 }), line({ l: 1, i: 1, text: "release friday", size: 0 }), line({ l: 2, i: 0, text: "blue door; release friday", size: 0 })]
    // A node past the copied messages is refused.
    expect((await memory(token, chief, { after: 2, main: main.slice(2), tree: [line({ l: 2, i: 1, text: "x", size: 0 })], done: true })).status).toBe(400)
    expect((await memory(token, chief, { after: 2, main: main.slice(2), tree, done: true })).json.value).toEqual({ count: 4, nodes: 3, state: "done" })
    expect((await memory(token, chief, { after: 4, main: [], tree: [] })).json.error.code).toBe("memory_import_done")

    // History: the Mac conversation fills the Chief's main conversation, then commits.
    const source = { kind: "mac", host: "inst_hostedmove", local_id: "conv_LOCALCHIEF" }
    const msg = (seq: number, author: string, text: string) => ({ id: `msg_h${seq}`, seq, client_msg_id: `h${seq}`, author, parts: [{ type: "text", text }], created_at: `2026-10-07T07:08:3${seq}.000Z` })
    expect((await op(other, "conversation.import", { id: chief.main_conversation, fill: true, source, messages: [] })).ok).toBe(false)
    const first = await op(token, "conversation.import", { id: chief.main_conversation, fill: true, source, messages: [msg(1, user, texts[0]!), msg(2, chief.id, texts[1]!)] })
    expect(first.error).toBeUndefined()
    expect(first.value.last_seq).toBe(2)
    // The same first call replays where it stands (a client resumes after last_seq).
    expect((await op(token, "conversation.import", { id: chief.main_conversation, fill: true, source, messages: [] })).value).toMatchObject({ last_seq: 2, state: "importing" })
    expect((await op(token, "conversation.import", { id: chief.main_conversation, after_seq: 2, messages: [msg(3, user, texts[2]!)] })).ok).toBe(true)
    expect((await op(token, "conversation.import.commit", { id: chief.main_conversation, last_seq: 3 })).ok).toBe(true)
    expect((await history(token, chief.main_conversation)).map((m) => m.parts[0].text)).toEqual(texts.slice(0, 3))
    // A filled conversation is not filled again from another source.
    expect((await op(token, "conversation.import", { id: chief.main_conversation, fill: true, source: { ...source, local_id: "conv_OTHER" }, messages: [] })).error.code).toBe("conversation_exists")

    // Brain on: a copy is refused now; the Chief reads the copied memory in its turn.
    expect((await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true })).status).toBe(200)
    expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: "hm-1", parts: [{ type: "text", text: "what did I ask? zoom(0, 2)" }] }, "hm-1")).ok).toBe(true)
    const replies = await chiefReplies(token, chief.main_conversation, chief.id, 2)
    expect(replies.at(-1).parts[0].text).toContain("remember the blue door")
    const brains = (env as unknown as { CHIEF_BRAIN_DO: DurableObjectNamespace }).CHIEF_BRAIN_DO
    const brain = brains.get(brains.idFromName(`${chief.id}/${chief.main_conversation}`))
    const kept = await runInDurableObject(brain, async (_i, state) => state.storage.sql.exec(`SELECT i, text FROM oc_message WHERE i < 4 ORDER BY i`).toArray())
    expect(kept.map((r) => r.text)).toEqual(texts)
  })
})
