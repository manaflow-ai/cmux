import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest"
import { runInDurableObject } from "cloudflare:test"
import { fireAlarm } from "./setup/alarm.ts"
import { gatewayBaseUrl, mintRunToken, revokeAgentSession } from "../src/model-gateway/run-token.ts"
import { DAILY_CAP_NOTICE, TURN_FAILED_NOTICE } from "../src/chief-brain/brain-gateway.ts"

/**
 * The model gateway (model-gateway/gateway.ts) at the product boundary: a person writes to a Cloud
 * Chief over POST /v1/ops, the Chief's brain answers through the gateway, and the Claude route is
 * faked at its HTTP boundary. This file runs the route in `service-key` mode (the scoped service key
 * of the Chatmux route, 1f-D) with Opus and Sonnet served and a paid fallback:
 * - every request carries the service key, the payer team, the chief and a request id, the Bedrock
 *   model id and the Chief's effort; no person's session;
 * - each call holds and then charges prepaid credits, and the run records its token usage;
 * - a team with no credits gets no model call and one out-of-credits notice in the conversation;
 * - a paid fallback passes the same gate as the Chief's model: refused, there is no turn (no silent paid spend).
 * One file on purpose: it sets the route configuration for the Worker and replaces globalThis.fetch.
 */
const testEnv = env as unknown as Record<string, any>
const KEY = "chatmux_sk_test-not-a-real-key"
const SAVED = ["CHIEF_BRAIN_CLAUDE_AUTH", "CHIEF_BRAIN_CLAUDE_SERVICE_KEY", "CHIEF_BRAIN_CLAUDE_MODELS", "CHIEF_BRAIN_FALLBACK_MODEL", "CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA", "CHIEF_BRAIN_COMPACTOR_MODEL", "CHIEF_BRAIN_VIEW_BUDGET"].map((k) => [k, testEnv[k]] as const)
afterAll(() => {
  for (const [k, v] of SAVED) v === undefined ? delete testEnv[k] : (testEnv[k] = v)
})
beforeAll(() => {
  Object.assign(testEnv, { CHIEF_BRAIN_CLAUDE_AUTH: "service-key", CHIEF_BRAIN_CLAUDE_SERVICE_KEY: KEY, CHIEF_BRAIN_CLAUDE_MODELS: "claude-opus-5-5,claude-sonnet-5-5", CHIEF_BRAIN_FALLBACK_MODEL: "claude-haiku-5-5" })
})
afterEach(() => vi.restoreAllMocks())

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
  return { status: res.status, text: await res.clone().text(), json: (await res.json()) as any }
}
const op = async (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => (await http("POST", "/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })).json
const history = async (token: string, conversation: string) => (await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation, limit: 50 } })).json.value.messages as Array<any>
const meter = (team: string) => testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)) as { creditAdd(e: string, k: string, kind: string, m: number, a: string, r: string | null): Promise<unknown>; creditBalance(e: string, since: number, limit: number): Promise<{ balance_micros: number; held_micros: number }> }

/** One Bedrock event-stream answer (frame CRCs zero: the reader skips them), with usage incl. a cache read. */
const eventStream = (text: string): Uint8Array => {
  const events = [
    { type: "message_start", message: { id: "msg_fake", type: "message", role: "assistant", model: "claude", content: [], stop_reason: null, usage: { input_tokens: 12, cache_read_input_tokens: 900, cache_creation_input_tokens: 40, output_tokens: 1 } } },
    { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
    { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } },
    { type: "content_block_stop", index: 0 },
    { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 6 } },
    { type: "message_stop" }
  ]
  const frames = events.map((e) => {
    const payload = new TextEncoder().encode(JSON.stringify({ bytes: btoa(JSON.stringify(e)) }))
    const frame = new Uint8Array(16 + payload.length)
    new DataView(frame.buffer).setUint32(0, frame.length)
    frame.set(payload, 12)
    return frame
  })
  const out = new Uint8Array(frames.reduce((n, f) => n + f.length, 0))
  let at = 0
  for (const f of frames) [out.set(f, at), (at += f.length)]
  return out
}

