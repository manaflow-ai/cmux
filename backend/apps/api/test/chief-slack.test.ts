import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it, vi } from "vitest"
import { postSlackMessage, validSlackInbound, type SlackInbound } from "../src/chief-slack.ts"
import { sha256Hex } from "../src/ingress/verify.ts"
import { slackOutbound } from "../src/chief-brain/brain-slack.ts"
import { PlatformChief } from "../src/platform-chief.ts"
import type { ChiefBrainDO } from "../src/chief-brain/brain-do.ts"
import type { Env } from "../src/env.ts"
import { createExecutionContext } from "cloudflare:test"
import { fireAlarm } from "./setup/alarm.ts"

/** The service-binding Slack bridge against the real conversation and brain storage. */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; TEAM_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace; MUX_DO: DurableObjectNamespace }
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
  const ensured = (await op(token, "user.ensure", {})).value
  const user = ensured.id as string
  const chief = (await op(token, "chief.create", { display_name: "Release Chief" }, `chief-${sub}`)).value
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  for (let i = 0; i < 20; i++) {
    await fireAlarm(userDO)
    if ((await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation: chief.main_conversation, limit: 1 } })).status === 200) break
  }
  return { token, user, team: ensured.personal_team as string, chief: chief as { id: string; main_conversation: string } }
}

const input = (user: string, team: string): SlackInbound => ({ slackTeamId: "T123", channelId: "C123", threadTs: "123.001", ts: "123.001", slackUserId: "U123", slackUserName: "Sam", isOwner: false, text: "Please run this", permalink: "https://example.slack.com/archives/C123/p123001", ownerUserId: user, cmuxTeamId: team, channelName: "general" })

