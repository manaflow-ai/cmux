import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Live Chief frames (chief-brain/contract.ts "Live frames", capability chief-live-v1) through the
 * product boundary: a member's conversation socket over the Worker, a person's message over
 * POST /v1/ops, the Chief's Durable Object brain answering with the fake model. The member sees the
 * "working on" line, then ordered `step.delta` frames whose text is the reply, then the reply
 * itself; a member who joins mid-run gets one `run.live` with the text so far and continues from
 * its seq; after the run nothing is live. Nothing live is stored (the run's steps hold the text).
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
  const chief = (await op(token, "chief.create", { display_name: "Live Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  for (let i = 0; i < 20; i++) {
    await fireAlarm(userDO)
    if ((await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation: chief.main_conversation, limit: 1 } })).status === 200) break
  }
  return { token, chief }
}

const connect = async (id: string, token: string) => {
  const res = await worker.fetch(`https://api.test/v1/wire/conv/${id}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": "cmux.wire.v1", authorization: `Bearer ${token}` } })
  expect(res.status).toBe(101)
  const ws = res.webSocket!
  const frames: Array<any> = []
  ws.addEventListener("message", (e) => frames.push({ ...JSON.parse(e.data as string), _ms: Date.now() }))
  ws.accept()
  ws.send(JSON.stringify({ t: "subscribe" }))
  return { ws, frames }
}

/** Drives the conversation outbox (wake -> MuxDO -> brain) and the brain's alarms until `done` holds. */
const drive = async (conversation: string, brain: string, done: () => boolean | Promise<boolean>, what: string) => {
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conversation))
  const b = testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(brain))
  for (let i = 0; i < 400; i++) {
    if (await done()) return
    await fireAlarm(conv)
    if (i % 10 === 9) await fireAlarm(b)
    await new Promise((r) => setTimeout(r, 20))
  }
  throw new Error(`timed out waiting for ${what}`)
}

const deltasOf = (frames: Array<any>) => frames.filter((f) => f.t === "step.delta")

describe("Live Chief frames on the conversation socket", { timeout: 120_000 }, () => {
  it("streams ordered step.delta frames and an activity line before the reply, and gives a late joiner the text so far", async () => {
    const { token, chief } = await ownerWithChief("brain-live")
    const conversation = chief.main_conversation
    const on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true, effort: "medium" })
    expect(on.status, JSON.stringify(on.json)).toBe(200)
    expect(on.json.value).toMatchObject({ model: "fake", effort: "medium" })
    // Effort is validated like the model.
    expect((await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { effort: "turbo" })).json.error.code).toBe("validation.invalid")
    // A metered model this deployment does not offer (no OpenRouter key here) is refused.
    expect((await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { model: "openrouter:openai/gpt-5" })).status).toBe(409)

    const early = await connect(conversation, token)
    const welcome = early.frames.find((f) => f.t === "welcome") ?? (await drive(conversation, `${chief.id}/${conversation}`, () => early.frames.some((f) => f.t === "welcome"), "welcome"), early.frames.find((f) => f.t === "welcome"))
    expect(welcome.capabilities).toContain("chief-live-v1")
    await drive(conversation, `${chief.id}/${conversation}`, () => early.frames.some((f) => f.t === "run.live"), "the join snapshot")
    expect(early.frames.find((f) => f.t === "run.live")).toMatchObject({ type: "run.live", conversation, runs: [] })

    const words = Array.from({ length: 24 }, (_, i) => `word${i}`).join(" ")
    const sentAt = Date.now()
    expect((await op(token, "message.send", { conversation, client_msg_id: "live-1", parts: [{ type: "text", text: `SLOW please answer ${words}` }] }, "live-1")).ok).toBe(true)

    // Join late: after the first deltas arrived on the early socket, before the run ends.
    await drive(conversation, `${chief.id}/${conversation}`, () => deltasOf(early.frames).length >= 3, "the first deltas")
    const firstDeltaMs = deltasOf(early.frames)[0]._ms - sentAt
    const late = await connect(conversation, token)
    await drive(conversation, `${chief.id}/${conversation}`, () => late.frames.some((f) => f.t === "run.live"), "the late join snapshot")
    await drive(conversation, `${chief.id}/${conversation}`, async () => (await history(token, conversation)).some((m) => m.author === chief.id), "the reply")
    const reply = (await history(token, conversation)).find((m) => m.author === chief.id)!
    const text = reply.parts[0].text as string
    expect(text).toContain("SLOW please answer")
    await drive(conversation, `${chief.id}/${conversation}`, () => early.frames.some((f) => f.t === "event" && JSON.stringify(f).includes(reply.id)) && deltasOf(early.frames).some((f) => f.final), "the reply event and the final delta")

    // Early member: activity first, then contiguous deltas of one talk step whose text is the reply.
    const d = deltasOf(early.frames)
    const step = d[0].step as string
    expect(step).toMatch(/^talk:/)
    expect(d.every((f) => f.step === step && f.kind === "talk" && f.run === d[0].run && f.author === chief.id && f.conversation === conversation)).toBe(true)
    expect(d.map((f) => f.seq)).toEqual(d.map((_, i) => i))
    // The posted reply is the streamed text, trimmed.
    expect(d.map((f) => f.text).join("").trim()).toBe(text)
    expect(d.at(-1).final).toBe(true)
    expect(d.slice(0, -1).some((f) => f.final)).toBe(false)
    expect(d.every((f) => f.text.length >= 1 && f.text.length <= 4096)).toBe(true)
    const activity = early.frames.filter((f) => f.t === "run.activity" && f.run === d[0].run)
    expect(activity.length).toBeGreaterThanOrEqual(1)
    expect(activity[0]).toMatchObject({ type: "run.activity", line: "Thinking", author: chief.id })
    expect(early.frames.indexOf(activity[0])).toBeLessThan(early.frames.indexOf(d[0]))
    expect(activity.every((a) => a.line.length <= 80 && typeof a.since === "number" && a.at >= a.since)).toBe(true)
    // Batching: fewer frames than stream chunks would give at one frame per token (3-token chunks).
    expect(d.length).toBeLessThan(Math.ceil(text.length / 4))

    // Late member: one snapshot with the text so far, then deltas continue from its seq with no gap.
    const snap = late.frames.find((f) => f.t === "run.live")
    const liveRun = snap.runs.find((r: any) => r.run === d[0].run)
    expect(liveRun, JSON.stringify(snap)).toBeDefined()
    expect(liveRun.author).toBe(chief.id)
    const liveStep = liveRun.steps.find((s: any) => s.step === step)
    expect(liveStep.seq).toBeGreaterThanOrEqual(1)
    expect(text.startsWith(liveStep.text)).toBe(true)
    expect(liveStep.text).toBe(d.slice(0, liveStep.seq + 1).map((f) => f.text).join(""))
    const after = deltasOf(late.frames).filter((f) => f.step === step)
    expect(after.map((f) => f.seq)).toEqual(after.map((_, i) => liveStep.seq + 1 + i))
    expect((liveStep.text + after.map((f) => f.text).join("")).trim()).toBe(text)
    expect(liveRun.activity?.line).toBeTypeOf("string")

    // Order (cx-zz30r): the final delta, then the run's end, then the reply message.
    const replyAt = early.frames.findIndex((f) => f.t === "event" && JSON.stringify(f).includes(reply.id))
    const endAt = early.frames.findIndex((f) => f.t === "conversation-run-changed" && f.run.id === d[0].run && f.run.status !== "running")
    expect(early.frames.indexOf(d.at(-1))).toBeLessThan(endAt)
    expect(endAt).toBeLessThan(replyAt)
    // After the run: nothing is live; the run's talk step holds the text.
    await drive(conversation, `${chief.id}/${conversation}`, () => early.frames.some((f) => f.t === "conversation-run-changed" && f.run.id === d[0].run && f.run.status !== "running"), "the run end")
    early.ws.send(JSON.stringify({ t: "run.live.get", conversation }))
    await drive(conversation, `${chief.id}/${conversation}`, () => early.frames.filter((f) => f.t === "run.live").length >= 2, "the run.live.get answer")
    expect(early.frames.filter((f) => f.t === "run.live").at(-1).runs).toEqual([])
    const run = await http("GET", `/v1/chiefs/${chief.id}/runs/${d[0].run}?conversation=${conversation}`, token)
    expect(run.json.value.steps.find((s: any) => s.id === step)?.text?.trim()).toBe(text)
    console.log(JSON.stringify({ msg: "live.timing", first_delta_ms: firstDeltaMs, deltas: d.length, reply_chars: text.length, late_snapshot_seq: liveStep.seq }))
    early.ws.close()
    late.ws.close()
  })
})
