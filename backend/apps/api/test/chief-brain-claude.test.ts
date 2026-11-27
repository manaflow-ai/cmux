import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { afterEach, describe, expect, it, vi } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"
import { forgetClaudeAuth } from "../src/chief-brain/claude-auth.ts"
import { MODEL_UNAVAILABLE_NOTICE, TURN_FAILED_NOTICE } from "../src/chief-brain/brain-gateway.ts"

/**
 * A Cloud Chief on Claude through the metered route (chief-brain/claude-auth.ts, models.ts): the
 * brain signs every request with the route's X-Stack-Auth (refreshed by the holder object, kept in
 * its storage), sends a streamed Messages request for claude-opus-5-5, and posts the answer. A failed
 * sign-in runs the turn on the fallback model and logs only "claude-david auth failed". The route and
 * the refresh are faked at their HTTP boundary; no token bytes may reach a reply, a run or a log.
 * One file on purpose: it replaces globalThis.fetch.
 */
const testEnv = env as unknown as { CHIEF_BRAIN_MODEL?: string; CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA?: string; STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace; CHIEF_BRAIN_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const REFRESH = "test-refresh-token-not-real"
const fakeJwt = (exp: number, iat?: number) => ["e30", btoa(JSON.stringify({ exp, ...(iat === undefined ? {} : { iat }) })).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_"), "sig"].join(".")
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

/** The Messages stream events of one answer, as Bedrock's binary event stream (frame CRCs zero: the reader skips them). */
const eventStream = (text: string): Uint8Array => {
  const events = [
    { type: "message_start", message: { id: "msg_fake", type: "message", role: "assistant", model: "claude-opus-5-5", content: [], stop_reason: null, usage: { input_tokens: 12, output_tokens: 1 } } },
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

interface Seen { readonly url: string; readonly stackAuth: { accessToken?: string; refreshToken?: string } | null; readonly apiKey: string | null; readonly beta: string | null; readonly cacheHeader: string | null; readonly body: any }
/** The route and the refresh at their HTTP boundary; everything else goes to the real fetch. */
const fakeRoute = (refresh: "ok" | "fail") => {
  const real = globalThis.fetch
  const seen: Array<Seen> = []
  let refreshes = 0
  const refreshHeaders: Array<string | null> = []
  // A 10-minute token (the refresh margin must stay under half its life).
  const fresh = fakeJwt(Math.floor(Date.now() / 1000) + 600, Math.floor(Date.now() / 1000))
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init)
    if (req.url.startsWith("https://auth.test/")) {
      refreshes++
      refreshHeaders.push(req.headers.get("x-hexclave-refresh-token"))
      return refresh === "ok" ? Response.json({ access_token: fresh }) : Response.json({ error: "refresh token revoked" }, { status: 401 })
    }
    if (req.url.startsWith("https://claude.test/")) {
      const raw = req.headers.get("x-stack-auth")
      const body = await req.json()
      seen.push({ url: req.url, stackAuth: raw ? JSON.parse(raw) : null, apiKey: req.headers.get("x-api-key"), beta: req.headers.get("anthropic-beta"), cacheHeader: req.headers.get("x-cmux-cache-blocks"), body })
      return new Response(eventStream(`Opus answers turn ${seen.length}`), { headers: { "content-type": "application/vnd.amazon.eventstream" } })
    }
    return real(input, init)
  })
  return { seen, fresh, refreshHeaders, refreshes: () => refreshes }
}
afterEach(() => vi.restoreAllMocks())

/** Prepaid credits for the owner's personal team (Claude turns hold and charge credits; model-gateway/gateway.ts). */
const grant = async (team: string, usd: number) => {
  const meters = (env as unknown as { USAGE_METER_DO: DurableObjectNamespace }).USAGE_METER_DO
  await (meters.get(meters.idFromName(team)) as unknown as { creditAdd(e: string, k: string, kind: string, m: number, a: string, r: string | null): Promise<unknown> }).creditAdd(team, `grant-${team}`, "grant", Math.round(usd * 1e6), "test", "claude test")
}
const ownerWithClaudeChief = async (sub: string) => {
  const token = await sessionToken(sub)
  const ensured = (await op(token, "user.ensure", {})).value
  const user = ensured.id as string
  await grant(ensured.personal_team as string, 5)
  const chief = (await op(token, "chief.create", { display_name: "Opus Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  let on = { status: 0, json: {} as any, text: "" }
  for (let i = 0; i < 20 && on.status !== 200; i++) {
    await fireAlarm(userDO)
    on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true, model: "claude-opus-5-5", role: "Release captain" })
  }
  expect(on.status, on.text).toBe(200)
  return { token, chief }
}
const replies = async (token: string, conversation: string, chief: string, n: number) => {
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conversation))
  const brain = testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${chief}/${conversation}`))
  for (let i = 0; i < 200; i++) {
    const mine = (await history(token, conversation)).filter((m) => m.author === chief)
    if (mine.length >= n) return mine
    await fireAlarm(conv)
    if (i % 10 === 9) await fireAlarm(brain)
    await new Promise((r) => setTimeout(r, 50))
  }
  throw new Error(`no ${n} chief replies`)
}
// The holder's stored token and this isolate's cached copy (claude-auth.ts claudeAuthFor) both go.
const forgetRefreshed = () => (forgetClaudeAuth(), runInDurableObject(testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName("claude-david-auth")), async (_i, state) => void state.storage.sql.exec("DELETE FROM cb_config WHERE name = 'claude.access'")))

describe("Cloud Chief on Claude through the metered route", { timeout: 120_000 }, () => {
  it("signs each streamed Opus request (Bedrock body, event stream answer) with a refreshed X-Stack-Auth and posts the answer; no token reaches a reply or run", async () => {
    const route = fakeRoute("ok")
    const { token, chief } = await ownerWithClaudeChief("brain-claude-ok")
    for (const [i, text] of ["first question", "second question"].entries()) {
      expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: `q${i}`, parts: [{ type: "text", text }] }, `q${i}`)).ok).toBe(true)
      await replies(token, chief.main_conversation, chief.id, i + 1)
    }
    const posted = (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)
    expect(posted.map((m) => m.parts[0].text)).toEqual(["Opus answers turn 1", "Opus answers turn 2"])
    // Every request: the route's path, streamed, Opus, signed with the refreshed access token, no API key.
    expect(route.seen).toHaveLength(2)
    for (const s of route.seen) {
      // The Anthropic client adds ?beta=true; the route matches the path.
      expect(new URL(s.url).origin + new URL(s.url).pathname).toBe("https://claude.test/api/claude-david/v1/messages")
      // Bedrock's body: its version, streamed, no model or metadata key (the route names Opus in its Bedrock URL).
      expect(s.body).toMatchObject({ anthropic_version: "bedrock-2023-05-31", stream: true })
      expect(s.body.model).toBeUndefined()
      expect(s.body.metadata).toBeUndefined()
      // The system prompt is Bedrock's top-level system; no system-role message, no output_config.
      expect(JSON.stringify(s.body.system)).toContain("You are a Chief")
      expect(s.body.messages.some((m: { role: string; output_config?: unknown }) => m.role === "system" || m.output_config !== undefined)).toBe(false)
      expect(s.stackAuth).toEqual({ accessToken: route.fresh, refreshToken: REFRESH })
      expect(s.apiKey).toBeNull()
      expect(s.beta).toBeNull()
      expect(JSON.stringify(s.body)).not.toContain(REFRESH)
    }
    // The view is rendered for each turn (the reference client's Memory.view(mem, from)): every message
    // before the turn's new ones is a view line, and after "</chat>" come only the new messages. Bedrock
    // reads only at a mark, so each turn marks the view's last whole block (the header while there is
    // none): turn 1 writes it, turn 2 starts with the same block and marks it again (reads it).
    const blocksOf = (s: Seen) => (s.body.messages.find((m: { role: string }) => m.role === "user").content as Array<{ text: string; cache_control?: { ttl?: string } }>)
    const [b1, b2] = [blocksOf(route.seen[0]!), blocksOf(route.seen[1]!)]
    const end1 = b1.findIndex((x) => x.text.endsWith("</chat>"))
    const end2 = b2.findIndex((x) => x.text.endsWith("</chat>"))
    expect(end1).toBeGreaterThan(0)
    expect(b1.slice(end1 + 1).map((b) => b.text)).toEqual([expect.stringMatching(/\|user: .*first question/)])
    expect(b2.slice(end2 + 1).map((b) => b.text)).toEqual([expect.stringMatching(/\|user: .*second question/)])
    const view2 = b2.slice(0, end2 + 1).map((b) => b.text).join("")
    expect(view2).toContain("first question")
    expect(view2).toContain("Opus answers turn 1")
    expect(view2).not.toContain("second question")
    expect(b2[0]!.text).toBe(b1[0]!.text)
    expect(b1[end1 - 1]!.cache_control).toMatchObject({ type: "ephemeral", ttl: "1h" })
    expect(b2[end2 - 1]!.cache_control).toMatchObject({ type: "ephemeral", ttl: "1h" })
    // The mark indices travel to the body conversion only: the route never sees their header.
    for (const s of route.seen) expect(s.cacheHeader).toBeNull()
    // The expired configured token was refreshed once; the second turn used the stored one.
    expect(route.refreshes()).toBe(1)
    expect(route.refreshHeaders).toEqual([REFRESH])
    const run = await http("GET", `/v1/chiefs/${chief.id}/runs/${posted[0].parts[1].session}?conversation=${chief.main_conversation}`, token)
    expect(run.json.value.run).toMatchObject({ model: "claude-opus-5-5", status: "done" })
    for (const body of [run.text, JSON.stringify(posted), (await http("GET", `/v1/chiefs/${chief.id}/brain`, token)).text]) {
      expect(body).not.toContain(REFRESH)
      expect(body).not.toContain(route.fresh)
    }
  })

  it("refuses Claude for an owner off the allow-list and for the compactor", async () => {
    const token = await sessionToken("brain-claude-other")
    const user = (await op(token, "user.ensure", {})).value.id as string
    const chief = (await op(token, "chief.create", {}, "chief-claude-other")).value as { id: string }
    const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
    let r = { status: 0, json: {} as any, text: "" }
    for (let i = 0; i < 20 && (r.status === 0 || r.status === 403); i++) {
      await fireAlarm(userDO)
      r = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { model: "claude-opus-5-5" })
    }
    expect(r.status, r.text).toBe(409)
    expect(r.json.error.code).toBe("chief_claude_unavailable")
    expect((await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { compactor_model: "claude-opus-5-5" })).status).toBe(400)
  })

  it("refuses turning on a Chief whose model is Claude for an owner off the allow-list (production's default model), allows a listed owner", async () => {
    const saved = [testEnv.CHIEF_BRAIN_MODEL, testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA] as const
    // Production's default turn model is Claude: a new Chief's brain starts on it without naming it.
    testEnv.CHIEF_BRAIN_MODEL = "claude-opus-5-5"
    try {
      const enable = async (sub: string) => {
        const token = await sessionToken(sub)
        const user = (await op(token, "user.ensure", {})).value.id as string
        const chief = (await op(token, "chief.create", {}, `chief-${sub}`)).value as { id: string }
        const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
        let r = { status: 0, json: {} as any, text: "" }
        // 403 / chief_archived: the chief record has not reached the brain yet.
        for (let i = 0; i < 20 && (r.status === 0 || r.status === 403 || r.json?.error?.code === "chief_archived"); i++) {
          await fireAlarm(userDO)
          r = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true })
        }
        return { r, token, chief, user }
      }
      const off = await enable("brain-claude-enable-off")
      expect(off.r.status, off.r.text).toBe(409)
      expect(off.r.json.error.code).toBe("chief_claude_unavailable")
      const status = await http("GET", `/v1/chiefs/${off.chief.id}/brain`, off.token)
      expect(status.json.value.config).toMatchObject({ enabled: false, model: "claude-opus-5-5" })
      // A listed owner turns the same Chief shape on with the same patch.
      const sessionUser = (await op(await sessionToken("brain-claude-enable-on"), "user.ensure", {})).value.id as string
      testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA = `${saved[1] ?? ""},${sessionUser}`
      const on = await enable("brain-claude-enable-on")
      expect(on.r.status, on.r.text).toBe(200)
      expect(on.r.json.value).toMatchObject({ enabled: true, model: "claude-opus-5-5" })
    } finally {
      saved[0] === undefined ? delete testEnv.CHIEF_BRAIN_MODEL : (testEnv.CHIEF_BRAIN_MODEL = saved[0])
      saved[1] === undefined ? delete testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA : (testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA = saved[1])
    }
  })

  it("a turn on Claude for an owner taken off the allow-list sends nothing to the route and tells the person the model is not available for their team", async () => {
    const saved = testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA
    const route = fakeRoute("ok")
    const sub = "brain-claude-delisted"
    const user = (await op(await sessionToken(sub), "user.ensure", {})).value.id as string
    testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA = `${saved ?? ""},${user}`
    try {
      // On the list (and with credits) when the brain was turned on; off it at the turn.
      const { token, chief } = await ownerWithClaudeChief(sub)
      saved === undefined ? delete testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA : (testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA = saved)
      expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: "d1", parts: [{ type: "text", text: "still there?" }] }, "d1")).ok).toBe(true)
      const [reply] = await replies(token, chief.main_conversation, chief.id, 1)
      expect(reply.parts[0].text).toBe(MODEL_UNAVAILABLE_NOTICE)
      // A settings save that repeats enabled:true on the Chief that is already on is not refused.
      const save = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true, role: "Release captain 2" })
      expect(save.status, save.text).toBe(200)
      expect(route.seen).toHaveLength(0)
      const runId = (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, token)).json.value.runs[0].id as string
      const run = await http("GET", `/v1/chiefs/${chief.id}/runs/${runId}?conversation=${chief.main_conversation}`, token)
      expect(run.json.value.run).toMatchObject({ status: "failed" })
      expect(run.json.value.steps.find((s: { id: string }) => s.id === "note:model")?.text).toContain("claude-opus-5-5: owner_not_allowed")
    } finally {
      saved === undefined ? delete testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA : (testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA = saved)
    }
  })

  it("refuses the turn (no unmetered fallback for a paid Chief) when the sign-in refresh fails, tells the person once, logging no token bytes", async () => {
    await forgetRefreshed()
    const route = fakeRoute("fail")
    const logs: Array<string> = []
    for (const level of ["log", "warn", "error"] as const) vi.spyOn(console, level).mockImplementation((...a: Array<unknown>) => void logs.push(a.map(String).join(" ")))
    const { token, chief } = await ownerWithClaudeChief("brain-claude-fail")
    expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: "f1", parts: [{ type: "text", text: "anyone there?" }] }, "f1")).ok).toBe(true)
    const [reply] = await replies(token, chief.main_conversation, chief.id, 1)
    // A paid Chief never runs on an unmetered model instead: the turn fails and the Chief says so once.
    expect(reply.parts[0].text).toBe(TURN_FAILED_NOTICE)
    expect(route.seen).toHaveLength(0)
    expect(route.refreshes()).toBeGreaterThanOrEqual(1)
    const runId = (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, token)).json.value.runs[0].id as string
    const run = await http("GET", `/v1/chiefs/${chief.id}/runs/${runId}?conversation=${chief.main_conversation}`, token)
    expect(run.json.value.run).toMatchObject({ model: "claude-opus-5-5", status: "failed" })
    // The fallback's reason is on the run (a note step), not only in the Worker log.
    expect(run.json.value.steps.find((s: { id: string }) => s.id === "note:model")?.text).toContain("claude-opus-5-5: auth_failed; no paid fallback")
    expect(logs).toContain("claude-david auth failed")
    for (const body of [...logs, run.text, JSON.stringify(reply)]) expect(body).not.toContain(REFRESH)
  })
})
