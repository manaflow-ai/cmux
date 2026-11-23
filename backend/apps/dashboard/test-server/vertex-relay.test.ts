import { beforeEach, expect, test } from "bun:test"
import { relayVertexChat, resetVertexTokenCache, SERVICE_ACCOUNT, VERTEX_URL, WIF_AUDIENCE } from "../src/lib/vertex-relay"

const body = (model: string) => JSON.stringify({ model, messages: [{ role: "user", content: "hi" }] })
const req = (key: string | undefined, b: string) => new Request("https://console.test/api/vertex/chat/completions", { method: "POST", headers: key ? { authorization: `Bearer ${key}` } : {}, body: b })

/** Fakes Google STS, IAM Credentials and Vertex; records every call. */
const google = (vertexStatus = 200) => {
  const calls: Array<{ url: string; auth: string | null; body: string }> = []
  const fake = (async (url: string, init: RequestInit) => {
    const text = typeof init.body === "string" ? init.body : new TextDecoder().decode(init.body as ArrayBuffer)
    calls.push({ url, auth: new Headers(init.headers).get("authorization"), body: text })
    if (url.startsWith("https://sts.googleapis.com/")) return Response.json({ access_token: "federated-t" })
    if (url.startsWith("https://iamcredentials.googleapis.com/")) return Response.json({ accessToken: "sa-t", expireTime: new Date(Date.now() + 3_600_000).toISOString() })
    return Response.json({ choices: [{ message: { content: "hi" } }] }, { status: vertexStatus })
  }) as unknown as typeof fetch
  return { calls, fake }
}

beforeEach(() => resetVertexTokenCache())

test("trades the Vercel OIDC token for the service account's token and forwards to Vertex", async () => {
  const { calls, fake } = google()
  const res = await relayVertexChat(req("relay-k", body("google/gemini-4-neon")), { relayKey: "relay-k", oidcToken: "oidc-t", fetch: fake })
  expect(res.status).toBe(200)
  expect(calls.map((c) => new URL(c.url).hostname)).toEqual(["sts.googleapis.com", "iamcredentials.googleapis.com", "aiplatform.googleapis.com"])
  const sts = JSON.parse(calls[0]!.body)
  expect(sts.subjectToken).toBe("oidc-t")
  expect(sts.audience).toBe(WIF_AUDIENCE)
  expect(calls[1]!.url).toContain(SERVICE_ACCOUNT)
  expect(calls[1]!.auth).toBe("Bearer federated-t")
  expect(calls[2]).toEqual({ url: VERTEX_URL, auth: "Bearer sa-t", body: body("google/gemini-4-neon") })
})

test("reuses the Google token until shortly before it expires", async () => {
  const { calls, fake } = google()
  for (let i = 0; i < 3; i++) expect((await relayVertexChat(req("relay-k", body("google/gemini-4-neon")), { relayKey: "relay-k", oidcToken: "oidc-t", fetch: fake })).status).toBe(200)
  expect(calls.filter((c) => c.url.startsWith("https://sts.")).length).toBe(1)
  expect(calls.filter((c) => c.url === VERTEX_URL).length).toBe(3)
})

test("forgets the token when Vertex rejects it", async () => {
  const { calls, fake } = google(401)
  await relayVertexChat(req("relay-k", body("google/gemini-4-neon")), { relayKey: "relay-k", oidcToken: "oidc-t", fetch: fake })
  await relayVertexChat(req("relay-k", body("google/gemini-4-neon")), { relayKey: "relay-k", oidcToken: "oidc-t", fetch: fake })
  expect(calls.filter((c) => c.url.startsWith("https://sts.")).length).toBe(2)
})

test("refuses a wrong relay key, a non-Google model, and runs off without a key or OIDC token", async () => {
  const { calls, fake } = google()
  expect((await relayVertexChat(req("wrong", body("google/gemini-4-neon")), { relayKey: "relay-k", oidcToken: "oidc-t", fetch: fake })).status).toBe(401)
  expect((await relayVertexChat(req("relay-k", body("deepseek/deepseek-v4-pro")), { relayKey: "relay-k", oidcToken: "oidc-t", fetch: fake })).status).toBe(403)
  expect((await relayVertexChat(req("relay-k", body("google/gemini-4-neon")), { relayKey: undefined, oidcToken: "oidc-t", fetch: fake })).status).toBe(404)
  expect((await relayVertexChat(req("relay-k", body("google/gemini-4-neon")), { relayKey: "relay-k", oidcToken: undefined, fetch: fake })).status).toBe(503)
  expect(calls).toHaveLength(0)
})

test("a failed token exchange is a 502 the Worker may retry elsewhere", async () => {
  const fake = (async () => new Response("no", { status: 403 })) as unknown as typeof fetch
  expect((await relayVertexChat(req("relay-k", body("google/gemini-4-neon")), { relayKey: "relay-k", oidcToken: "oidc-t", fetch: fake })).status).toBe(502)
})

test("Google holding the request past the header deadline is a clean 504, not a proxy timeout", async () => {
  const hang = (async (url: string, init: RequestInit) => {
    if (url.startsWith("https://sts.googleapis.com/")) return Response.json({ access_token: "federated-t" })
    if (url.startsWith("https://iamcredentials.googleapis.com/")) return Response.json({ accessToken: "sa-t", expireTime: new Date(Date.now() + 3_600_000).toISOString() })
    return new Promise<Response>((_, reject) => init.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError"))))
  }) as unknown as typeof fetch
  const started = Date.now()
  const res = await relayVertexChat(req("relay-k", body("google/gemini-4-neon")), { relayKey: "relay-k", oidcToken: "oidc-t", fetch: hang, headerTimeoutMs: 50 })
  expect(res.status).toBe(504)
  expect(((await res.json()) as { error: { code: string } }).error.code).toBe("upstream.timeout")
  expect(Date.now() - started).toBeLessThan(2_000)
})
