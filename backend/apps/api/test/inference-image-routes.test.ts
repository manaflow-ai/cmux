import { Effect, Result } from "effect"
import { describe, expect, it } from "vitest"
import type { ModelEntry, ProviderRoute } from "../src/inference/catalog.ts"
import { fitToRoutes, type ImagePart } from "../src/inference/chat-request.ts"

/**
 * A route that publishes a lower image limit than its model is skipped for a request with more
 * images, never the cause of a refusal (review of #41163). No catalog route publishes one today, so
 * a test model with two routes stands in: `low` takes 10 images, `open` the model's own limit (none).
 */

const low: ProviderRoute = { provider: "openrouter", id: "test/low", maxImages: 10 }
const open: ProviderRoute = { provider: "vercel", id: "test/open" }
const model = (routes: ReadonlyArray<ProviderRoute>): ModelEntry => ({
  id: "test/vision",
  name: "Test vision",
  card: { input: 1, output: 1 },
  context: 1_000_000,
  maxOutput: 1_000,
  defaultMaxTokens: 1_000,
  tools: false,
  vision: { tokensPerImage: 1 },
  routes
})

const image = { type: "image_url", image_url: { url: "data:image/png;base64,AA==" } }

/** One new user message with `count` images, and where they are. */
const newMessage = (count: number): { messages: ReadonlyArray<unknown>; found: ReadonlyArray<ImagePart> } => ({
  messages: [{ role: "user", content: [{ type: "text", text: "All of these?" }, ...Array.from({ length: count }, () => image)] }],
  found: Array.from({ length: count }, (_, i) => ({ message: 0, part: i + 1 }))
})

const fit = (routes: ReadonlyArray<ProviderRoute>, count: number) => {
  const { messages, found } = newMessage(count)
  return Effect.runPromise(Effect.result(fitToRoutes(messages, found, model(routes), routes)))
}

describe("image limits per route", () => {
  it("skips the route that takes fewer images and sends all of them through the other", async () => {
    const result = await fit([low, open], 11)
    expect(Result.isSuccess(result)).toBe(true)
    if (!Result.isSuccess(result)) return
    expect(result.success.routes.map((r) => r.id)).toEqual(["test/open"])
    expect(result.success.images).toBe(11)
    expect(result.success.omittedImages).toBe(0)
  })

  it("keeps the low route for a request it takes", async () => {
    const result = await fit([low, open], 10)
    expect(Result.isSuccess(result) && result.success.routes.map((r) => r.id)).toEqual(["test/low", "test/open"])
  })

  it("refuses a new message past the only route's limit, and says what to do", async () => {
    const result = await fit([low], 11)
    expect(Result.isFailure(result)).toBe(true)
    if (!Result.isFailure(result)) return
    expect(result.failure.status).toBe(400)
    expect(result.failure.message).toBe("test/vision takes at most 10 images in one message; send the rest in another message")
  })
})
