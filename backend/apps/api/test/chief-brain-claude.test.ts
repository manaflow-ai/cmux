import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { afterEach, describe, expect, it, vi } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * A Cloud Chief on Claude through the metered route (chief-brain/claude-auth.ts, models.ts): the
 * brain signs every request with the route's X-Stack-Auth (refreshed by the holder object, kept in
 * its storage), sends a streamed Messages request for claude-opus-5-5, and posts the answer. A failed
 * sign-in runs the turn on the fallback model and logs only "claude-david auth failed". The route and
 * the refresh are faked at their HTTP boundary; no token bytes may reach a reply, a run or a log.
 * One file on purpose: it replaces globalThis.fetch.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace; CHIEF_BRAIN_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const REFRESH = "test-refresh-token-not-real"
const fakeJwt = (exp: number) => ["e30", btoa(JSON.stringify({ exp })).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_"), "sig"].join(".")
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

const sse = (text: string) =>
  [
    { type: "message_start", message: { id: "msg_fake", type: "message", role: "assistant", model: "claude-opus-5-5", content: [], stop_reason: null, usage: { input_tokens: 12, output_tokens: 1 } } },
    { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
    { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } },
    { type: "content_block_stop", index: 0 },
    { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 6 } },
    { type: "message_stop" }
  ]
    .map((e) => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`)
    .join("")

interface Seen { readonly url: string; readonly stackAuth: { accessToken?: string; refreshToken?: string } | null; readonly apiKey: string | null; readonly body: any }
/** The route and the refresh at their HTTP boundary; everything else goes to the real fetch. */
const fakeRoute = (refresh: "ok" | "fail") => {
  const real = globalThis.fetch
  const seen: Array<Seen> = []
  let refreshes = 0
  const fresh = fakeJwt(Math.floor(Date.now() / 1000) + 3600)
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init)
    if (req.url.startsWith("https://auth.test/")) {
      refreshes++
      expect(req.headers.get("x-hexclave-refresh-token")).toBe(REFRESH)
      return refresh === "ok" ? Response.json({ access_token: fresh }) : Response.json({ error: "refresh token revoked" }, { status: 401 })
    }
    if (req.url.startsWith("https://claude.test/")) {
      const raw = req.headers.get("x-stack-auth")
      const body = await req.json()
      seen.push({ url: req.url, stackAuth: raw ? JSON.parse(raw) : null, apiKey: req.headers.get("x-api-key"), body })
      return new Response(sse(`Opus answers turn ${seen.length}`), { headers: { "content-type": "text/event-stream" } })
    }
    return real(input, init)
  })
  return { seen, fresh, refreshes: () => refreshes }
}
afterEach(() => vi.restoreAllMocks())

const ownerWithClaudeChief = async (sub: string) => {
  const token = await sessionToken(sub)
  const user = (await op(token, "user.ensure", {})).value.id as string
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
const forgetRefreshed = () => runInDurableObject(testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName("claude-david-auth")), async (_i, state) => void state.storage.sql.exec("DELETE FROM cb_config WHERE name = 'claude.access'"))

describe("Cloud Chief on Claude through the metered route", { timeout: 120_000 }, () => {
  it("signs each streamed Opus request with a refreshed X-Stack-Auth and posts the answer; no token reaches a reply or run", async () => {
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
      expect(s.body).toMatchObject({ model: "claude-opus-5-5", stream: true })
      expect(s.stackAuth).toEqual({ accessToken: route.fresh, refreshToken: REFRESH })
      expect(s.apiKey).toBeNull()
      expect(JSON.stringify(s.body)).not.toContain(REFRESH)
    }
    // The expired configured token was refreshed once; the second turn used the stored one.
    expect(route.refreshes()).toBe(1)
    const run = await http("GET", `/v1/chiefs/${chief.id}/runs/${posted[0].parts[1].session}?conversation=${chief.main_conversation}`, token)
    expect(run.json.value.run).toMatchObject({ model: "claude-opus-5-5", status: "done" })
    for (const body of [run.text, JSON.stringify(posted), (await http("GET", `/v1/chiefs/${chief.id}/brain`, token)).text]) {
      expect(body).not.toContain(REFRESH)
      expect(body).not.toContain(route.fresh)
    }
  })

  it("runs the turn on the fallback model when the sign-in refresh fails, logging no token bytes", async () => {
    await forgetRefreshed()
    const route = fakeRoute("fail")
    const logs: Array<string> = []
    for (const level of ["log", "warn", "error"] as const) vi.spyOn(console, level).mockImplementation((...a: Array<unknown>) => void logs.push(a.map(String).join(" ")))
    const { token, chief } = await ownerWithClaudeChief("brain-claude-fail")
    expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: "f1", parts: [{ type: "text", text: "anyone there?" }] }, "f1")).ok).toBe(true)
    const [reply] = await replies(token, chief.main_conversation, chief.id, 1)
    expect(reply.parts[0].text).toContain("[fake-echo] reply to:")
    expect(route.seen).toHaveLength(0)
    expect(route.refreshes()).toBeGreaterThanOrEqual(1)
    const run = await http("GET", `/v1/chiefs/${chief.id}/runs/${reply.parts[1].session}?conversation=${chief.main_conversation}`, token)
    expect(run.json.value.run.model).toBe("fake")
    expect(logs).toContain("claude-david auth failed")
    for (const body of [...logs, run.text, JSON.stringify(reply)]) expect(body).not.toContain(REFRESH)
  })
})
