import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { afterEach, describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"
import { fakeCalls, holdTurns } from "../src/chief-brain/fake.ts"

/**
 * Cloud Chief D (chief-durable/, plans/cmux-next/cloud-chief-durable-DESIGN.md) through the product
 * boundary: the owner turns the brain on and picks `brain_impl: "durable"` over HTTP, a person writes in
 * the Chief's conversation over POST /v1/ops, and the Chief answers there as itself. Fake model only.
 * Every check is on what a person sees (messages, runs) or on the stored memory a later turn reads.
 */
const testEnv = env as unknown as Record<string, any>
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
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
const say = async (token: string, conversation: string, key: string, text: string) => expect((await op(token, "message.send", { conversation, client_msg_id: key, parts: [{ type: "text", text }] }, key)).ok).toBe(true)

const ownerWithChief = async (sub: string, impl: "durable" | "pi") => {
  const token = await sessionToken(sub)
  const ensured = (await op(token, "user.ensure", {})).value
  const chief = (await op(token, "chief.create", { display_name: "Durable Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(ensured.id))
  for (let i = 0; i < 20; i++) {
    await fireAlarm(userDO)
    if ((await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation: chief.main_conversation, limit: 1 } })).status === 200) break
  }
  expect((await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true })).status).toBe(200)
  if (impl === "durable") {
    const set = await http("PUT", `/v1/chiefs/${chief.id}/brain-impl`, token, { impl: "durable" })
    expect(set.status, JSON.stringify(set.json)).toBe(200)
  }
  return { token, user: ensured.id as string, chief }
}

