import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { afterAll, afterEach, beforeAll, expect, vi } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * The people, Chiefs and requests of the Claude Code route's tests (chief-brain-cc*.test.ts), shared so each
 * file stays under the backend's 1000-line / 64 KB limit (scripts/check-file-size.ts). Each file calls
 * useCcSettings() once.
 */
type TestEnv = Record<string, string | undefined> & { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; TEAM_DO: DurableObjectNamespace; CHIEF_BRAIN_DO: DurableObjectNamespace }
export const testEnv = env as unknown as TestEnv
export const worker = (exports as unknown as { default: Fetcher }).default
export const inDO = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
export const sessionToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
export const http = async (method: string, path: string, token: string, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method, headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  return { status: res.status, text: await res.clone().text(), json: (await res.json().catch(() => null)) as any }
}
export const op = async (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => (await http("POST", "/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })).json
export const history = async (token: string, conversation: string) => (await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation, limit: 50 } })).json.value.messages as Array<any>

const SETTINGS = { CHIEF_CC_ENABLED: "1", CHIEF_CC_SNAPSHOT: "sh-test-chief-cc", CHIEF_CC_FREESTYLE_API_KEY: "test-freestyle-key-not-real", CHIEF_CC_FREESTYLE_API_URL: "https://freestyle.test", CHIEF_CC_TS_OAUTH: JSON.stringify({ client_id: "test-client", client_secret: "test-client-secret-not-real" }) }
/** The route's settings for one test file (restored after it), and the fetch fakes undone after each test. */
export const useCcSettings = (): void => {
  const saved: Record<string, string | undefined> = {}
  beforeAll(() => {
    for (const k of [...Object.keys(SETTINGS), "CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA", "CHIEF_CC_OWNERS"]) saved[k] = testEnv[k]
    Object.assign(testEnv, SETTINGS)
  })
  afterAll(() => {
    for (const [k, v] of Object.entries(saved)) v === undefined ? delete testEnv[k] : (testEnv[k] = v)
  })
  afterEach(() => vi.restoreAllMocks())
}

/** `cc`: on the Claude Code route's owner list (and the paid-model list); `paid`: on the paid-model list only. */
export const enabledChief = async (sub: string, lists: "cc" | "paid" | false) => {
  const listed = lists !== false
  const token = await sessionToken(sub)
  const ensured = (await op(token, "user.ensure", {})).value
  const user = ensured.id as string
  if (listed) testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA = `${testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA ?? ""},${user}`
  if (lists === "cc") testEnv.CHIEF_CC_OWNERS = `${testEnv.CHIEF_CC_OWNERS ?? ""},${user}`
  const chief = (await op(token, "chief.create", { display_name: "Route Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  let on = { status: 0, json: {} as any, text: "" }
  for (let i = 0; i < 20 && on.status !== 200; i++) {
    await fireAlarm(userDO)
    on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, listed ? { enabled: true, model: "claude-opus-5-5" } : { enabled: true })
  }
  expect(on.status, on.text).toBe(200)
  return { token, user, team: ensured.personal_team as string, chief }
}
export const replies = async (token: string, conversation: string, chief: string, n: number) => {
  for (let i = 0; i < 300; i++) {
    const mine = (await history(token, conversation)).filter((m) => m.author === chief)
    if (mine.length >= n) return mine
    await new Promise((r) => setTimeout(r, 50))
  }
  throw new Error(`no ${n} chief replies`)
}
export const send = (token: string, conversation: string, key: string, text: string) => op(token, "message.send", { conversation, client_msg_id: key, parts: [{ type: "text", text }] }, key)
