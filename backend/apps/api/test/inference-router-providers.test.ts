import { env } from "cloudflare:workers"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.ts"
import { MODELS } from "../src/inference/catalog.ts"
import { paidPerson } from "./setup/inference-person.ts"

/**
 * The cmux inference router's provider set (user 2026-10-28): Vercel AI Gateway first (reached
 * through the OIDC relay when one is configured), then OpenRouter, Cloudflare (Workers AI through
 * AI Gateway), Azure AI Foundry and our own OpenAI-compatible endpoint. A model allowlist narrows
 * the catalog per deployment (DeepSeek V4.1 Flash 1017 only, for now), and that model takes images.
 * Providers are faked at their HTTP boundary.
 */

const DS = "deepseek/deepseek-v4.1-flash-1017"
const HOSTS: Record<string, string> = {
  "openrouter.ai": "openrouter",
  "ai-gateway.vercel.sh": "vercel",
  "relay.test": "vercel-relay",
  "cmux-test.services.ai.azure.com": "azure",
  "own.test": "custom",
  "api.openai.com": "openai",
  "api.particle.ai": "particle"
}

interface Seen {
  readonly provider: string
  readonly url: string
  readonly headers: Headers
  readonly body: Record<string, unknown>
}

const record = (reply: (provider: string) => Response) => {
  const seen: Array<Seen> = []
  const real = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input))
    const provider = HOSTS[url.hostname]
    if (!provider) return real(input, init)
    seen.push({ provider, url: url.toString(), headers: new Headers(init?.headers), body: JSON.parse(String(init?.body ?? "{}")) })
    return reply(provider)
  })
  return seen
}

const ok = () => Response.json({ id: "x", choices: [{ index: 0, message: { role: "assistant", content: "Red" } }], usage: { prompt_tokens: 200, completion_tokens: 2 } })

const allKeys = (extra: Record<string, string> = {}) =>
  ({
    ...env,
    INFERENCE_OPENROUTER_KEY: "k-or",
    INFERENCE_VERCEL_GATEWAY_KEY: "k-vc",
    INFERENCE_AZURE_ENDPOINT: "https://cmux-test.services.ai.azure.com",
    INFERENCE_AZURE_KEY: "k-az",
    INFERENCE_CUSTOM_URL: "https://own.test/v1/chat/completions",
    INFERENCE_CUSTOM_KEY: "k-own",
    INFERENCE_OPENAI_KEY: "k-oa",
    INFERENCE_PARTICLE_KEY: "k-pa",
    ...extra
  }) as any

const RED_PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
const imageMessages = [{ role: "user", content: [{ type: "text", text: "What color?" }, { type: "image_url", image_url: { url: RED_PNG } }] }]

/** A chat of `count` earlier turns, each a user image and an answer, then a new text message. */
const historyWithImages = (count: number) => [
  ...Array.from({ length: count }, (_, i) => [
    { role: "user", content: [{ type: "text", text: `Picture ${i + 1}` }, { type: "image_url", image_url: { url: RED_PNG } }] },
    { role: "assistant", content: "Red" }
  ]).flat(),
  { role: "user", content: "Which of them was red?" }
]

/** `count` image parts of one tiny PNG. */
const imageParts = (count: number) => Array.from({ length: count }, () => ({ type: "image_url", image_url: { url: RED_PNG } }))

/** The image parts of the messages a provider was sent. */
const imagePartsOf = (messages: unknown) => (JSON.stringify(messages).match(/"type":"image_url"/g) ?? []).length

