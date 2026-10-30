import { env } from "cloudflare:workers"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import worker from "../src/index.ts"
import { paidPerson, post, token } from "./setup/inference-person.ts"

/**
 * The console's billing page reads one route (plans/cmux-next/paid-plans-DESIGN.md §3):
 * GET /v1/billing/summary answers the caller's plan, this period's AI usage against the included
 * amount, the prepaid credits balance, the plans above the current one with a test-mode checkout
 * link each, and where the person manages the subscription.
 */
const ORIGIN = "https://api.test"

const summary = async (t: string | null, runEnv: Record<string, unknown> = {}) => {
  const ctx = createExecutionContext()
  const headers: Record<string, string> = t ? { authorization: `Bearer ${t}` } : {}
  const res = await worker.fetch!(new Request(`${ORIGIN}/v1/billing/summary`, { headers }) as any, { ...env, CLOUD_API_ORIGIN: ORIGIN, ...runEnv } as any, ctx)
  await waitOnExecutionContext(ctx)
  return { status: res.status, body: (await res.json()) as any }
}

describe("GET /v1/billing/summary (paid plans dashboard)", () => {
  it("refuses a caller who is not signed in", async () => {
    const r = await summary(null)
    expect(r.status).toBe(401)
    expect(r.body.ok).toBe(false)
  })

  it("a free person: Free plan, credits, and Pro and Max offered with a test checkout link", async () => {
    const t = await token("billing-summary-free")
    await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })
    const r = await summary(t, { STRIPE_CREDITS_KEY: "sk_test_fake-credits" })
    expect(r.status).toBe(200)
    const v = r.body.value
    expect(v.personal).toBe(true)
    expect(v.plan).toMatchObject({ id: null, paid: false, name: "Free" })
    expect(v.credits).toMatchObject({ available_usd: 0, balance_usd: 0 })
    expect(v.credits.topup_amounts_usd).toEqual([10, 20, 50, 100])
    expect(v.credits).toMatchObject({ topup_min_usd: 5, topup_max_usd: 2500 })
    expect(v.upgrade.map((p: { id: string }) => p.id)).toEqual(["pro", "max"])
    expect(v.upgrade[0]).toMatchObject({ name: "cmux Pro", usd: 50 })
    expect(v.upgrade[0].checkout_url).toMatch(/^https:\/\/api\.test\/v1\/billing\/plan\/[A-Za-z0-9_-]+\.[0-9a-f]{64}$/)
    expect(v.manage_url).toBe("https://cmux.com/dashboard/billing")
    expect(v.pricing_url).toBe("https://cmux.com/pricing")
    expect(v.test_mode).toBe(true)
  })

  it("a Pro person: Pro plan, usage against the included amount, only Max offered", async () => {
    const { t } = await paidPerson("billing-summary-pro", "pro")
    const r = await summary(t, { STRIPE_CREDITS_KEY: "sk_test_fake-credits" })
    expect(r.status).toBe(200)
    const v = r.body.value
    expect(v.plan).toMatchObject({ id: "pro", paid: true, name: "cmux Pro" })
    expect(v.usage).toMatchObject({ included_usd: expect.any(Number), spent_usd: 0, billed: false })
    expect(v.usage.period_end).toBeGreaterThan(v.usage.period_start)
    expect(v.upgrade.map((p: { id: string }) => p.id)).toEqual(["max"])
  })

  it("no test billing key: plans still listed, no checkout link, not test mode", async () => {
    const t = await token("billing-summary-nokey")
    await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })
    const r = await summary(t, { STRIPE_CREDITS_KEY: "", STRIPE_USAGE_KEY: "" })
    expect(r.status).toBe(200)
    expect(r.body.value.upgrade[0].checkout_url).toBeNull()
    expect(r.body.value.credits.topup_amounts_usd).toEqual([])
    expect(r.body.value.test_mode).toBe(false)
  })
})