interface Seen { readonly headers: Record<string, string>; readonly body: any }
const fakeRoute = () => {
  const real = globalThis.fetch
  const seen: Array<Seen> = []
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init)
    if (req.url.startsWith("https://claude.test/")) {
      const body = await req.json()
      // A body the route refuses (Bedrock's validation answer).
      if (JSON.stringify(body).includes("FORCE_400")) return Response.json({ message: "tools.0.custom.defer_loading: Extra inputs are not permitted" }, { status: 400 })
      seen.push({ headers: Object.fromEntries(req.headers.entries()), body })
      return new Response(eventStream(`Routed answer ${seen.length}`), { headers: { "content-type": "application/vnd.amazon.eventstream", "x-bedrock-region": "us-west-2" } })
    }
    return real(input, init)
  })
  return seen
}

const owner = async (sub: string, credits: number, model: string, effort = "low", allow: false | "user" | "team" = false) => {
  const token = await sessionToken(sub)
  const ensured = (await op(token, "user.ensure", {})).value
  const team = ensured.personal_team as string
  // A third allowed owner, on the no-deploy list (read at every call).
  // By user id, or by the user's personal team id (production lists people by team id).
  if (allow) testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA = `${testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA ?? ""},${allow === "team" ? team : ensured.id}`
  if (credits > 0) await meter(team).creditAdd(team, `grant-${sub}`, "grant", Math.round(credits * 1e6), "test", "gateway test")
  const chief = (await op(token, "chief.create", { display_name: "Gateway Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(ensured.id))
  let on = { status: 0, json: {} as any, text: "" }
  for (let i = 0; i < 20 && on.status !== 200; i++) {
    await fireAlarm(userDO)
    on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true, model, effort })
  }
  expect(on.status, on.text).toBe(200)
  return { token, chief, team }
}

/** Drives the wake path until `done` holds (bounded). */
const drive = async (conversation: string, chief: string, done: () => Promise<boolean>, what: string) => {
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conversation))
  const brain = testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${chief}/${conversation}`))
  for (let i = 0; i < 200; i++) {
    if (await done()) return
    await fireAlarm(conv)
    if (i % 10 === 9) await fireAlarm(brain)
    await new Promise((r) => setTimeout(r, 50))
  }
  throw new Error(`timed out waiting for ${what}`)
}
/** A run of the chief's brain in that conversation with this status (a hand's agent works for a running run). */
const runState = (chief: string, conversation: string, run: string, status: string) =>
  runInDurableObject(testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${chief}/${conversation}`)), async (_i: unknown, state: DurableObjectState) => {
    state.storage.sql.exec(`INSERT INTO cb_turn (id, conversation, trigger_message, trigger_kind, last_seq, status, model, started) VALUES (?, ?, 'msg_x', 'chief', 0, ?, 'claude-opus-5-5', ?) ON CONFLICT (id) DO UPDATE SET status = excluded.status`, run, conversation, status, Date.now())
  })
const runsOf = async (token: string, chief: string, conversation: string) => (await http("GET", `/v1/chiefs/${chief}/runs?conversation=${conversation}`, token)).json.value?.runs ?? []

