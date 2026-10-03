import { env, exports } from "cloudflare:workers"
import { runDurableObjectAlarm, runInDurableObject as runIn } from "cloudflare:test"
// The typed helper recurses through the DO class types (TS2589); the tests only need any.
const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
import { conversation as homeConversation, invites } from "@cmux/home-core"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"

/** Stage C invite email sends from AddressDO: once, fail-closed switch, allow list, nothing printed but ids. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; HOME_ADDRESS_KEY: string; ADDRESS_DO: any; CONVERSATION_DO: any }
const worker = (exports as unknown as { default: Fetcher }).default
const sessionToken = async (sub: string, email: string) =>
  new SignJWT({ email, email_verified: true, name: "Alice Example" })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const op = async (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => {
  const res = await worker.fetch("https://api.test/v1/ops", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ op: name, params, idempotency_key: key, origin: "user" }) })
  return (await res.json()) as any
}

const invite = async (sub: string, to: string, overrides: Record<string, string>) => {
  const token = await sessionToken(sub, `${sub}@example.com`)
  await op(token, "user.ensure", {})
  const user = userIdFor(testEnv.STACK_PROJECT_ID, sub)
  const address = invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizeEmail(to) as invites.Address)
  const addr = testEnv.ADDRESS_DO.get(testEnv.ADDRESS_DO.idFromName(address))
  const calls: Array<{ url: string; body: string }> = []
  // The stash RPC creates the object; set the environment and the provider fake before any alarm runs.
  const opened = await op(token, "dm.open", { peer: { email: to } })
  expect(opened.ok).toBe(true)
  await runInDurableObject(addr, async (instance: any) => {
    instance.env = { ...instance.env, ...overrides }
    instance.fetcher = async (url: string, init: { body: string }) => {
      calls.push({ url, body: init.body })
      return { status: 200, json: async () => ({ id: "re_msg_1" }) }
    }
  })
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(homeConversation.dmConversationId(user, address)))
  let state = ""
  for (let i = 0; i < 20 && !["sent", "disabled", "refused_env", "failed"].includes(state); i++) {
    await runDurableObjectAlarm(conv)
    await runDurableObjectAlarm(addr)
    state = await runInDurableObject(addr, async (instance: any) => String(instance.boundEngine?.currentState?.deliveries?.[0]?.state ?? ""))
  }
  const left = await runInDurableObject(addr, async (_i, s) => Number(s.storage.sql.exec("SELECT count(*) AS n FROM address_secrets").toArray()[0]!.n))
  return { state, calls, left }
}

const ON = { HOME_INVITES_SEND: "on", RESEND_API_KEY: "re_test_key", HOME_INVITE_FROM: "cmux <invites@cmux.dev>", HOME_INVITE_ORIGIN: "https://console-staging.cmux.dev", ENVIRONMENT: "staging" }

describe("invite email sends (stage C)", { timeout: 60_000 }, () => {
  it("sends once to an allow-listed address with the accept link, then drops the secret", async () => {
    const r = await invite("send-on", "dana@example.com", { ...ON, HOME_INVITE_ALLOWLIST_EMAILS: "dana@example.com" })
    expect(r.state).toBe("sent")
    expect(r.calls).toHaveLength(1)
    expect(r.calls[0]!.url).toBe("https://api.resend.com/emails")
    expect(r.calls[0]!.body).toMatch(/https:\/\/console-staging\.cmux\.dev\/i\/d[0-9A-HJKMNP-TV-Z]{26}#[0-9A-HJKMNP-TV-Z]{26}/)
    expect(r.left).toBe(0)
  })

  it("sends nothing while the switch is not exactly on", async () => {
    const { HOME_INVITES_SEND: _off, ...rest } = ON
    const r = await invite("send-off", "erin@example.com", { ...rest, HOME_INVITES_SEND: "", HOME_INVITE_ALLOWLIST_EMAILS: "erin@example.com" })
    expect(r.state).toBe("disabled")
    expect(r.calls).toHaveLength(0)
  })

  it("outside production, sends nothing to an address off the allow list", async () => {
    const r = await invite("send-off-list", "frank@example.com", { ...ON, HOME_INVITE_ALLOWLIST_EMAILS: "someone-else@example.com" })
    expect(r.state).toBe("refused_env")
    expect(r.calls).toHaveLength(0)
  })

  it("ENVIRONMENT=production on a Worker that is not cmux-api still uses the allow list", async () => {
    const r = await invite("send-mislabeled", "gina@example.com", { ...ON, ENVIRONMENT: "production", WORKER_NAME: "cmux-api-staging", HOME_INVITE_ALLOWLIST_EMAILS: "someone-else@example.com" })
    expect(r.state).toBe("refused_env")
    expect(r.calls).toHaveLength(0)
  })
})
