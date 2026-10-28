import { env } from "cloudflare:workers"
import { afterEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.ts"

/**
 * The 15-minute cron (wrangler.jsonc, development and staging) runs only the Stripe usage sync, and never in
 * production until its live switch (plans/cmux-next/usage-billing.md section 10). No projection database is
 * read on it: the Postgres/MySQL compare left with the Postgres read path (cmuxterm-hq#4767 step 8).
 */
const USAGE_CRON = "*/15 * * * *"
/** A Hyperdrive binding that fails the test if anything reads it (a database connection would). */
const untouchable = (name: string) =>
  new Proxy({}, { get: (_t, key) => (key === "then" ? undefined : expect.unreachable(`${name}.${String(key)} was read`)) })
const withEnv = (overrides: Record<string, unknown>) => ({
  ...(env as object),
  HYPERDRIVE: untouchable("HYPERDRIVE"),
  PS_MYSQL: untouchable("PS_MYSQL"),
  PS_MYSQL_RO: untouchable("PS_MYSQL_RO"),
  ...overrides
})
const run = (e: Record<string, unknown>) =>
  worker.scheduled!({ cron: USAGE_CRON, scheduledTime: Date.now(), noRetry: () => undefined } as unknown as ScheduledController, e as never)
const recordFetches = (status: number) => {
  const calls: Array<string> = []
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL) => {
    calls.push(String(input instanceof Request ? input.url : input))
    return new Response(JSON.stringify({ error: { message: "test" } }), { status })
  })
  return calls
}

describe("the 15-minute cron", () => {
  afterEach(() => vi.restoreAllMocks())

  it("in production, with a usage key, calls nothing and reads no database binding", async () => {
    const calls = recordFetches(500)
    const logs = vi.spyOn(console, "log").mockImplementation(() => {})
    const errors = vi.spyOn(console, "error").mockImplementation(() => {})
    await run(withEnv({ ENVIRONMENT: "production", STRIPE_USAGE_KEY: "sk_test_fake-usage-sync-key" }))
    expect(calls).toEqual([])
    expect([...logs.mock.calls, ...errors.mock.calls]).toEqual([])
  })

  it("on staging without a usage key, does nothing", async () => {
    const calls = recordFetches(500)
    await run(withEnv({ ENVIRONMENT: "staging", STRIPE_USAGE_KEY: undefined }))
    expect(calls).toEqual([])
  })

  it("on staging, runs the usage sync; a sync failure is logged and does not fail the run", async () => {
    const calls = recordFetches(500)
    vi.spyOn(console, "log").mockImplementation(() => {})
    vi.spyOn(console, "error").mockImplementation(() => {})
    await expect(run(withEnv({ ENVIRONMENT: "staging", STRIPE_USAGE_KEY: "sk_test_fake-usage-sync-key" }))).resolves.toBeUndefined()
    expect(calls.some((u) => u.startsWith("https://api.stripe.com/"))).toBe(true)
  })
})
