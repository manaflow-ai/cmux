import { env } from "cloudflare:workers"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.ts"
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
  "own.test": "custom"
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
    ...extra
  }) as any

const RED_PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
const imageMessages = [{ role: "user", content: [{ type: "text", text: "What color?" }, { type: "image_url", image_url: { url: RED_PNG } }] }]

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

  it("fails over from Vercel to OpenRouter before the first byte", async () => {
    const { t } = await paidPerson("router-vercel-failover")
    const seen = record((p) => (p === "vercel" ? new Response("no credit", { status: 402 }) : ok()))
    expect((await call(t, allKeys(), DS)).status).toBe(200)
    expect(seen.map((s) => s.provider)).toEqual(["vercel", "openrouter"])
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
})