describe("Chief Slack bridge", () => {
  it("persists the thread map, dedupes input, and retains owner authorization per inbox row", async () => {
    const { token, chief, user, team } = await ownerWithChief("slack-inbound")
    expect((await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true })).status).toBe(200)
    const brains = (env as unknown as Env).CHIEF_BRAIN_DO
    const brain = brains.get(brains.idFromName(`${chief.id}/${chief.main_conversation}`))
    const inDO = runInDurableObject as unknown as <T>(stub: unknown, f: (b: ChiefBrainDO) => Promise<T>) => Promise<T>
    // Hold the model, so the test observes the exact queued policy rather than timing a model run.
    const rows = await inDO(brain, async (b) => {
      const kick = b.kick
      b.kick = () => undefined
      try {
        const inbound = input(user, team)
        const concurrent = await Promise.all(Array.from({ length: 3 }, () => b.slackInbound({ agent: chief.id, conversation: chief.main_conversation, inbound })))
        expect(concurrent.every((result) => result.ok)).toBe(true)
        expect(concurrent.filter((result) => result.ok && result.queued)).toHaveLength(1)
        expect(await b.slackInbound({ agent: chief.id, conversation: chief.main_conversation, inbound })).toMatchObject({ ok: true, queued: false })
        expect(await b.slackInbound({ agent: chief.id, conversation: chief.main_conversation, inbound: { ...inbound, slackUserName: "New display name", text: "Changed redelivery", isOwner: true } })).toMatchObject({ ok: true, queued: false })
        expect(b.sql.exec("SELECT text, effect_authorized FROM cb_inbox WHERE seq = 1").one()).toMatchObject({ effect_authorized: 0, text: `[slack:T123:U123 · Sam] ${inbound.text}` })
        expect(await b.slackInbound({ agent: chief.id, conversation: chief.main_conversation, inbound: { ...inbound, ts: "123.002", isOwner: true, slackUserId: "UOWNER", text: "I approve" } })).toMatchObject({ ok: true })
        expect(b.sql.exec("SELECT * FROM cb_slack_threads").toArray()).toHaveLength(1)
        // A normal cmux wake wins the race between conversation commit and bridge inbox injection.
        const raced = { ...inbound, threadTs: "123.003", ts: "123.003" }
        const raceRoot = `msg_${(await sha256Hex(JSON.stringify([chief.id, chief.main_conversation, raced.slackTeamId, raced.channelId, raced.threadTs]))).slice(0, 32)}`
        const conv = (env as unknown as Env).CONVERSATION_DO.get((env as unknown as Env).CONVERSATION_DO.idFromName(chief.main_conversation))
        await conv.slackMessage(chief.main_conversation, { owner: user, agent: chief.id, root: raceRoot, inbound: raced })
        await b.wake({ agent: chief.id, owner: user, conversation: chief.main_conversation, seq: 3, reason: "message" })
        expect(b.sql.exec<{ kind: string; thread_root: string }>("SELECT kind, thread_root FROM cb_inbox WHERE seq = 3").one()).toMatchObject({ kind: "slack", thread_root: raceRoot })
        expect(await b.slackInbound({ agent: chief.id, conversation: chief.main_conversation, inbound: raced })).toMatchObject({ ok: true, queued: false })
        expect(b.sql.exec("SELECT * FROM cb_slack_threads").toArray()).toHaveLength(2)
        const sends: Array<Promise<unknown>> = []
        const fetch = vi.fn(async () => new Response("{}"))
        const host = { sql: b.sql, doEnv: { ENVIRONMENT: "test", PLATFORM: { fetch }, INTERNAL_TOKEN: "test-internal" }, doCtx: { waitUntil: (p: Promise<unknown>) => sends.push(p) } } as unknown as ChiefBrainDO
        const root = b.sql.exec<{ root: string }>("SELECT root FROM cb_slack_threads WHERE thread_ts = '123.001'").one().root
        await slackOutbound(host, { root: "msg_unlinked", message: "normal", text: "private" })
        await slackOutbound(host, { root, message: "reply", text: "answer" })
        await slackOutbound(host, { root, message: "reply", text: "answer" })
        await Promise.all(sends)
        expect(fetch).toHaveBeenCalledTimes(1)
        return b.sql.exec<{ effect_authorized: number; woke: number; thread_root: string }>("SELECT effect_authorized, woke, thread_root FROM cb_inbox ORDER BY n").toArray()
      } finally { b.kick = kick }
    })
    expect(rows.map((r) => r.effect_authorized)).toEqual([0, 1, 0])
    expect(rows.map((r) => r.woke)).toEqual([1, 1, 1])
    expect(rows[0]!.thread_root).toBe(rows[1]!.thread_root)
    expect(rows[2]!.thread_root).not.toBe(rows[0]!.thread_root)
    const messages = await history(token, chief.main_conversation)
    expect(messages).toHaveLength(3)
    expect(messages[0].author).toBe("slack:T123:U123")
    expect(messages[0].thread).toMatchObject({ source: "slack", channelName: "general", permalink: input(user, team).permalink })
    expect(messages[1].thread_root).toBe(messages[0].id)
  })

  it("refuses malformed input and is unavailable outside development", async () => {
    const valid = input("user_test", "team_test")
    expect(validSlackInbound(valid)).toBe(true)
    expect(validSlackInbound({ ...valid, isOwner: "yes" as unknown as boolean })).toBe(false)
    const bound = exports as unknown as { PlatformChief: { slackInbound(input: SlackInbound): Promise<{ ok: boolean; code?: string }> } }
    expect(await bound.PlatformChief.slackInbound({ ...valid, text: "" })).toEqual({ ok: false, code: "validation.invalid" })
    const rpc = new PlatformChief(createExecutionContext(), { ENVIRONMENT: "production" } as Env)
    expect(await rpc.slackInbound(valid)).toEqual({ ok: false, code: "slack.disabled" })
  })

  it("sends exactly one binding-internal attempt and isolates failures", async () => {
    const fetch = vi.fn(async (_url: RequestInfo | URL, _init?: RequestInit) => new Response("down", { status: 503 }))
    const log = vi.spyOn(console, "warn").mockImplementation(() => undefined)
    try {
      const config = { ENVIRONMENT: "test", INTERNAL_TOKEN: "test-internal", PLATFORM: { fetch } as unknown as Fetcher }
      const message = { slackTeamId: "T123", channelId: "C123", threadTs: "123.001", text: "answer" }
      await expect(postSlackMessage(config, message)).resolves.toBeUndefined()
      expect(fetch).toHaveBeenCalledTimes(1)
      expect(fetch.mock.calls[0]?.[0]).toBe("https://platform/internal/v1/slack/messages")
      const init = (fetch.mock.calls as unknown as Array<[string, RequestInit]>)[0]![1]
      expect(new Headers(init.headers).get("authorization")).toBe("Bearer test-internal")
      expect(JSON.parse(init.body as string)).toEqual(message)
      fetch.mockRejectedValueOnce(new Error("transport"))
      await expect(postSlackMessage(config, message)).resolves.toBeUndefined()
      expect(fetch).toHaveBeenCalledTimes(2)
      expect(log).toHaveBeenCalled()
    } finally { log.mockRestore() }
  })
})
