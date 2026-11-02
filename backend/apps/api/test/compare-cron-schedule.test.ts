import { env } from "cloudflare:workers"
import { afterEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.ts"
import { compareFromEnv } from "../src/projection-compare-cron.ts"

/**
 * The 15-minute cron (wrangler.jsonc, every environment): the projection compare runs only while a
 * MySQL projection switch is set, and in production the usage sync beside it stays off until its live
 * switch (plans/cmux-next/usage-billing.md section 10), so adding the cron to production for the
 * Vitess dual write (cmuxterm-hq#4767 step 2) starts the compare there and nothing else.
 */
const COMPARE_CRON = "*/15 * * * *"
/** A Hyperdrive binding that fails the test if anything reads it (a database connection would). */
const untouchable = (name: string) =>
  new Proxy({}, { get: (_t, key) => (key === "then" ? undefined : expect.unreachable(`${name}.${String(key)} was read`)) })
/** A production env with no projection switch, every database binding trapped. */
const production = (overrides: Record<string, unknown> = {}) => ({
  ...(env as object),
  ENVIRONMENT: "production",
  PROJECTION_PRIMARY: undefined,
  PROJECTION_SHADOW: undefined,
  PROJECTION_READS: undefined,
  HYPERDRIVE: untouchable("HYPERDRIVE"),
  HYPERDRIVE_RO: untouchable("HYPERDRIVE_RO"),
  PS_MYSQL: untouchable("PS_MYSQL"),
  PS_MYSQL_RO: untouchable("PS_MYSQL_RO"),
  ...overrides
})
const run = (e: Record<string, unknown>) =>
  worker.scheduled!({ cron: COMPARE_CRON, scheduledTime: Date.now(), noRetry: () => undefined } as unknown as ScheduledController, e as never)

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
    await run(production({ STRIPE_USAGE_KEY: "sk_test_fake-usage-sync-key" }))
    expect(calls).toEqual([])
    expect([...logs.mock.calls, ...errors.mock.calls]).toEqual([])
  })

  it("the compare reads no database binding without a MySQL switch; with one set and a binding missing, the run fails", async () => {
    await expect(compareFromEnv(production() as never)).resolves.toBeUndefined()
    const errors = vi.spyOn(console, "error").mockImplementation(() => {})
    await expect(compareFromEnv(production({ PROJECTION_SHADOW: "mysql", HYPERDRIVE: undefined }) as never)).rejects.toThrow("projection compare unconfigured")
    expect(JSON.parse(String(errors.mock.calls[0]?.[0]))).toMatchObject({ event: "projection.compare.unconfigured", postgres: false, mysql: true })
  })

  it("the Worker's 15-minute run fails when the compare cannot run (a switch set, a binding missing)", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {})
    vi.spyOn(console, "log").mockImplementation(() => {})
    // PROJECTION_READS stays unset so the shadow-read probe beside it does nothing.
    await expect(run(production({ PROJECTION_SHADOW: "mysql", HYPERDRIVE: undefined }))).rejects.toThrow("projection compare unconfigured")
  })

  it("outside production, the usage sync runs beside the compare", async () => {
    const calls: Array<string> = []
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL) => {
      calls.push(String(input instanceof Request ? input.url : input))
      return new Response(JSON.stringify({ error: { message: "test" } }), { status: 500 })
    })
    vi.spyOn(console, "log").mockImplementation(() => {})
    vi.spyOn(console, "error").mockImplementation(() => {})
    await run(production({ ENVIRONMENT: "staging", STRIPE_USAGE_KEY: "sk_test_fake-usage-sync-key" }))
    expect(calls.some((u) => u.startsWith("https://api.stripe.com/"))).toBe(true)
  })
})
