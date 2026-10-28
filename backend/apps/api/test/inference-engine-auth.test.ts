import { env } from "cloudflare:workers"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import worker from "../src/index.ts"
import { MODELS, type ModelEntry } from "../src/inference/catalog.ts"
import { servingRoutes } from "../src/inference/route.ts"
import { makeTenant } from "./setup/tenant.ts"
import { paidPerson } from "./setup/inference-person.ts"

/**
 * Chief-engines design section 4 (decided by Lawrence, Oct 28): every free model reaches the free
 * tier only through our Vercel AI Gateway route, Chief engines call /v1/inference with an install
 * bearer token, and a model outside the catalog allowlist is refused with an error that names the
 * allowlist. Auth is exercised at the route with a real install token (tests/setup/tenant.ts).
 */

const keys = { INFERENCE_OPENROUTER_KEY: "k-or", INFERENCE_DEEPINFRA_KEY: "k-di", INFERENCE_VERCEL_GATEWAY_KEY: "k-vc" } as any

const model = (id: string): ModelEntry => {
  const m = MODELS.find((x) => x.id === id)
  if (!m) throw new Error(`no model ${id}`)
  return m
}

const chatWith = async (bearer: string, body: Record<string, unknown>) => {
  const ctx = createExecutionContext()
  const res = await worker.fetch!(
    new Request("https://api.test/v1/inference/chat/completions", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${bearer}` }, body: JSON.stringify(body) }) as any,
    env as any,
    ctx
  )
  const text = await res.text()
  await waitOnExecutionContext(ctx)
  return { status: res.status, body: JSON.parse(text) as any }
}

describe("free models reach only the Vercel AI Gateway route (section 4)", () => {
  it.each(["qwen/qwen3.7-flash", "openai/gpt-oss-120b", "deepseek/deepseek-v4-flash"])("%s: a free device gets only the vercel route", (id) => {
    expect(model(id).free).toBe(true)
    expect(servingRoutes(keys, model(id), true).map((r) => r.provider)).toEqual(["vercel"])
  })

  it("a paid caller keeps every keyed route for gpt-oss-120b, cheapest first", () => {
    expect(servingRoutes(keys, model("openai/gpt-oss-120b"), false).map((r) => r.provider)).toEqual(["deepinfra", "vercel", "openrouter"])
  })
})

describe("Chief engine calls (section 4)", () => {
  it("an install bearer token is authenticated at /v1/inference (no 401)", async () => {
    const t = await makeTenant("engine-install")
    const r = await chatWith(t.installToken, { model: "deepseek/deepseek-v4-flash", max_tokens: 16, messages: [{ role: "user", content: "hi" }] })
    expect(r.status).not.toBe(401)
    expect(r.body?.error?.code).not.toBe("auth.required")
  })

  it("a model outside the catalog allowlist is a 404 whose message names the allowlist", async () => {
    // A paid person: the caller resolves at once, so the model check is what answers (no plan check 503).
    const { t } = await paidPerson("engine-unknown")
    const r = await chatWith(t, { model: "example/not-in-catalog", max_tokens: 16, messages: [{ role: "user", content: "hi" }] })
    expect(r.status).toBe(404)
    expect(r.body.error.code).toBe("model.not_found")
    for (const m of MODELS) expect(r.body.error.message).toContain(m.id)
  })
})
