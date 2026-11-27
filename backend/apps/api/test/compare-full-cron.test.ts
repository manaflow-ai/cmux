import { env } from "cloudflare:workers"
import { afterEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.ts"
import { compareFullFromEnv } from "../src/projection-compare-full-cron.ts"

/**
 * The hourly full verify (wrangler.jsonc: staging's "7 * * * *"): its own invocation, read only, and only
 * while a MySQL projection switch is set. The rows themselves are compared in backend/db/test-mysql/compare-full.test.ts.
 */
const FULL_CRON = "7 * * * *"
/** A binding that fails the test if anything reads it (a database connection would). */
const untouchable = (name: string) =>
  new Proxy({}, { get: (_t, key) => (key === "then" ? undefined : expect.unreachable(`${name}.${String(key)} was read`)) })
const staging = (overrides: Record<string, unknown> = {}) => ({
  ...(env as object),
  ENVIRONMENT: "staging",
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
  worker.scheduled!({ cron: FULL_CRON, scheduledTime: Date.parse("2026-10-28T00:07:00Z"), noRetry: () => undefined } as unknown as ScheduledController, e as never)

describe("the hourly full projection verify", () => {
  afterEach(() => vi.restoreAllMocks())

  it("without a MySQL switch, the full cron reads no binding, calls nothing and runs nothing else (no feed sweep)", async () => {
    const calls: Array<string> = []
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL) => {
      calls.push(String(input instanceof Request ? input.url : input))
      return new Response("{}", { status: 500 })
    })
    const logs = vi.spyOn(console, "log").mockImplementation(() => {})
    const errors = vi.spyOn(console, "error").mockImplementation(() => {})
    await run(staging())
    expect(calls).toEqual([])
    expect([...logs.mock.calls, ...errors.mock.calls]).toEqual([])
  })

  it("a switch set without the read bindings fails the run with an unconfigured event, and never reads the MySQL writer", async () => {
    const errors = vi.spyOn(console, "error").mockImplementation(() => {})
    await expect(run(staging({ PROJECTION_SHADOW: "mysql", HYPERDRIVE: undefined }))).rejects.toThrow("projection full compare unconfigured")
    expect(JSON.parse(String(errors.mock.calls[0]?.[0]))).toMatchObject({ event: "projection.compare.full.unconfigured", level: "error", postgres: false, mysql: true })
    await expect(compareFullFromEnv(staging({ PROJECTION_PRIMARY: "mysql", PS_MYSQL_RO: undefined }) as never, Date.now())).rejects.toThrow("projection full compare unconfigured")
    expect(JSON.parse(String(errors.mock.calls[1]?.[0]))).toMatchObject({ event: "projection.compare.full.unconfigured", postgres: true, mysql: false })
  })
})