describe("Model gateway: service-key route, credits, usage, paid fallback", { timeout: 120_000 }, () => {
  it("sends Sonnet with the service key, payer team, chief, request id and effort; charges credits and records usage", async () => {
    const seen = fakeRoute()
    const { token, chief, team } = await owner("brain-claude-ok", 5, "claude-sonnet-5-5", "medium")
    const before = await meter(team).creditBalance(team, 0, 5)
    expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: "g1", parts: [{ type: "text", text: "route check" }] }, "g1")).ok).toBe(true)
    await drive(chief.main_conversation, chief.id, async () => (await history(token, chief.main_conversation)).some((m) => m.author === chief.id), "the reply")
    const reply = (await history(token, chief.main_conversation)).find((m) => m.author === chief.id)!
    expect(reply.parts[0].text).toBe("Routed answer 1")
    expect(seen).toHaveLength(1)
    const s = seen[0]!
    expect(s.headers["x-api-key"]).toBe(KEY)
    expect(s.headers["x-stack-auth"]).toBeUndefined()
    expect(s.headers["x-cmux-team-id"]).toBe(team)
    expect(s.headers["x-cmux-chief-id"]).toBe(chief.id)
    expect(s.headers["x-request-id"]).toMatch(/^[A-Za-z0-9._:-]{1,128}$/)
    expect(s.headers["user-agent"]).toMatch(/cmux-cloud-chief/)
    expect(s.body).toMatchObject({ anthropic_version: "bedrock-2023-05-31", stream: true, model: "global.anthropic.claude-sonnet-5-5", output_config: { effort: "medium" } })
    // Usage on the run (cache hit is measurable) and the call charged to the team's prepaid credits.
    await drive(chief.main_conversation, chief.id, async () => (await runsOf(token, chief.id, chief.main_conversation))[0]?.usage !== undefined, "run usage")
    const run = (await runsOf(token, chief.id, chief.main_conversation))[0]
    expect(run).toMatchObject({ model: "claude-sonnet-5-5", status: "done", usage: { input: 12, cache_read: 900, cache_write: 40, output: 6, calls: 1 } })
    // At the Bedrock price (global profile, 1-hour cache writes), not the first-party catalog's: 12 x $2 + 900 x $0.10 + 40 x $4 + 6 x $10 per million.
    expect(run.cost_usd).toBeCloseTo((12 * 2 + 900 * 0.1 + 40 * 4 + 6 * 10) / 1e6, 10)
    // Timing: the first model request after the run started, the first token after the request.
    expect(run.timing.request_at).toBeGreaterThanOrEqual(run.started_at)
    // The Bedrock region that answered (the route's x-bedrock-region) is on the run.
    expect(run.timing.regions).toEqual(["us-west-2"])
    expect(run.timing.first_token_at).toBeGreaterThanOrEqual(run.timing.request_at)
    // The wake path's marks, in order: the brain got the wake, the turn was admitted, the view was ready, the run started.
    expect(run.timing.wake_at).toBeLessThanOrEqual(run.timing.admitted_at)
    expect(run.timing.admitted_at).toBeLessThanOrEqual(run.timing.settled_at)
    expect(run.timing.settled_at).toBeLessThanOrEqual(run.started_at)
    const after = await meter(team).creditBalance(team, 0, 5)
    expect(after.balance_micros).toBeLessThan(before.balance_micros)
    expect(after.held_micros).toBe(0)
    for (const body of [JSON.stringify(run), JSON.stringify(reply)]) expect(body).not.toContain(KEY)
  })

  it("makes no model call for a team with no credits and posts one out-of-credits notice", async () => {
    const seen = fakeRoute()
    const { token, chief } = await owner("brain-claude-fail", 0, "claude-opus-5-5")
    for (const k of ["n1", "n2"]) {
      expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: k, parts: [{ type: "text", text: `hello ${k}` }] }, k)).ok).toBe(true)
      await drive(chief.main_conversation, chief.id, async () => (await history(token, chief.main_conversation)).some((m) => m.author === chief.id), "the notice")
    }
    // Let the second wake run its course, then: one notice, no reply, no request upstream.
    let ticks = 0
    await drive(chief.main_conversation, chief.id, async () => ++ticks > 40, "the second wake")
    const mine = (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)
    expect(mine).toHaveLength(1)
    expect(mine[0].parts[0].text).toContain("out of Cloud credits")
    expect(seen).toHaveLength(0)
  })

  it("refuses a paid fallback through the same gate: no turn and no paid call when the Chief's model is refused", async () => {
    const seen = fakeRoute()
    // The owner's daily limit of paid turns (1) is spent by a first turn: then Opus is refused, and so is
    // the paid fallback (Sonnet, which the route serves: before the gate, the turn ran on it unchecked).
    testEnv.CHIEF_BRAIN_CLAUDE_DAILY_TURNS = "1"
    testEnv.CHIEF_BRAIN_FALLBACK_MODEL = "claude-sonnet-5-5"
    try {
      const { token, chief } = await owner("brain-gateway-cap", 5, "claude-opus-5-5", "low", "user")
      expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: "f0", parts: [{ type: "text", text: "first" }] }, "f0")).ok).toBe(true)
      await drive(chief.main_conversation, chief.id, async () => (await history(token, chief.main_conversation)).some((m) => m.author === chief.id), "the first reply")
      expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: "f1", parts: [{ type: "text", text: "anyone?" }] }, "f1")).ok).toBe(true)
      await drive(chief.main_conversation, chief.id, async () => (await runsOf(token, chief.id, chief.main_conversation)).some((r: any) => r.status === "failed"), "the failed run")
      const run = (await runsOf(token, chief.id, chief.main_conversation))[0]
      expect(run.status).toBe("failed")
      expect(run.model).toBe("claude-opus-5-5")
      expect(seen).toHaveLength(1)
      expect(run.error).toContain("daily_cap")
      // Not silent: the Chief says why, once per conversation per day; a second refused turn adds nothing.
      await drive(chief.main_conversation, chief.id, async () => (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id).length >= 2, "the cap notice")
      expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: "f2", parts: [{ type: "text", text: "still there?" }] }, "f2")).ok).toBe(true)
      await drive(chief.main_conversation, chief.id, async () => (await runsOf(token, chief.id, chief.main_conversation)).filter((r: any) => r.status === "failed").length >= 2, "the second failed run")
      const posted = (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)
      expect(posted.map((m) => m.parts[0].text)).toEqual(["Routed answer 1", DAILY_CAP_NOTICE])
    } finally {
      delete testEnv.CHIEF_BRAIN_CLAUDE_DAILY_TURNS
      testEnv.CHIEF_BRAIN_FALLBACK_MODEL = "claude-haiku-5-5"
    }
  })

  it("serves a hand's coding agent over HTTP with a per-run token: Anthropic Messages in, events out, charged to the team", async () => {
    const seen = fakeRoute()
    const { chief, team } = await owner("brain-gateway-http", 5, "claude-opus-5-5", "low", "team")
    const ownerId = (await op(await sessionToken("brain-gateway-http"), "user.ensure", {})).value.id as string
    await runState(chief.id, chief.main_conversation, "run_500", "running")
    const { token } = await mintRunToken(testEnv as any, { team, chief: chief.id, owner: ownerId, run: "run_500", conversation: chief.main_conversation })
    expect(gatewayBaseUrl(testEnv as any)).toBe("https://api.test/v1/model-gateway")
    const before = await meter(team).creditBalance(team, 0, 5)
    const body = { model: "claude-sonnet-5-5", max_tokens: 1000, stream: true, messages: [{ role: "user", content: "write a haiku" }] }
    const call = (auth: Record<string, string>, b: unknown = body) => worker.fetch("https://api.test/v1/model-gateway/v1/messages", { method: "POST", headers: { "content-type": "application/json", ...auth }, body: JSON.stringify(b) })
    const res = await call({ authorization: `Bearer ${token}` })
    expect(res.status, await res.clone().text()).toBe(200)
    expect(res.headers.get("content-type")).toContain("text/event-stream")
    const events = await res.text()
    expect(events).toContain("Routed answer 1")
    expect(events).toContain("message_stop")
    expect(seen).toHaveLength(1)
    expect(seen[0]!.headers["x-api-key"]).toBe(KEY)
    expect(seen[0]!.headers["x-cmux-team-id"]).toBe(team)
    expect(seen[0]!.headers["x-cmux-chief-id"]).toBe(chief.id)
    expect(seen[0]!.body).toMatchObject({ model: "global.anthropic.claude-sonnet-5-5", anthropic_version: "bedrock-2023-05-31" })
    // The call was held and then charged (usage from the stream), with no hold left.
    let after = await meter(team).creditBalance(team, 0, 5)
    for (let i = 0; i < 50 && after.balance_micros === before.balance_micros; i++) [await new Promise((r) => setTimeout(r, 20)), (after = await meter(team).creditBalance(team, 0, 5))]
    expect(after.balance_micros).toBeLessThan(before.balance_micros)
    expect(after.held_micros).toBe(0)
    // Claude Code's request shape: betas in the header map into Bedrock's anthropic_beta (unknown ones dropped),
    // fields Bedrock does not take (context_management) are dropped, not forwarded.
    const cc = await call({ authorization: `Bearer ${token}`, "anthropic-beta": "interleaved-thinking-2025-05-14,claude-code-20250219,oauth-2025-04-20" }, { ...body, context_management: { edits: [] }, metadata: { user_id: "u" }, thinking: { type: "enabled", budget_tokens: 1024 } })
    expect(cc.status, await cc.clone().text()).toBe(200)
    await cc.text()
    const ccBody = seen.at(-1)!.body
    expect(ccBody.anthropic_beta).toEqual(["interleaved-thinking-2025-05-14"])
    expect(ccBody.context_management).toBeUndefined()
    expect(ccBody.metadata).toBeUndefined()
    expect(ccBody.thinking).toEqual({ type: "enabled", budget_tokens: 1024 })
    // Claude Code's dated and small/fast model names map to the family's 5.5 model, or to a model the route serves.
    const small = await call({ authorization: `Bearer ${token}` }, { ...body, model: "claude-haiku-4-5-20251001" })
    expect(small.status, await small.clone().text()).toBe(200)
    await small.text()
    expect(seen.at(-1)!.body.model).toBe("global.anthropic.claude-opus-5-5")
    // A refusal of the route reaches the caller with its reason (Claude Code shows it), not a bare status.
    const refused = await call({ authorization: `Bearer ${token}` }, { ...body, messages: [{ role: "user", content: "FORCE_400" }] })
    expect(refused.status).toBe(400)
    expect(((await refused.json()) as any).error.message).toContain("defer_loading: Extra inputs are not permitted")
    // x-api-key works too (stock clients); refusals: no token, a person's session token, a model it does not serve, no streaming.
    expect((await call({ "x-api-key": token })).status).toBe(200)
    expect((await call({})).status).toBe(401)
    expect((await call({ authorization: `Bearer ${await sessionToken("brain-gateway-http")}` })).status).toBe(401)
    expect((await call({ authorization: `Bearer ${token}` }, { ...body, model: "gpt-5" })).status).toBe(400)
    expect((await call({ authorization: `Bearer ${token}` }, { ...body, stream: false })).status).toBe(400)
    expect(seen).toHaveLength(4)
    // Spend cap: a token minted with a tiny budget is refused (429) before the route, the run still running.
    const tiny = (await mintRunToken(testEnv as any, { team, chief: chief.id, owner: ownerId, run: "run_500", conversation: chief.main_conversation }, { capUsd: 0.0001 })).token
    expect((await call({ authorization: `Bearer ${tiny}` })).status).toBe(429)
    // Revoke: the run ends, and the same token stops working at once (401), long before its expiry.
    await runState(chief.id, chief.main_conversation, "run_500", "done")
    expect((await call({ authorization: `Bearer ${token}` })).status).toBe(401)
    expect(seen).toHaveLength(4)
  })

  it("counts the daily paid-model limit per owner, and never falls back to an unmetered model for a paid Chief", async () => {
    const seen = fakeRoute()
    testEnv.CHIEF_BRAIN_CLAUDE_DAILY_TURNS = "1"
    testEnv.CHIEF_BRAIN_FALLBACK_MODEL = "fake"
    try {
      const a = await owner("brain-cap-a", 5, "claude-opus-5-5", "low", "user")
      const b = await owner("brain-cap-b", 5, "claude-opus-5-5", "low", "user")
      for (const [who, k] of [[a, "a1"], [a, "a2"], [b, "b1"]] as const) {
        expect((await op(who.token, "message.send", { conversation: who.chief.main_conversation, client_msg_id: k, parts: [{ type: "text", text: `q ${k}` }] }, k)).ok).toBe(true)
        await drive(who.chief.main_conversation, who.chief.id, async () => (await runsOf(who.token, who.chief.id, who.chief.main_conversation)).filter((r: any) => r.status !== "running").length >= (k === "a2" ? 2 : 1), `run ${k}`)
      }
      const runsA = await runsOf(a.token, a.chief.id, a.chief.main_conversation)
      const runsB = await runsOf(b.token, b.chief.id, b.chief.main_conversation)
      // Owner a: one Opus turn, then refused (no silent fake/unmetered fallback); owner b still gets its turn.
      expect(runsA.map((r: any) => [r.status, r.model])).toEqual([["failed", "claude-opus-5-5"], ["done", "claude-opus-5-5"]])
      expect(runsA[0].error).toContain("no paid fallback")
      expect(runsB.map((r: any) => [r.status, r.model])).toEqual([["done", "claude-opus-5-5"]])
      expect(seen).toHaveLength(2)
    } finally {
      delete testEnv.CHIEF_BRAIN_CLAUDE_DAILY_TURNS
      testEnv.CHIEF_BRAIN_FALLBACK_MODEL = "claude-haiku-5-5"
    }
  })

  it("counts paid turns in each owner's own object and the deployment bound by leases, not one holder call per turn", async () => {
    fakeRoute()
    testEnv.CHIEF_BRAIN_CLAUDE_DAILY_TURNS_TOTAL = "1"
    try {
      const a = await owner("brain-shard-a", 5, "claude-opus-5-5", "low", "user")
      for (const k of ["s1", "s2"]) {
        expect((await op(a.token, "message.send", { conversation: a.chief.main_conversation, client_msg_id: k, parts: [{ type: "text", text: `q ${k}` }] }, k)).ok).toBe(true)
        await drive(a.chief.main_conversation, a.chief.id, async () => (await runsOf(a.token, a.chief.id, a.chief.main_conversation)).filter((r: any) => r.status !== "running").length >= (k === "s2" ? 2 : 1), `run ${k}`)
      }
      const runs = await runsOf(a.token, a.chief.id, a.chief.main_conversation)
      // The bound of 1 holds across the lease: one turn ran, the second was refused.
      expect(runs.map((r: any) => r.status)).toEqual(["failed", "done"])
      const day = new Date().toISOString().slice(0, 10)
      const rows = (name: string) => runInDurableObject(testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(name)), async (_i: unknown, s: DurableObjectState) => s.storage.sql.exec(`SELECT name, value FROM cb_config WHERE name LIKE 'claude.%' AND name != 'claude.access' AND name != 'claude.refresh'`).toArray() as Array<{ name: string; value: string }>)
      const user = a.chief.id && (await op(a.token, "user.ensure", {})).value.id
      // The holder keeps only the deployment's lease total; the owner's count lives in the owner's object.
      expect((await rows("claude-david-auth")).filter((r) => r.name.includes(user))).toEqual([])
      expect((await rows(`claude-turns/${user}`)).find((r) => r.name === `claude.turns:${user}:${day}`)?.value).toBe("1")
    } finally {
      delete testEnv.CHIEF_BRAIN_CLAUDE_DAILY_TURNS_TOTAL
    }
  })

  it("names the route's refusal in Run.error when a turn fails, and tells the person once", async () => {
    const seen = fakeRoute()
    const { token, chief } = await owner("brain-gateway-fail", 5, "claude-opus-5-5", "low", "user")
    expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: "x1", parts: [{ type: "text", text: "FORCE_400 please" }] }, "x1")).ok).toBe(true)
    await drive(chief.main_conversation, chief.id, async () => (await runsOf(token, chief.id, chief.main_conversation)).some((r: any) => r.status === "failed"), "the failed run")
    const run = (await runsOf(token, chief.id, chief.main_conversation))[0]
    expect(run.error).toContain("Extra inputs are not permitted")
    await drive(chief.main_conversation, chief.id, async () => (await history(token, chief.main_conversation)).some((m) => m.author === chief.id), "the failure notice")
    expect((await history(token, chief.main_conversation)).filter((m) => m.author === chief.id).map((m) => m.parts[0].text)).toEqual([TURN_FAILED_NOTICE])
    expect(seen).toHaveLength(0)
  })

  it("keeps an agent token working while its agent session lives, past the Chief's turn, and stops it when the session ends", async () => {
    const seen = fakeRoute()
    const { chief, team } = await owner("brain-gateway-agent", 5, "claude-opus-5-5", "low", "user")
    const ownerId = (await op(await sessionToken("brain-gateway-agent"), "user.ensure", {})).value.id as string
    await runState(chief.id, chief.main_conversation, "run_600", "running")
    const minted = await mintRunToken(testEnv as any, { team, chief: chief.id, owner: ownerId, run: "run_600", conversation: chief.main_conversation }, { agent: true })
    const brain = testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${chief.id}/${chief.main_conversation}`))
    await brain.runToken("run_600", minted.jti, 0, { op: "open" })
    await brain.runToken("run_600", minted.jti, 0, { op: "bind", hand: "hand_1", session: "ses_1" })
    const call = () => worker.fetch("https://api.test/v1/model-gateway/v1/messages", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${minted.token}` }, body: JSON.stringify({ model: "claude-opus-5-5", max_tokens: 100, stream: true, messages: [{ role: "user", content: "hi" }] }) })
    // The Chief's turn ends; the agent session still runs, so its token still works.
    await runState(chief.id, chief.main_conversation, "run_600", "done")
    const r1 = await call()
    expect(r1.status, await r1.clone().text()).toBe(200)
    await r1.text()
    // The session ends (the hand's hook, or the Chief cancels it): the token stops at once.
    await revokeAgentSession(testEnv as any, chief.id, chief.main_conversation, "hand_1", "ses_1")
    expect((await call()).status).toBe(401)
    expect(seen).toHaveLength(1)
  })

  it("refuses a run token whose team has no credits (402) without calling the route", async () => {
    const seen = fakeRoute()
    const { chief, team } = await owner("brain-gateway-broke", 0, "claude-opus-5-5", "low", "user")
    const ownerId = (await op(await sessionToken("brain-gateway-broke"), "user.ensure", {})).value.id as string
    await runState(chief.id, chief.main_conversation, "run_501", "running")
    const { token } = await mintRunToken(testEnv as any, { team, chief: chief.id, owner: ownerId, run: "run_501", conversation: chief.main_conversation })
    const res = await worker.fetch("https://api.test/v1/model-gateway/v1/messages", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ model: "claude-opus-5-5", max_tokens: 100, stream: true, messages: [{ role: "user", content: "hi" }] }) })
    expect(res.status).toBe(402)
    expect(((await res.json()) as any).error.message).toContain("out of Cloud credits")
    expect(seen).toHaveLength(0)
  })
})

