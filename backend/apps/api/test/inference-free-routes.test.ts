import { describe, expect, it } from "vitest"
import { MODELS, type ModelEntry } from "../src/inference/catalog.ts"
import { servingRoutes } from "../src/inference/route.ts"

/**
 * Free DeepSeek fallback (user, 2026-10-27): a signed-out Mac that passes App Attest gets DeepSeek V4 Flash
 * only through our own Vercel AI Gateway route. Paid callers keep every keyed route, cheapest first.
 * Pure routing, no provider calls: the route list is what a request may reach.
 */

const keys = { INFERENCE_OPENROUTER_KEY: "k-or", INFERENCE_DEEPINFRA_KEY: "k-di", INFERENCE_VERCEL_GATEWAY_KEY: "k-vc" } as any

const model = (id: string): ModelEntry => {
  const m = MODELS.find((x) => x.id === id)
  if (!m) throw new Error(`no model ${id}`)
  return m
}

describe("free DeepSeek route", () => {
  it("the free tier serves DeepSeek V4 Flash", () => {
    expect(model("deepseek/deepseek-v4-flash").free).toBe(true)
  })

  it("a free device reaches DeepSeek V4 Flash only through the Vercel AI Gateway", () => {
    expect(servingRoutes(keys, model("deepseek/deepseek-v4-flash"), true).map((r) => r.provider)).toEqual(["vercel"])
  })

  it("a paid caller keeps every keyed DeepSeek V4 Flash route, cheapest first", () => {
    expect(servingRoutes(keys, model("deepseek/deepseek-v4-flash"), false).map((r) => r.provider)).toEqual(["deepinfra", "openrouter", "vercel"])
  })

  it("a free device's pin to a provider outside its free list finds no route", () => {
    expect(servingRoutes(keys, model("deepseek/deepseek-v4-flash"), true, "deepinfra")).toEqual([])
  })

  it("a model without a free provider list keeps every keyed route for the free tier", () => {
    expect(servingRoutes(keys, model("moonshotai/kimi-k3"), true).map((r) => r.provider).sort()).toEqual(["deepinfra", "openrouter", "vercel"])
  })
})