const call = async (t: string, runEnv: unknown, model: string, messages: unknown = [{ role: "user", content: "hi" }], headers: Record<string, string> = {}) => {
  const ctx = createExecutionContext()
  const res = await worker.fetch!(
    new Request("https://api.test/v1/inference/chat/completions", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}`, ...headers }, body: JSON.stringify({ model, max_tokens: 32, messages }) }) as any,
    runEnv as any,
    ctx
  )
  const text = await res.text()
  await waitOnExecutionContext(ctx)
  return { status: res.status, text, headers: res.headers }
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe("inference router providers (Vercel first, OpenRouter, Cloudflare, Azure, our own)", () => {
  it("serves DeepSeek V4.1 Flash 1017 through Vercel AI Gateway first", async () => {
    const { t } = await paidPerson("router-vercel-first")
    const seen = record(() => ok())
    const r = await call(t, allKeys(), DS)
    expect(r.status).toBe(200)
    expect(seen.map((s) => s.provider)).toEqual(["vercel"])
    expect(seen[0]!.body.model).toBe("deepseek/deepseek-v4.1-flash-1017")
    expect(r.headers.get("x-cmux-provider")).toBe("vercel")
  })

  it("reaches Vercel through the OIDC relay when one is configured, with the relay key", async () => {
    const { t } = await paidPerson("router-vercel-relay")
    const seen = record(() => ok())
    const r = await call(t, allKeys({ INFERENCE_VERCEL_GATEWAY_KEY: "", INFERENCE_VERCEL_RELAY_URL: "https://relay.test/api/ai-gateway/chat/completions", INFERENCE_VERCEL_RELAY_KEY: "relay-secret" }), DS)
    expect(r.status).toBe(200)
    expect(seen.map((s) => s.provider)).toEqual(["vercel-relay"])
    expect(seen[0]!.headers.get("authorization")).toBe("Bearer relay-secret")
  })

  it("calls an Azure AI Foundry deployment with its api-key header", async () => {
    const { t } = await paidPerson("router-azure")
    const seen = record(() => ok())
    const r = await call(t, allKeys(), DS, undefined, { "x-cmux-provider": "azure" })
    expect(r.status).toBe(200)
    expect(seen[0]!.url).toBe("https://cmux-test.services.ai.azure.com/openai/v1/chat/completions")
    expect(seen[0]!.headers.get("api-key")).toBe("k-az")
    expect(seen[0]!.body.model).toBe("deepseek-v4.1-flash")
  })

  it("calls our own OpenAI-compatible endpoint", async () => {
    const { t } = await paidPerson("router-custom")
    const seen = record(() => ok())
    const r = await call(t, allKeys(), DS, undefined, { "x-cmux-provider": "custom" })
    expect(r.status).toBe(200)
    expect(seen[0]!.url).toBe("https://own.test/v1/chat/completions")
    expect(seen[0]!.headers.get("authorization")).toBe("Bearer k-own")
  })

  it("serves an OpenAI model through OpenAI's own API first, with max_completion_tokens", async () => {
    const { t } = await paidPerson("router-openai")
    const seen = record(() => ok())
    const r = await call(t, allKeys({ INFERENCE_PRIMARY_PROVIDER: "openai" }), "openai/gpt-5.4-mini")
    expect(r.status).toBe(200)
    expect(seen.map((s) => s.provider)).toEqual(["openai"])
    expect(seen[0]!.url).toBe("https://api.openai.com/v1/chat/completions")
    expect(seen[0]!.headers.get("authorization")).toBe("Bearer k-oa")
    expect(seen[0]!.body.model).toBe("gpt-5.4-mini")
    expect(seen[0]!.body.max_completion_tokens).toBe(32)
    expect(seen[0]!.body.max_tokens).toBeUndefined()
  })

  it("serves Particle-1 through Particle's own API with its key", async () => {
    const { t } = await paidPerson("router-particle")
    const seen = record(() => ok())
    const r = await call(t, allKeys(), "particle-ai/particle-1")
    expect(r.status).toBe(200)
    expect(seen.map((s) => s.provider)).toEqual(["particle"])
    expect(seen[0]!.url).toBe("https://api.particle.ai/v1/chat/completions")
    expect(seen[0]!.headers.get("authorization")).toBe("Bearer k-pa")
    expect(seen[0]!.body.model).toBe("particle-ai/particle-1")
    expect(r.headers.get("x-cmux-provider")).toBe("particle")
  })

  it("the catalog gives Particle to Particle-1 alone", () => {
    for (const m of MODELS) {
      const providers = m.routes.map((r) => r.provider)
      if (m.id === "particle-ai/particle-1") expect(providers).toEqual(["particle"])
      else expect(providers, m.id).not.toContain("particle")
    }
  })

  it("Particle-1 is unavailable without the Particle key", async () => {
    const { t } = await paidPerson("router-particle-unkeyed")
    const seen = record(() => ok())
    const r = await call(t, allKeys({ INFERENCE_PARTICLE_KEY: "" }), "particle-ai/particle-1")
    expect(r.status).toBe(503)
    expect(JSON.parse(r.text).error.code).toBe("provider.unavailable")
    expect(seen).toEqual([])
  })

  it("the model allowlist refuses every other model with a clear error", async () => {
    const { t } = await paidPerson("router-allowlist")
    record(() => ok())
    const r = await call(t, allKeys({ INFERENCE_MODEL_ALLOWLIST: DS }), "openai/gpt-oss-120b")
    expect(r.status).toBe(403)
    const e = JSON.parse(r.text).error
    expect(e.code).toBe("model.not_allowed")
    expect(e.message).toContain(DS)
  })

  it("the models list shows only allowlisted models", async () => {
    const res = await worker.fetch!(new Request("https://api.test/v1/inference/models") as any, allKeys({ INFERENCE_MODEL_ALLOWLIST: DS }), createExecutionContext())
    const ids = ((await res.json()) as { data: Array<{ id: string; vision?: boolean }> }).data
    expect(ids.map((m) => m.id)).toEqual([DS])
    expect(ids[0]!.vision).toBe(true)
  })

  it("passes an image part to a vision model", async () => {
    const { t } = await paidPerson("router-vision")
    const seen = record(() => ok())
    const r = await call(t, allKeys(), DS, imageMessages)
    expect(r.status).toBe(200)
    expect(JSON.stringify(seen[0]!.body.messages)).toContain("image_url")
  })

  it("refuses an image part for a text-only model", async () => {
    const { t } = await paidPerson("router-vision-refused")
    record(() => ok())
    const r = await call(t, allKeys(), "openai/gpt-oss-120b", imageMessages)
    expect(r.status).toBe(400)
    expect(JSON.parse(r.text).error.message).toContain("image")
  })

  // A chat is never locked out by its own history: older images past the model's per-request limit
  // go as a placeholder the model reads, the answer counts them, and only a new message that alone
  // carries more than the limit is refused (send-path caps rule).
  it("serves a chat with 9 images in its history and a new text message", async () => {
    const { t } = await paidPerson("router-vision-history")
    const seen = record(() => ok())
    const r = await call(t, allKeys(), DS, historyWithImages(9))
    expect(r.status).toBe(200)
    expect(imagePartsOf(seen[0]!.body.messages)).toBe(9)
    expect(r.headers.get("x-cmux-images-omitted")).toBeNull()
  })

  // DeepSeek takes 600 images per request (api-docs.deepseek.com/guides/vision).
  it("sends the newest images up to the limit and a placeholder for each older one", async () => {
    const { t } = await paidPerson("router-vision-history-cut")
    const seen = record(() => ok())
    const r = await call(t, allKeys(), DS, historyWithImages(601))
    expect(r.status).toBe(200)
    const sent = seen[0]!.body.messages as Array<{ content: unknown }>
    expect(imagePartsOf(sent)).toBe(600)
    // The oldest image is the one left out; the model reads why.
    expect(JSON.stringify(sent[0]!.content)).toContain("[earlier image not sent: limit 600 per request]")
    expect(JSON.stringify(sent[0]!.content)).not.toContain("image_url")
    expect(JSON.stringify(sent[2]!.content)).toContain("image_url")
    expect(r.headers.get("x-cmux-images-omitted")).toBe("1")
  })

  it("refuses only a new message that alone carries more images than every route takes", async () => {
    const { t } = await paidPerson("router-vision-new-message")
    const seen = record(() => ok())
    const r = await call(t, allKeys(), DS, [{ role: "user", content: [{ type: "text", text: "All of these?" }, ...imageParts(601)] }])
    expect(r.status).toBe(400)
    expect(JSON.parse(r.text).error.message).toContain("at most 600 images in one message")
    expect(seen).toEqual([])
  })

  it("sends 51 images in one message through one pinned route", async () => {
    // No route of this model has a published limit below DeepSeek's own 600: nothing is refused or cut.
    const { t } = await paidPerson("router-vision-pinned-vercel")
    const seen = record(() => ok())
    const r = await call(t, allKeys(), DS, [{ role: "user", content: [{ type: "text", text: "All of these?" }, ...imageParts(51)] }], { "x-cmux-provider": "vercel" })
    expect(r.status).toBe(200)
    expect(seen.map((s) => s.provider)).toEqual(["vercel"])
    expect(imagePartsOf(seen[0]!.body.messages)).toBe(51)
  })

  it("sends a GPT-5.4 mini message of 501 images (OpenAI takes 1,500 per request)", async () => {
    const { t } = await paidPerson("router-vision-openai-count")
    const seen = record(() => ok())
    const r = await call(t, allKeys({ INFERENCE_PRIMARY_PROVIDER: "openai" }), "openai/gpt-5.4-mini", [{ role: "user", content: [{ type: "text", text: "All of these?" }, ...imageParts(501)] }])
    expect(r.status).toBe(200)
    expect(imagePartsOf(seen[0]!.body.messages)).toBe(501)
  })

  it("serves a chat with about 9 MiB of history images and a short new text message", async () => {
    const { t } = await paidPerson("router-vision-history-bytes")
    const seen = record(() => ok())
    const big = `data:image/png;base64,${"A".repeat(3 * 1024 * 1024)}`
    const turn = { role: "user", content: [{ type: "text", text: "This one" }, { type: "image_url", image_url: { url: big } }] }
    const messages = [turn, { role: "assistant", content: "Seen" }, turn, { role: "assistant", content: "Seen" }, turn, { role: "assistant", content: "Seen" }, { role: "user", content: "Which was first?" }]
    const r = await call(t, allKeys(), DS, messages)
    expect(r.status).toBe(200)
    expect(imagePartsOf(seen[0]!.body.messages)).toBe(3)
  })

  it("sends every image to a model whose provider has no image-count limit", async () => {
    // Particle limits image bytes only (16 MiB each, 100 MiB in all), never their count.
    const { t } = await paidPerson("router-vision-no-count-limit")
    const seen = record(() => ok())
    const r = await call(t, allKeys(), "particle-ai/particle-1", [{ role: "user", content: [{ type: "text", text: "All of these?" }, ...imageParts(9)] }])
    expect(r.status).toBe(200)
    expect(imagePartsOf(seen[0]!.body.messages)).toBe(9)
    expect(r.headers.get("x-cmux-images-omitted")).toBeNull()
  })

  // Near the end: a failed Vercel attempt puts Vercel in the spend guard's cooldown for the next tests.
  it("fails over from Vercel to OpenRouter before the first byte", async () => {
    const { t } = await paidPerson("router-vercel-failover")
    const seen = record((p) => (p === "vercel" ? new Response("no credit", { status: 402 }) : ok()))
    expect((await call(t, allKeys(), DS)).status).toBe(200)
    expect(seen.map((s) => s.provider)).toEqual(["vercel", "openrouter"])
  })

  // After the last failover test: every provider answers 503 here, which cools them all down.
  it("never routes another model to Particle, even when every other provider fails", async () => {
    // The cmux Particle key's traffic is outside Particle's zero-data-retention terms: only a caller
    // who picks Particle-1 may reach it, never a DeepSeek or GLM caller through failover.
    const { t } = await paidPerson("router-particle-only-own")
    const seen = record(() => new Response("busy", { status: 503 }))
    for (const model of [DS, "z-ai/glm-5.3-flash"]) await call(t, allKeys(), model)
    expect(seen.length).toBeGreaterThan(0)
    expect(seen.map((s) => s.provider)).not.toContain("particle")
  })
})