const durable = (chief: string, conversation: string) => testEnv.CHIEF_DURABLE_DO.get(testEnv.CHIEF_DURABLE_DO.idFromName(`${chief}/${conversation}`))
const pBrain = (chief: string, conversation: string) => testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${chief}/${conversation}`))

/** Drives the conversation's outbox (wake to MuxDO, then to the brain) and the brain's alarm until the Chief has posted `n` messages. */
const chiefReplies = async (token: string, conversation: string, chief: string, n: number, brain: unknown) => {
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conversation))
  const mux = testEnv.MUX_DO.get(testEnv.MUX_DO.idFromName(chief))
  for (let i = 0; i < 300; i++) {
    const mine = (await history(token, conversation)).filter((m) => m.author === chief)
    if (mine.length >= n) return mine
    await fireAlarm(conv)
    if (i % 10 === 9) [await fireAlarm(brain), await fireAlarm(mux)]
    await sleep(30)
  }
  const dump = await inDO(brain, async (_i, s) => Object.fromEntries(["cd_batch", "cd_run", "cb_cursor", "cb_turn"].map((t) => [t, s.storage.sql.exec(`SELECT name FROM sqlite_master WHERE name = ?`, t).toArray().length ? s.storage.sql.exec(`SELECT * FROM ${t}`).toArray() : null]))).catch((e) => String(e))
  throw new Error(`the chief did not answer ${n} time(s) in ${conversation}: ${JSON.stringify(dump).slice(0, 3000)}`)
}
/** A few more rounds of every alarm, so a duplicate post would have landed. */
const settle = async (conversation: string, chief: string, brain: unknown) => {
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conversation))
  const mux = testEnv.MUX_DO.get(testEnv.MUX_DO.idFromName(chief))
  for (let i = 0; i < 15; i++) [await fireAlarm(conv), await fireAlarm(mux), await fireAlarm(brain), await sleep(30)]
}
const textOf = (m: any) => (m.parts ?? []).filter((p: any) => p.type === "text").map((p: any) => p.text).join("")

describe("Cloud Chief D (pi-durable)", { timeout: 120_000 }, () => {
  let release: (() => void) | undefined
  afterEach(() => {
    release?.()
    release = undefined
  })

  it("answers its owner once, with a run members can read, on the durable brain only", async () => {
    const { token, chief } = await ownerWithChief("durable-dm", "durable")
    const conv = chief.main_conversation
    await say(token, conv, "d1", "hello durable chief")
    const [reply] = await chiefReplies(token, conv, chief.id, 1, durable(chief.id, conv))
    expect(textOf(reply)).toContain("reply to:")
    expect(textOf(reply)).toContain("hello durable chief")
    // The work part names the run; the runs route reads it from the durable brain.
    const work = reply.parts.find((p: any) => p.type === "work")
    expect(work?.session).toMatch(/^run_9\d{9}$/)
    const run = await http("GET", `/v1/chiefs/${chief.id}/runs/${work.session}?conversation=${conv}`, token)
    expect(run.status, JSON.stringify(run.json)).toBe(200)
    expect(run.json.value.run.status).toBe("done")
    expect(run.json.value.run.harness).toBe("pi-durable-d")
    expect(run.json.value.steps.some((s: any) => s.kind === "talk")).toBe(true)
    // P never ran a turn for this Chief.
    expect(await inDO(pBrain(chief.id, conv), async (_i, s) => s.storage.sql.exec(`SELECT name FROM sqlite_master WHERE name = 'cb_turn'`).toArray().length === 0 || Number(s.storage.sql.exec(`SELECT COUNT(*) AS n FROM cb_turn`).one().n) === 0)).toBe(true)
  })

  it("answers a repeated wake once", async () => {
    const { token, user, chief } = await ownerWithChief("durable-repeat", "durable")
    const conv = chief.main_conversation
    await say(token, conv, "r1", "only once please")
    const brain = durable(chief.id, conv)
    await chiefReplies(token, conv, chief.id, 1, brain)
    const seq = Math.max(...(await history(token, conv)).filter((m) => m.author !== chief.id).map((m) => m.seq))
    // MuxDO resends a wake whose first RPC got no answer: the brain must not answer the same message again.
    for (let i = 0; i < 3; i++) await (brain as any).wake({ agent: chief.id, owner: user, conversation: conv, seq, reason: "dm" })
    await settle(conv, chief.id, brain)
    expect((await history(token, conv)).filter((m) => m.author === chief.id)).toHaveLength(1)
  })

  it("one run answers a message that comes while it works", async () => {
    const { token, chief } = await ownerWithChief("durable-steer", "durable")
    const conv = chief.main_conversation
    const brain = durable(chief.id, conv)
    const runs = async () => (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${conv}`, token)).json.value?.runs as Array<any> ?? []
    const convDO = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conv))
    release = holdTurns()
    await say(token, conv, "s1", "SLOW tell me about releases")
    for (let i = 0; i < 300 && !(await runs()).some((r) => r.status === "running"); i++) [await fireAlarm(convDO), await sleep(20)]
    await say(token, conv, "s2", "and 12 x 12?")
    for (let i = 0; i < 300 && !(await runs()).some((r) => r.answers?.length === 2); i++) [await fireAlarm(convDO), await sleep(20)]
    release()
    release = undefined
    const [reply] = await chiefReplies(token, conv, chief.id, 1, brain)
    await settle(conv, chief.id, brain)
    expect((await history(token, conv)).filter((m) => m.author === chief.id)).toHaveLength(1)
    expect(textOf(reply)).toContain("12 x 12")
    const all = await runs()
    expect(all.map((r) => r.status)).toEqual(["done"])
    expect(all[0].answers).toHaveLength(2)
  })

  it("an eviction in the middle of a run still answers once", async () => {
    const { token, chief } = await ownerWithChief("durable-evict", "durable")
    const conv = chief.main_conversation
    let brain = durable(chief.id, conv)
    const runs = async () => (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${conv}`, token)).json.value?.runs as Array<any> ?? []
    const convDO = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conv))
    release = holdTurns()
    await say(token, conv, "e1", "SLOW survive a restart")
    for (let i = 0; i < 300 && !(await runs()).some((r) => r.status === "running"); i++) [await fireAlarm(convDO), await sleep(20)]
    // The object dies as an eviction does: memory gone, storage kept.
    await (brain as any).fault().catch(() => undefined)
    // A stub whose object was aborted stays broken; the next one reaches the restarted object.
    brain = durable(chief.id, conv)
    release()
    release = undefined
    await chiefReplies(token, conv, chief.id, 1, brain)
    await settle(conv, chief.id, brain)
    const mine = (await history(token, conv)).filter((m) => m.author === chief.id)
    expect(mine).toHaveLength(1)
    expect(textOf(mine[0])).toContain("survive a restart")
  })

  it("keeps the memory a Chief built on P when it moves to D", async () => {
    const { token, chief } = await ownerWithChief("durable-move", "pi")
    const conv = chief.main_conversation
    await say(token, conv, "m1", "remember the codename BLUE HERON")
    await chiefReplies(token, conv, chief.id, 1, pBrain(chief.id, conv))
    expect((await http("PUT", `/v1/chiefs/${chief.id}/brain-impl`, token, { impl: "durable" })).status).toBe(200)
    await say(token, conv, "m2", "what was the codename?")
    const brain = durable(chief.id, conv)
    await chiefReplies(token, conv, chief.id, 2, brain)
    // D's memory holds P's log (the earlier message and P's reply) before its own new message.
    const log = await inDO(brain, async (_i, s) => s.storage.sql.exec<{ kind: string; text: string }>(`SELECT kind, text FROM oc_message ORDER BY i`).toArray())
    const first = log.findIndex((r) => r.text.includes("BLUE HERON"))
    const asked = log.findIndex((r) => r.text.includes("what was the codename"))
    expect(first).toBeGreaterThanOrEqual(0)
    expect(asked).toBeGreaterThan(first)
    expect(log.some((r) => r.kind === "talk")).toBe(true)
    // The earlier message is answered once in all: D did not answer it again.
    await settle(conv, chief.id, brain)
    expect((await history(token, conv)).filter((m) => m.author === chief.id)).toHaveLength(2)
  })

  it("NO_REPLY to its owner leaves the message waiting; the reply ledger's retry turn answers it", async () => {
    const { token, chief } = await ownerWithChief("durable-noreply", "durable")
    const conv = chief.main_conversation
    const brain = durable(chief.id, conv)
    // The fake model answers "NO_REPLY" to a message that asks for exactly that.
    await say(token, conv, "n1", "SAY_NO_REPLY")
    const convDO = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conv))
    const runs = async () => (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${conv}`, token)).json.value?.runs as Array<any> ?? []
    for (let i = 0; i < 300 && !(await runs()).some((r) => r.status === "done"); i++) [await fireAlarm(convDO), i % 10 === 9 ? await fireAlarm(brain) : undefined, await sleep(20)]
    expect((await history(token, conv)).filter((m) => m.author === chief.id)).toHaveLength(0)
    expect((await runs()).at(-1)?.reply?.state).toBe("no_reply")
    // The kernel's reply ledger (chief-kernel ledger.rs) checks 5 s after the turn: the person's message got no
    // words, so a retry turn starts on a "[no reply]" note and its answer is posted in the message's thread.
    await sleep(5_200)
    const [reply] = await chiefReplies(token, conv, chief.id, 1, brain)
    expect(textOf(reply)).toContain("[no reply]")
    await settle(conv, chief.id, brain)
    expect((await history(token, conv)).filter((m) => m.author === chief.id)).toHaveLength(1)
  })

  it("send and reply post at once, in the thread of the line they name, before the turn's final text", async () => {
    const { token, chief } = await ownerWithChief("durable-send", "durable")
    const conv = chief.main_conversation
    // A fresh Chief's first message is line 0 of its view.
    await say(token, conv, "t1", 'tool:send {"text":"first part","reply_to":0}')
    const posted = await chiefReplies(token, conv, chief.id, 2, durable(chief.id, conv))
    const asked = (await history(token, conv)).find((m) => m.author !== chief.id && textOf(m).includes("tool:send"))
    expect(textOf(posted[0])).toBe("first part")
    expect(posted[0].reply_to?.message_id).toBe(asked.id)
    // The tool's result went back to the model, whose last text is the second post.
    expect(textOf(posted[1])).toContain("tool said:")
  })

  it("stop ends the turn with nothing more posted", async () => {
    const { token, chief } = await ownerWithChief("durable-stop", "durable")
    const conv = chief.main_conversation
    const brain = durable(chief.id, conv)
    const convDO = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conv))
    const runs = async () => (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${conv}`, token)).json.value?.runs as Array<any> ?? []
    await say(token, conv, "p1", "tool:stop {}")
    for (let i = 0; i < 300 && !(await runs()).some((r) => r.status === "done"); i++) [await fireAlarm(convDO), i % 10 === 9 ? await fireAlarm(brain) : undefined, await sleep(20)]
    // Read at once: 5 s later the reply ledger starts a retry turn for the unanswered message (the NO_REPLY case).
    // No model request after stop: the run has no talk step and posted nothing.
    expect((await history(token, conv)).filter((m) => m.author === chief.id)).toHaveLength(0)
    const run = (await runs()).at(-1)
    expect(run.status).toBe("done")
    const steps = (await http("GET", `/v1/chiefs/${chief.id}/runs/${run.id}?conversation=${conv}`, token)).json.value.steps as Array<any>
    expect(steps.some((s) => s.kind === "talk")).toBe(false)
    expect(steps.some((s) => s.tool?.name === "stop")).toBe(true)
  })

  it("zoom answers from the kernel's pure tool", async () => {
    const { token, chief } = await ownerWithChief("durable-zoom", "durable")
    const conv = chief.main_conversation
    await say(token, conv, "z0", "remember the word ORCHID")
    await chiefReplies(token, conv, chief.id, 1, durable(chief.id, conv))
    await say(token, conv, "z1", "zoom(0, 1)")
    const replies = await chiefReplies(token, conv, chief.id, 2, durable(chief.id, conv))
    expect(textOf(replies[1])).toContain("ORCHID")
  })
  it("runs on the kernel's cloud prompt: only the tools it offers, no shell, the owner rule", async () => {
    const { token, chief } = await ownerWithChief("durable-prompt", "durable")
    const conv = chief.main_conversation
    await say(token, conv, "q1", "what can you do here?")
    await chiefReplies(token, conv, chief.id, 1, durable(chief.id, conv))
    const call = [...fakeCalls].reverse().find((c) => c.kind === "turn" && c.firstUser.some((b) => b.includes("what can you do here?")))
    expect(call, "the turn's model request").toBeDefined()
    expect(call!.system).toContain("You run in cmux Cloud")
    expect(call!.system).toContain("owner approval required")
    for (const absent of ["spawn(", "sleep(", "react(", "remember(", "transcript("]) expect(call!.system, absent).not.toContain(absent)
    expect(call!.tools.map((t) => t.name).sort()).toEqual(["date", "reply", "send", "stop", "zoom"])
  })
})
