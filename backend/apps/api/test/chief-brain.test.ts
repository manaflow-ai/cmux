import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * The Chief's Durable Object brain (chief-brain/brain-do.ts) through the product boundary: the
 * owner turns it on over HTTP, a person writes in a Cloud conversation over POST /v1/ops, and the
 * chief answers in that conversation as itself (a member's socket sees it type, then the message),
 * with a run reference whose steps the run route returns to members only. Fake model only.
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

/** Waits (bounded) until `pred` holds on the socket's frames; socket frames arrive after the RPC that sent them. */
const waitFor = async (frames: Array<any>, pred: (f: any) => boolean) => {
  for (let i = 0; i < 200 && !frames.some(pred); i++) await new Promise((r) => setTimeout(r, 20))
  return frames.findIndex(pred)
}

/** A conversation socket with a frame log. */
const connect = async (id: string, token: string) => {
  const res = await worker.fetch(`https://api.test/v1/wire/conv/${id}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": "cmux.wire.v1", authorization: `Bearer ${token}` } })
  expect(res.status).toBe(101)
  const ws = res.webSocket!
  const frames: Array<any> = []
  ws.addEventListener("message", (e) => frames.push(JSON.parse(e.data as string)))
  ws.accept()
  ws.send(JSON.stringify({ t: "subscribe" }))
  return { ws, frames }
}

describe("Chief brain on Durable Objects", { timeout: 120_000 }, () => {
  it("answers its owner's DM in realtime with a run whose steps only members read", async () => {
    const { token, chief } = await ownerWithChief("brain-dm")
    const other = await sessionToken("brain-dm-other")
    await op(other, "user.ensure", {})

    // Only the owner turns the brain on; a bad model name is refused.
    expect((await http("PUT", `/v1/chiefs/${chief.id}/brain`, other, { enabled: true })).status).toBe(403)
    expect((await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { model: "gpt-4" })).json.error.code).toBe("validation.invalid")
    const on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true, role: "Release captain", personality: "Brief." })
    expect(on.status, JSON.stringify(on.json)).toBe(200)
    expect(on.json.value).toMatchObject({ agent: chief.id, enabled: true, model: "fake", role: "Release captain" })

    const socket = await connect(chief.main_conversation, token)
    expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: "dm-1", parts: [{ type: "text", text: "is the release green?" }] }, "dm-1")).ok).toBe(true)
    const [reply] = await chiefReplies(token, chief.main_conversation, chief.id, 1)
    expect(reply.parts[0]).toMatchObject({ type: "text" })
    expect(reply.parts[0].text).toContain("is the release green?")
    expect(reply.parts[1]).toMatchObject({ type: "work", host: `cloud-chief:${chief.id}`, status: "done" })
    expect(reply.thread_root).toBeUndefined()

    // The owner's socket saw the chief type, the run go live, then the reply arrive (no reload).
    const typing = await waitFor(socket.frames, (f) => f.t === "conversation-typing" && f.participant === chief.id && f.on === true)
    const live = await waitFor(socket.frames, (f) => f.t === "conversation-run-changed" && f.run.status === "running" && f.run.author === chief.id)
    const arrived = await waitFor(socket.frames, (f) => f.t === "event" && JSON.stringify(f).includes(reply.id))
    const talked = await waitFor(socket.frames, (f) => f.t === "conversation-run-changed" && f.steps.some((s: { kind: string; text?: string }) => s.kind === "talk" && s.text?.includes("is the release green?")))
    expect(typing, JSON.stringify(socket.frames.map((f) => f.t))).toBeGreaterThanOrEqual(0)
    expect(live).toBeGreaterThanOrEqual(0)
    expect(arrived).toBeGreaterThan(typing)
    expect(talked).toBeGreaterThan(live)
    socket.ws.close()

    // The run (trajectory wire): the reply's client_msg_id is the run's turn; members only, one answer for hidden and missing.
    const run = reply.parts[1].session as string
    const read = await http("GET", `/v1/chiefs/${chief.id}/runs/${run}?conversation=${chief.main_conversation}`, token)
    expect(read.status, JSON.stringify(read.json)).toBe(200)
    expect(read.json.value.run).toMatchObject({ id: run, author: chief.id, conversation: chief.main_conversation, status: "done", harness: "pi-durable", turn: reply.client_msg_id, reply: { state: "posted", message: reply.id } })
    expect(read.json.value.steps.map((s: { kind: string }) => s.kind)).toContain("talk")
    expect(read.json.value.steps[0]).toMatchObject({ id: expect.stringMatching(/^talk:/), seq: 1 })
    const list = await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, token)
    expect(list.json.value.runs.map((r: { id: string }) => r.id)).toEqual([run])
    expect((await http("GET", `/v1/chiefs/${chief.id}/runs/${run}?conversation=${chief.main_conversation}`, other)).status).toBe(404)
    expect((await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, other)).status).toBe(404)
    expect((await http("GET", `/v1/chiefs/${chief.id}/runs/run_999999?conversation=${chief.main_conversation}`, token)).status).toBe(404)

    // A second message is a new turn with its own run; the memory holds the first exchange.
    expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: "dm-2", parts: [{ type: "text", text: "and the notes?" }] }, "dm-2")).ok).toBe(true)
    const replies = await chiefReplies(token, chief.main_conversation, chief.id, 2)
    expect(replies[1].parts[1].session).not.toBe(run)
    const status = await http("GET", `/v1/chiefs/${chief.id}/brain`, token)
    expect(status.json.value.turns_today).toBe(2)
  })

  it("replies in the thread of a channel message, and stays quiet until its owner turns it on", async () => {
    const { token, user, chief } = await ownerWithChief("brain-channel")
    const created = await op(token, "conversation.create", {
      title: "release",
      participants: [
        { id: user, kind: "human", display_name: "Owner" },
        { id: chief.id, kind: "agent", agent_class: "mux", display_name: "Release Chief" }
      ]
    })
    expect(created.ok, JSON.stringify(created)).toBe(true)
    const channel = created.value.conversation.id as string
    const mention = (text: string, key: string) => ({ conversation: channel, client_msg_id: key, parts: [{ type: "text", text, runs: [{ start: 0, length: 6, mention: chief.id }] }] })

    // Off: the wake is queued in MuxDO but nobody answers.
    expect((await op(token, "message.send", mention("@chief before", "ch-0"), "ch-0")).ok).toBe(true)
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(channel))
    for (let i = 0; i < 5; i++) await fireAlarm(conv)
    expect((await history(token, channel)).filter((m) => m.author === chief.id)).toHaveLength(0)

    expect((await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true })).status).toBe(200)
    const sent = await op(token, "message.send", mention("@chief ship it?", "ch-1"), "ch-1")
    expect(sent.ok).toBe(true)
    const [reply] = await chiefReplies(token, channel, chief.id, 1)
    // Only the message after it was turned on is answered, in that message's thread.
    expect(reply.parts[0].text).toContain("ship it?")
    expect(reply.parts[0].text).not.toContain("before")
    expect(reply.thread_root).toBe(sent.value.message_id)
    expect(reply.reply_to).toMatchObject({ message_id: sent.value.message_id })
  })
  it("ends its typing when it skips a turn, so a client's Thinking line does not stay", async () => {
    const limits = env as unknown as { CHIEF_BRAIN_DAILY_TURNS?: string }
    const saved = limits.CHIEF_BRAIN_DAILY_TURNS
    limits.CHIEF_BRAIN_DAILY_TURNS = "1"
    try {
      const { token, chief } = await ownerWithChief("brain-skip-typing")
      expect((await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true })).status).toBe(200)
      expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: "sk-1", parts: [{ type: "text", text: "first" }] }, "sk-1")).ok).toBe(true)
      await chiefReplies(token, chief.main_conversation, chief.id, 1)

      // Over the daily limit: no turn and no reply, but the socket sees the chief's typing go off.
      const socket = await connect(chief.main_conversation, token)
      expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: "sk-2", parts: [{ type: "text", text: "second" }] }, "sk-2")).ok).toBe(true)
      const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(chief.main_conversation))
      const off = (f: any) => f.t === "conversation-typing" && f.participant === chief.id && f.on === false
      for (let i = 0; i < 20 && !socket.frames.some(off); i++) {
        await fireAlarm(conv)
        await new Promise((r) => setTimeout(r, 50))
      }
      expect(socket.frames.findIndex(off), JSON.stringify(socket.frames.map((f) => [f.t, f.on]))).toBeGreaterThanOrEqual(0)
      expect(socket.frames.some((f) => f.t === "conversation-typing" && f.participant === chief.id && f.on === true)).toBe(false)
      expect((await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)).toHaveLength(1)
      socket.ws.close()
    } finally {
      saved === undefined ? delete limits.CHIEF_BRAIN_DAILY_TURNS : (limits.CHIEF_BRAIN_DAILY_TURNS = saved)
    }
  })
})
