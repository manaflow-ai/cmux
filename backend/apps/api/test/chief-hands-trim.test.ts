import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { fakeCalls, holdTurns } from "../src/chief-brain/fake.ts"
import { testSandboxInstalls } from "../src/hand-providers.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * The P brain's hands tools by whether the Chief has a hand, through the product boundary (POST /v1/ops,
 * /v1/hands routes): a Chief with no hand is offered one compact `hands` tool (list, pair_code, new_sandbox)
 * and no `agent`; a hand found during a turn changes nothing inside that turn (a model signs its thinking for the
 * tools list; the fake model refuses a changed list with Anthropic's 400), and the next turn has the full tools.
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
const pair = async (token: string, name: string) => {
  const minted = await http("POST", "/v1/hands/pair-codes", token, { name, profile: "sandbox" })
  expect(minted.status, JSON.stringify(minted.json)).toBe(200)
  const key = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
  expect((await http("POST", "/v1/hands/pair", "", { code: (minted.json.value as { code: string }).code, key_sha256: await sha(key), name, profile: "sandbox" })).json.ok).toBe(true)
}
const turnTools = (marker: string) =>
  fakeCalls.filter((c) => c.kind === "turn" && c.tools.length > 0 && (c.firstUser.join("\n").includes(marker) || c.laterUsers.join("\n").includes(marker))).map((c) => c.tools)

describe("Chief hands tools by hand", { timeout: 120_000 }, () => {
  it("offers a compact hands entry without a hand, and the full hands and agent tools once a hand is paired", async () => {
    const { token, chief } = await ownerWithChief("hands-trim")
    expect((await http("PUT", `/v1/hands/grants/${chief.id}`, token, { on: true })).status).toBe(200)

    await dmAndReply(token, chief, "no hand yet marker-one", 1)
    const first = turnTools("marker-one")
    expect(first.length).toBeGreaterThan(0)
    const names = first[0]!.map((t) => t.name)
    expect(names).toContain("hands")
    expect(names).not.toContain("agent")
    const compact = first[0]!.find((t) => t.name === "hands")!.size

    // A hand appears while the turn's first request runs (held), and the Chief lists its hands with the entry tool.
    // The model signs its thinking for the tools list (as Anthropic does): the tools must not change inside the turn,
    // or the next request is refused with a 400. The full tools come at the next turn boundary.
    const release = holdTurns()
    const key2 = "hands-marker-two"
    expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: key2, parts: [{ type: "text", text: 'SIGNED marker-two tool:hands {"action":"list"}' }] }, key2)).ok).toBe(true)
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(chief.main_conversation))
    for (let i = 0; i < 200 && turnTools("marker-two").length === 0; i++) [await fireAlarm(conv), await new Promise((r) => setTimeout(r, 25))]
    await pair(token, "sb-trim")
    release()
    let replies: Array<any> = []
    for (let i = 0; i < 200 && replies.length < 2; i++) [(replies = (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)), await fireAlarm(conv), await new Promise((r) => setTimeout(r, 25))]
    expect(replies.length).toBe(2)
    expect(replies[1].parts[0].text, "the turn failed").not.toContain("could not reach the model")
    // The pi turn that found the hand kept one tools list; the run's one continuation has the full tools.
    const calls = fakeCalls.filter((c) => c.kind === "turn" && c.tools.length > 0 && c.firstUser.join("\n").includes("marker-two"))
    const inTurn = calls.filter((c) => !c.laterUsers.join("\n").includes("Your new hand is ready")).map((c) => JSON.stringify(c.tools))
    const continued = calls.filter((c) => c.laterUsers.join("\n").includes("Your new hand is ready"))
    expect(inTurn.length, "the tool call took no second request").toBeGreaterThanOrEqual(2)
    expect(new Set(inTurn).size, `the tools changed inside the turn: ${JSON.stringify(inTurn)}`).toBe(1)
    expect(inTurn[0]).not.toContain('"agent"')
    expect(continued.length, "no continuation").toBeGreaterThanOrEqual(1)
    expect(continued[0]!.tools.map((t) => t.name)).toEqual(expect.arrayContaining(["hands", "agent"]))
    expect((await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, token)).json.value.runs).toHaveLength(2)

    // The next turn has the full tools from its first request.
    await dmAndReply(token, chief, "SIGNED marker-three", 3)
    const three = turnTools("marker-three")[0]!
    expect(three.map((t) => t.name)).toEqual(expect.arrayContaining(["hands", "agent"]))
    expect(three.find((t) => t.name === "hands")!.size).toBeGreaterThan(compact * 3)
  })

  it("a Chief whose hand was paired between turns gets the full tools without waiting on the turn's path", async () => {
    const { token, chief } = await ownerWithChief("hands-trim-next")
    expect((await http("PUT", `/v1/hands/grants/${chief.id}`, token, { on: true })).status).toBe(200)
    await dmAndReply(token, chief, "first marker-four", 1)
    expect(turnTools("marker-four")[0]!.map((t) => t.name)).not.toContain("agent")
    await pair(token, "sb-next")
    // The next turn starts with the cached (compact) set and finds the hand in the background; the turn after has the full tools.
    await dmAndReply(token, chief, "then marker-five", 2)
    await dmAndReply(token, chief, "then marker-six", 3)
    expect(turnTools("marker-six")[0]!.map((t) => t.name)).toEqual(expect.arrayContaining(["hands", "agent"]))
  })
  it("a hand paired between turns, then two more turns: every turn answers (no replayed thinking under another tools list)", async () => {
    const { token, chief } = await ownerWithChief("hands-between-signed")
    expect((await http("PUT", `/v1/hands/grants/${chief.id}`, token, { on: true })).status).toBe(200)
    await dmAndReply(token, chief, "SIGNED THINK turn one", 1)
    await pair(token, "sb-between")
    for (const [n, t] of [[2, "SIGNED THINK turn two"], [3, "SIGNED THINK turn three"], [4, "SIGNED THINK turn four"]] as const) await dmAndReply(token, chief, t, n)
    const replies = (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)
    expect(replies.map((m) => m.parts[0].text).filter((t: string) => t.includes("could not reach the model")), JSON.stringify(replies.map((m) => m.parts[0].text))).toHaveLength(0)
    expect(turnTools("turn four")[0]!.map((t) => t.name)).toEqual(expect.arrayContaining(["hands", "agent"]))
  })

  it("a run whose first answer is a tool call only: first_token_at is that first output, before the tool step", async () => {
    const { token, chief } = await ownerWithChief("hands-first-token")
    await dmAndReply(token, chief, 'first-token tool:hands {"action":"list"}', 1)
    const run = (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, token)).json.value.runs[0]
    const steps = (await http("GET", `/v1/chiefs/${chief.id}/runs/${run.id}?conversation=${chief.main_conversation}`, token)).json.value.steps as Array<any>
    const tool = steps.find((st) => st.kind === "tool")
    const talk = steps.find((st) => st.kind === "talk")
    expect(run.timing.first_token_at, JSON.stringify(run.timing)).toBeLessThanOrEqual(tool.at)
    expect(tool.ended_at).toBeGreaterThanOrEqual(tool.at)
    expect(talk.ended_at).toBeGreaterThanOrEqual(tool.ended_at)
  })

  it("one message makes a sandbox and starts an agent: one run, one reply, no 400 (the run continues once with the full tools)", async () => {
    const { token, chief } = await ownerWithChief("hands-one-msg")
    expect((await http("PUT", `/v1/hands/grants/${chief.id}`, token, { on: true })).status).toBe(200)
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(chief.main_conversation))
    const agentStarts: Array<any> = []
    // The test plays the sandbox machine: it pairs with the install code and dials the hand socket.
    let dialed = false
    const playMachine = async () => {
      const install = testSandboxInstalls.find((x) => x.name === "sb-one")
      if (!install || dialed) return
      dialed = true
      const key = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
      const paired = await http("POST", "/v1/hands/pair", "", { code: install.code, key_sha256: await sha(key), name: "sb-one", profile: "sandbox" })
      expect(paired.json.ok, JSON.stringify(paired.json)).toBe(true)
      const res = await worker.fetch(`https://api.test/v1/hands/${paired.json.value.hand}/socket`, { headers: { Upgrade: "websocket", authorization: `Bearer ${key}` } })
      const ws = res.webSocket!
      const send = (x: unknown) => ws.send(JSON.stringify(x))
      ws.addEventListener("message", (e) => {
        const f = JSON.parse(e.data as string)
        if (f.t !== "req" || f.action !== "agent.start") return
        agentStarts.push(f)
        send({ t: "res", id: f.id, ok: true, value: { session: "sess-one", harness: "codex", cwd: f.params.cwd } })
        send({ t: "event", session: "sess-one", seq: 1, event: { kind: "turn_start" } })
        send({ t: "event", session: "sess-one", seq: 2, event: { kind: "text", text: "Agent is on it." } })
        send({ t: "event", session: "sess-one", seq: 3, event: { kind: "turn_end", stop_reason: "end_turn" } })
      })
      ws.accept()
      send({ t: "hello", version: "test", profile: "sandbox", roots: ["/work"], agent_policy: "approve-edits", harnesses: ["claude", "codex", "opencode"], caps: ["levels"], os: "linux", arch: "x86_64", hostname: "sb-one" })
    }
    const key = "hands-one-msg-1"
    const text = 'SIGNED make a sandbox and start an agent then:agent {"action":"start","hand":"sb-one","harness":"codex","cwd":"/work","prompt":"say hi","wait_seconds":5} tool:hands {"action":"new_sandbox","name":"sb-one"}'
    expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: key, parts: [{ type: "text", text }] }, key)).ok).toBe(true)
    let replies: Array<any> = []
    for (let i = 0; i < 400 && replies.length === 0; i++) {
      await playMachine()
      replies = (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)
      if (replies.length === 0) [await fireAlarm(conv), await new Promise((r) => setTimeout(r, 25))]
    }
    for (let i = 0; i < 10; i++) [await fireAlarm(conv), await new Promise((r) => setTimeout(r, 25))]
    replies = (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)
    expect(replies, JSON.stringify(replies.map((m) => m.parts[0]?.text))).toHaveLength(1)
    expect(replies[0].parts[0].text, "the run failed (a 400?)").toContain("tool said")
    expect(agentStarts, "no agent was started").toHaveLength(1)
    expect(agentStarts[0].params).toMatchObject({ harness: "codex", cwd: "/work", prompt: "say hi" })
    const runs = (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, token)).json.value.runs
    expect(runs).toHaveLength(1)
    expect(runs[0]).toMatchObject({ status: "done", reply: { state: "posted" } })
    // Run timing: the run's first token is the first request's (before the continuation), and the continuation has its own.
    const tm = runs[0].timing
    expect(tm.first_token_at, JSON.stringify(tm)).toBeLessThan(tm.continuation_at)
    expect(tm.continuation_first_token_at).toBeGreaterThanOrEqual(tm.continuation_at)
    // Steps carry ended_at: the sandbox tool step ends at its result, after it started.
    const steps = (await http("GET", `/v1/chiefs/${chief.id}/runs/${runs[0].id}?conversation=${chief.main_conversation}`, token)).json.value.steps as Array<any>
    const sandboxStep = steps.find((st) => st.kind === "tool" && st.tool?.name === "hands")
    expect(sandboxStep.ended_at, JSON.stringify(sandboxStep)).toBeGreaterThanOrEqual(sandboxStep.at)
    expect(steps.filter((st) => st.kind === "talk").every((st) => typeof st.ended_at === "number")).toBe(true)
    expect(tm.first_token_at).toBeLessThanOrEqual(sandboxStep.at)
    // Within each pi turn the tools list stayed the same; the continuation had the full tools.
    const calls = fakeCalls.filter((c) => c.kind === "turn" && c.tools.length > 0 && c.firstUser.join("\n").includes("make a sandbox and start an agent"))
    // The continuation starts from the made hand: its first tool call is agent (no second hands list).
    expect(steps.filter((st) => st.kind === "tool").map((st) => st.tool?.name), JSON.stringify(steps.map((st) => st.tool?.name ?? st.kind))).toEqual(["hands", "agent"])
    const contText = calls.flatMap((c) => c.laterUsers).find((t) => t.includes("Your new hand is ready")) ?? ""
    expect(contText).toContain('"sb-one"')
    expect(contText).toMatch(/\(hand_[A-Za-z0-9]+\), online/)
    expect(contText).toContain("/root/proj")
    const root = calls.filter((c) => !c.laterUsers.join("\n").includes("Your new hand is ready")).map((c) => JSON.stringify(c.tools))
    const cont = calls.filter((c) => c.laterUsers.join("\n").includes("Your new hand is ready"))
    expect(new Set(root).size, `the tools changed inside the first pi turn: ${JSON.stringify(root)}`).toBe(1)
    expect(root[0]).not.toContain('"agent"')
    expect(cont.length, "no continuation").toBeGreaterThanOrEqual(1)
    expect(cont.every((c) => c.tools.some((t) => t.name === "agent")), "the continuation had no agent tool").toBe(true)
  })
})
