import { expect, test } from "bun:test"
import { GATEWAY_URL, relayChat } from "../src/lib/ai-gateway-relay"

const body = (model: string) => JSON.stringify({ model, messages: [{ role: "user", content: "hi" }] })
const req = (key: string | undefined, b: string) => new Request("https://console.test/api/ai-gateway/chat/completions", { method: "POST", headers: key ? { authorization: `Bearer ${key}` } : {}, body: b })

const recording = () => {
  const calls: Array<{ url: string; auth: string | null; body: string }> = []
  const fake = (async (url: string, init: RequestInit) => {
    calls.push({ url, auth: new Headers(init.headers).get("authorization"), body: new TextDecoder().decode(init.body as ArrayBuffer) })
    return Response.json({ choices: [{ message: { content: "hi" } }] })
  }) as unknown as typeof fetch
  return { calls, fake }
}

test("forwards a DeepSeek body to AI Gateway with the OIDC token", async () => {
  const { calls, fake } = recording()
  const res = await relayChat(req("relay-k", body("deepseek/deepseek-v4.1-flash-1017")), { relayKey: "relay-k", oidcToken: "oidc-t", fetch: fake })
  expect(res.status).toBe(200)
  expect(calls).toEqual([{ url: GATEWAY_URL, auth: "Bearer oidc-t", body: body("deepseek/deepseek-v4.1-flash-1017") }])
})

test("refuses a wrong relay key without calling the gateway", async () => {
  const { calls, fake } = recording()
  expect((await relayChat(req("wrong", body("deepseek/x")), { relayKey: "relay-k", oidcToken: "oidc-t", fetch: fake })).status).toBe(401)
  expect(calls.length).toBe(0)
})

test("refuses a non-DeepSeek model", async () => {
  const { calls, fake } = recording()
  expect((await relayChat(req("relay-k", body("anthropic/claude-opus-5-5")), { relayKey: "relay-k", oidcToken: "oidc-t", fetch: fake })).status).toBe(403)
  expect(calls.length).toBe(0)
})

test("is off (404) without a relay key", async () => {
  const { fake } = recording()
  expect((await relayChat(req("x", body("deepseek/x")), { relayKey: undefined, oidcToken: "oidc-t", fetch: fake })).status).toBe(404)
})
