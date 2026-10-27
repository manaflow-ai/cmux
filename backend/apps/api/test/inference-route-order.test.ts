import { env } from "cloudflare:workers"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.ts"
import { paidPerson } from "./setup/inference-person.ts"

/**
 * Paid plan step 2 (plans/cmux-next/paid-plan.md §2): the router tries the cheapest keyed provider
 * first (list price per route), and outside production `x-cmux-provider` pins one provider so staging
 * can check each provider on its own. Providers faked at their HTTP boundary.
 */

const HOSTS: Record<string, string> = { "openrouter.ai": "openrouter", "api.deepinfra.com": "deepinfra", "ai-gateway.vercel.sh": "vercel" }

const recordProviders = (reply: (provider: string) => Response) => {
  const asked: Array<string> = []
  const real = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input))
    const provider = HOSTS[url.hostname]
    if (!provider) return real(input, init)
    asked.push(provider)
    return reply(provider)
  })
  return asked
}

const ok = () => Response.json({ id: "x", choices: [{ index: 0, message: { role: "assistant", content: "hi" } }], usage: { prompt_tokens: 5, completion_tokens: 2 } })

const keyed = (extra: Record<string, string> = {}) => ({ ...env, INFERENCE_OPENROUTER_KEY: "k-or", INFERENCE_DEEPINFRA_KEY: "k-di", INFERENCE_VERCEL_GATEWAY_KEY: "k-vc", ...extra }) as any

const call = async (t: string, runEnv: unknown, model: string, headers: Record<string, string> = {}) => {
  const ctx = createExecutionContext()
  const res = await worker.fetch!(
    new Request("https://api.test/v1/inference/chat/completions", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}`, ...headers }, body: JSON.stringify({ model, max_tokens: 32, messages: [{ role: "user", content: "hi" }] }) }) as any,
    runEnv as any,
    ctx
  )
  const text = await res.text()
  await waitOnExecutionContext(ctx)
  return { status: res.status, text }
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe("router provider order (paid-plan step 2)", () => {
  it("tries the cheapest keyed provider first", async () => {
    const { t } = await paidPerson("route-order-cheapest")
    const asked = recordProviders(() => ok())
    // gpt-oss-120b list prices 2026-10-23: deepinfra 0.037/0.17, vercel 0.10/0.50, openrouter 0.15/0.60.
    expect((await call(t, keyed(), "openai/gpt-oss-120b")).status).toBe(200)
    expect(asked).toEqual(["deepinfra"])
  })

  it("falls back to the next cheapest when the cheapest fails before the first byte", async () => {
    const { t } = await paidPerson("route-order-fallback")
    const asked = recordProviders((p) => (p === "deepinfra" ? new Response("busy", { status: 429 }) : ok()))
    expect((await call(t, keyed(), "openai/gpt-oss-120b")).status).toBe(200)
    expect(asked).toEqual(["deepinfra", "vercel"])
  })

  it("outside production x-cmux-provider pins one provider", async () => {
    const { t } = await paidPerson("route-order-pin")
    const asked = recordProviders(() => ok())
    expect((await call(t, keyed(), "openai/gpt-oss-120b", { "x-cmux-provider": "vercel" })).status).toBe(200)
    expect(asked).toEqual(["vercel"])
  })

  it("a pin to a provider that does not serve the model is a 400", async () => {
    const { t } = await paidPerson("route-order-pin-miss")
    recordProviders(() => ok())
    const r = await call(t, keyed(), "moonshotai/kimi-k2.7-code", { "x-cmux-provider": "deepinfra" })
    expect(r.status).toBe(400)
    expect(JSON.parse(r.text).error.code).toBe("provider.not_on_route")
  })
})
