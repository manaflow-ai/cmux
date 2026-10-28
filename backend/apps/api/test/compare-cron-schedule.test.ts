import { env } from "cloudflare:workers"
import { afterEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.ts"

/**
 * The 15-minute cron (wrangler.jsonc, every environment): the projection compare does nothing until a
 * MySQL projection switch is set, and in production the usage sync beside it stays off until its live
 * switch (plans/cmux-next/usage-billing.md section 10), so adding the cron to production for the
 * Vitess cutover (cmuxterm-hq#4767 step 2) changes nothing there.
 */
const COMPARE_CRON = "*/15 * * * *"
const run = (overrides: Record<string, unknown>) =>
  worker.scheduled!({ cron: COMPARE_CRON, scheduledTime: Date.now(), noRetry: () => undefined } as unknown as ScheduledController, { ...(env as object), PROJECTION_PRIMARY: undefined, PROJECTION_SHADOW: undefined, ...overrides } as never)

describe("the 15-minute cron", () => {
  afterEach(() => vi.restoreAllMocks())

  it("in production, with a usage key and no projection switch, calls nothing outside the Worker", async () => {
    const calls: Array<string> = []
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL) => {
      calls.push(String(input instanceof Request ? input.url : input))
      return new Response("{}", { status: 500 })
    })
    const logs = vi.spyOn(console, "log").mockImplementation(() => {})
    const errors = vi.spyOn(console, "error").mockImplementation(() => {})
    await run({ ENVIRONMENT: "production", STRIPE_USAGE_KEY: "sk_test_fake-usage-sync-key" })
    expect(calls).toEqual([])
    expect([...logs.mock.calls, ...errors.mock.calls]).toEqual([])
  })

  it("outside production, the usage sync runs beside the compare", async () => {
    const calls: Array<string> = []
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL) => {
      calls.push(String(input instanceof Request ? input.url : input))
      return new Response(JSON.stringify({ error: { message: "test" } }), { status: 500 })
    })
    vi.spyOn(console, "log").mockImplementation(() => {})
    vi.spyOn(console, "error").mockImplementation(() => {})
    await run({ ENVIRONMENT: "staging", STRIPE_USAGE_KEY: "sk_test_fake-usage-sync-key" })
    expect(calls.some((u) => u.startsWith("https://api.stripe.com/"))).toBe(true)
  })
})
