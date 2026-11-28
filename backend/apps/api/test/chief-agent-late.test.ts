import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * An agent's result that comes after the Chief's agent call returned (an approval answered later, a long
 * task) still reaches the Chief: HandDO sends the turn's outcome to the brain that started the session,
 * which posts it as a work message and answers it in a new turn. An outcome the Chief's own call already
 * saw posts nothing. The test plays the hand machine over its socket; fake model, real Worker boundary.
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
  const res = await worker.fetch(`https://api.test${path}`, { method, headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  return { status: res.status, json: (await res.json()) as any }
}
const op = async (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => (await http("POST", "/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })).json
const history = async (token: string, conversation: string) => (await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation, limit: 50 } })).json.value.messages as Array<any>

const ownerWithChief = async (sub: string) => {
  const token = await sessionToken(sub)
  const user = (await op(token, "user.ensure", {})).value.id as string
  const chief = (await op(token, "chief.create", { display_name: "Hands Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
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
  const key = `hands-${text.replace(/[^a-z0-9]+/g, "-")}`
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

const sha = async (s: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))), (b) => b.toString(16).padStart(2, "0")).join("")
// Turn requests of the Chief's own loop that carried this marker (requests with no tool set, such as a summary
// pass over the same text, are left out).
/** The person pairs a machine for their Chiefs (pair code, then the hand's pair call). */
const pairAndDial = async (token: string, name: string, onReq: (f: any, send: (x: unknown) => void) => void) => {
  const minted = await http("POST", "/v1/hands/pair-codes", token, { name, profile: "sandbox" })
  expect(minted.status, JSON.stringify(minted.json)).toBe(200)
  const key = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
  const paired = await http("POST", "/v1/hands/pair", "", { code: (minted.json.value as { code: string }).code, key_sha256: await sha(key), name, profile: "sandbox" })
  expect(paired.json.ok).toBe(true)
  const res = await worker.fetch(`https://api.test/v1/hands/${paired.json.value.hand}/socket`, { headers: { Upgrade: "websocket", authorization: `Bearer ${key}` } })
  const ws = res.webSocket!
  const send = (x: unknown) => ws.send(JSON.stringify(x))
  ws.addEventListener("message", (e) => onReq(JSON.parse(e.data as string), send))
  ws.accept()
  send({ t: "hello", version: "test", profile: "sandbox", roots: ["/work"], agent_policy: "approve-edits", harnesses: ["claude", "codex", "opencode"], caps: ["levels"], os: "linux", arch: "x86_64", hostname: name })
  return Object.assign(send, { hand: paired.json.value.hand as string })
}

const cards = (ms: Array<any>, chief: string) => ms.filter((m) => m.author === chief && m.parts[0]?.type === "work" && String(m.parts[0].session).startsWith("agent_"))

describe("an agent result after the Chief's agent call returned", { timeout: 150_000 }, () => {
  it("comes back as one work message and the Chief answers it; a result the call already saw posts nothing", async () => {
    const { token, chief } = await ownerWithChief("agent-late")
    expect((await http("PUT", `/v1/hands/grants/${chief.id}`, token, { on: true })).status).toBe(200)
    let seq = 0
    const send = await pairAndDial(token, "sb-late", (f, send) => {
      if (f.t !== "req" || f.action !== "agent.start") return
      const session = String(f.params.prompt).includes("quick") ? "sess-quick" : "sess-late"
      send({ t: "res", id: f.id, ok: true, value: { session, harness: "claude", cwd: f.params.cwd } })
      send({ t: "event", session, seq: ++seq, event: { kind: "turn_start" } })
      // The quick agent ends inside the call; the late one waits for its owner's approval.
      if (session === "sess-quick") [send({ t: "event", session, seq: ++seq, event: { kind: "text", text: "quick done" } }), send({ t: "event", session, seq: ++seq, event: { kind: "turn_end", stop_reason: "end_turn" } })]
      else send({ t: "event", session, seq: ++seq, event: { kind: "permission", permission_id: "p1", title: "date -u > /work/child.txt" } })
    })
    // The next turns get the full hands and agent tools.
    await dmAndReply(token, chief, "warm one", 1)
    await dmAndReply(token, chief, "warm two", 2)
    await dmAndReply(token, chief, 'quick tool:agent {"action":"start","hand":"sb-late","harness":"claude","cwd":"/work","prompt":"quick","wait_seconds":3}', 3)
    await dmAndReply(token, chief, 'late tool:agent {"action":"start","hand":"sb-late","harness":"claude","cwd":"/work","prompt":"write child.txt","wait_seconds":1}', 4)
    // The owner allowed it later: the agent runs on and ends its turn.
    send({ t: "event", session: "sess-late", seq: ++seq, event: { kind: "text", text: "child.txt is written" } })
    send({ t: "event", session: "sess-late", seq: ++seq, event: { kind: "turn_end", stop_reason: "end_turn" } })
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(chief.main_conversation))
    let ms: Array<any> = []
    for (let i = 0; i < 300; i++) {
      ms = await history(token, chief.main_conversation)
      if (cards(ms, chief.id).length > 0 && ms.filter((m) => m.author === chief.id && m.parts[0]?.type === "text").length >= 5) break
      await fireAlarm(conv)
      await new Promise((r) => setTimeout(r, 25))
    }
    const found = cards(ms, chief.id)
    expect(found.map((m) => m.parts[0].session)).toEqual(["agent_sess-late"])
    expect(found[0].parts[0].preview).toContain("child.txt is written")
    const last = ms.filter((m) => m.author === chief.id && m.parts[0]?.type === "text").at(-1)
    expect(last.parts[0].text).toContain("child.txt is written")
    expect(last.seq).toBeGreaterThan(found[0].seq)

    // A send that failed (the brain did not answer): the row stays in the hand's object and the alarm sends it
    // again; the brain takes it once however often it comes.
    const handDO = (testEnv as any).HAND_DO.get((testEnv as any).HAND_DO.idFromName(send.hand))
    const outcome = { hand: send.hand, hand_name: "sb-late", session: "sess-resent", seq: 900, end_seq: 901, status: "done", stop_reason: "end_turn", text: "resent result arrived", tools: [], errors: [] }
    await runInDurableObject(handDO, async (_i: unknown, s: DurableObjectState) => void s.storage.sql.exec(`INSERT INTO hand_outcome (key, target, body, tries, first_at, next_at) VALUES ('sess-resent:900', ?, ?, 1, ?, 0)`, `${chief.id}/${chief.main_conversation}`, JSON.stringify(outcome), Date.now()))
    await fireAlarm(handDO)
    for (let i = 0; i < 300 && !cards(await history(token, chief.main_conversation), chief.id).some((m) => m.parts[0].session === "agent_sess-resent"); i++) [await fireAlarm(conv), await new Promise((r) => setTimeout(r, 25))]
    // The same outcome once more (a resend after a lost ack): no second card.
    const insert = () => runInDurableObject(handDO, async (_i: unknown, s: DurableObjectState) => void s.storage.sql.exec(`INSERT INTO hand_outcome (key, target, body, tries, first_at, next_at) VALUES ('sess-resent:900', ?, ?, 1, ?, 0) ON CONFLICT DO NOTHING`, `${chief.id}/${chief.main_conversation}`, JSON.stringify(outcome), Date.now()))
    await insert()
    await fireAlarm(handDO)
    for (let i = 0; i < 40; i++) [await fireAlarm(conv), await new Promise((r) => setTimeout(r, 25))]
    const again = cards(await history(token, chief.main_conversation), chief.id).filter((m) => m.parts[0].session === "agent_sess-resent")
    expect(again).toHaveLength(1)
    expect(again[0].parts[0].preview).toContain("resent result arrived")
    expect(await runInDurableObject(handDO, async (_i: unknown, s: DurableObjectState) => Number(s.storage.sql.exec(`SELECT COUNT(*) AS n FROM hand_outcome`).one().n))).toBe(0)
  })
})
