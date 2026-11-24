// The Chief computer's plan check (chief-brain-cc/sandbox-plan.ts ownerEntitled): a platform that does not answer is
// cached briefly as unknown (not entitled in production), never as paid, so the profile's status polls do not ask it
// on every read; an answer is kept longer.
import { afterEach, describe, expect, it, vi } from "vitest"
import { FAILED_FRESH_MS, ownerEntitled } from "../src/chief-brain-cc/sandbox-plan.ts"

const OWNER = "user_00000000000000000001"

const brain = (environment: string, reply: () => Promise<unknown>) => {
  const calls = { n: 0 }
  const ns = { idFromName: (name: string) => name, get: () => ({ readOp: async () => (calls.n++, reply()) }) }
  const b = { sql: {}, doEnv: { ENVIRONMENT: environment, CLOUD_ALLOWED_TEAMS: "*", CLOUD_DO: ns } }
  return { b: b as never, calls }
}

afterEach(() => vi.useRealTimers())

describe("ownerEntitled when the platform does not answer", () => {
  it("answers not entitled in production and asks again only after FAILED_FRESH_MS", async () => {
    vi.useFakeTimers({ now: 1_000_000 })
    const { b, calls } = brain("production", () => Promise.reject(new Error("platform down")))
    for (let i = 0; i < 5; i++) expect(await ownerEntitled(b, OWNER)).toBe(false)
    expect(calls.n).toBe(1)
    vi.setSystemTime(1_000_000 + FAILED_FRESH_MS + 1)
    expect(await ownerEntitled(b, OWNER)).toBe(false)
    expect(calls.n).toBe(2)
  })

  it("never keeps a failure as paid: a later paid answer is taken once the failure is stale", async () => {
    vi.useFakeTimers({ now: 2_000_000 })
    let up = false
    const { b, calls } = brain("production", () => (up ? Promise.resolve({ ok: true, value: { plan_id: "pro" } }) : Promise.resolve({ ok: false, error: { code: "unavailable" } })))
    expect(await ownerEntitled(b, OWNER)).toBe(false)
    up = true
    expect(await ownerEntitled(b, OWNER)).toBe(false)
    vi.setSystemTime(2_000_000 + FAILED_FRESH_MS + 1)
    expect(await ownerEntitled(b, OWNER)).toBe(true)
    // The paid answer is kept past FAILED_FRESH_MS.
    vi.setSystemTime(2_000_000 + 2 * FAILED_FRESH_MS + 2)
    expect(await ownerEntitled(b, OWNER)).toBe(true)
    expect(calls.n).toBe(2)
  })

  it("keeps the stub rule outside production while the failure is cached", async () => {
    vi.useFakeTimers({ now: 3_000_000 })
    const { b, calls } = brain("test", () => Promise.reject(new Error("platform down")))
    expect(await ownerEntitled(b, OWNER)).toBe(true)
    expect(await ownerEntitled(b, OWNER)).toBe(true)
    expect(calls.n).toBe(1)
  })
})