describe("Model gateway: the compactor on the service-key route", { timeout: 120_000 }, () => {
  const compacting = () => {
    // Haiku served and the default compactor; a small view budget (test only) makes every turn's view fold.
    Object.assign(testEnv, { CHIEF_BRAIN_CLAUDE_MODELS: "claude-opus-5-5,claude-sonnet-5-5,claude-haiku-5-5", CHIEF_BRAIN_COMPACTOR_MODEL: "claude-haiku-5-5", CHIEF_BRAIN_VIEW_BUDGET: "400" })
  }
  afterEach(() => {
    for (const [k, v] of SAVED.filter(([k]) => k === "CHIEF_BRAIN_COMPACTOR_MODEL" || k === "CHIEF_BRAIN_VIEW_BUDGET")) v === undefined ? delete testEnv[k] : (testEnv[k] = v)
    testEnv.CHIEF_BRAIN_CLAUDE_MODELS = "claude-opus-5-5,claude-sonnet-5-5"
  })
  const notes = ["first long team note about the harbor crew ".repeat(30), "second long team note about the quarry crew ".repeat(30), "third question"]

  it("sends the Haiku compactor's call with the service key, payer team, chief and request id, at effort high", async () => {
    compacting()
    const seen = fakeRoute()
    const { token, chief, team } = await owner("brain-compact-route", 5, "claude-opus-5-5", "low", "user")
    for (const [n, text] of notes.entries()) {
      expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: `cp-${n}`, parts: [{ type: "text", text }] }, `cp-${n}`)).ok).toBe(true)
      await drive(chief.main_conversation, chief.id, async () => (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id).length > n, `reply ${n}`)
    }
    const haiku = () => seen.filter((s) => s.body?.model === "global.anthropic.claude-haiku-5-5")
    await drive(chief.main_conversation, chief.id, async () => haiku().length > 0, "a compactor call on the route")
    const c = haiku()[0]!
    // Before: the call failed in the route's fetch (no x-cmux-team-id), so it never reached the route.
    expect(c.headers["x-api-key"]).toBe(KEY)
    expect(c.headers["x-cmux-team-id"]).toBe(team)
    expect(c.headers["x-cmux-chief-id"]).toBe(chief.id)
    expect(c.headers["x-request-id"]).toMatch(/^[A-Za-z0-9._:-]{1,128}$/)
    expect(c.body).toMatchObject({ output_config: { effort: "high" } })
  })

  it("never runs a paid compactor for an owner off the paid allow-list", async () => {
    compacting()
    const seen = fakeRoute()
    const { token, chief } = await owner("brain-compact-unpaid", 5, "fake")
    for (const [n, text] of notes.entries()) {
      expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: `cu-${n}`, parts: [{ type: "text", text }] }, `cu-${n}`)).ok).toBe(true)
      await drive(chief.main_conversation, chief.id, async () => (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id).length > n, `reply ${n}`)
    }
    // Before: the default compactor (Haiku) ran for this owner and charged the team.
    expect(seen.filter((s) => s.body?.model === "global.anthropic.claude-haiku-5-5")).toHaveLength(0)
  })
})
