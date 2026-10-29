import { env } from "cloudflare:workers"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.ts"
import { autoReloadDecision } from "../src/credits-autoreload.ts"
import { inDO, post, testEnv, token } from "./setup/inference-person.ts"

/**
 * Prepaid credits v2 (plans/cmux-next/paid-plans-DESIGN.md §6): any amount in a range, and auto-reload
 * (threshold, reload amount, monthly cap) that charges the team's saved card off-session. Payment
 * service faked at api.stripe.com.
 */
const ORIGIN = "https://api.test"
const KEYED = { STRIPE_CREDITS_KEY: "sk_test_fake-credits" }

type Made = { path: string; form: Record<string, string> }
const fakeStripe = (opts: { card?: boolean; decline?: boolean } = {}) => {
  const made: Made[] = []
  const real = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input))
    if (url.hostname !== "api.stripe.com") return real(input, init)
    const form = Object.fromEntries(new URLSearchParams(String(init?.body ?? "")))
    made.push({ path: url.pathname, form })
    if (url.pathname.endsWith("/payment_methods")) return Response.json({ data: opts.card === false ? [] : [{ id: "pm_card_visa", type: "card" }] })
    if (url.pathname === "/v1/payment_intents") {
      if (opts.decline) return Response.json({ error: { code: "card_declined", message: "Your card was declined." } }, { status: 402 })
      return Response.json({ id: `pi_test_${made.length}`, status: "succeeded", amount: Number(form.amount), currency: "usd", metadata: {} })
    }
    return Response.json({ id: `cs_test_${made.length}`, url: `https://checkout.stripe.com/c/pay/cs_test_${made.length}` })
  })
  return made
}

const call = async (method: string, path: string, t: string, body?: unknown) => {
  const ctx = createExecutionContext()
  const res = await worker.fetch!(
    new Request(`${ORIGIN}${path}`, { method, headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }) as any,
    { ...env, CLOUD_API_ORIGIN: ORIGIN, ...KEYED } as any,
    ctx
  )
  await waitOnExecutionContext(ctx)
  return { status: res.status, body: (await res.json().catch(() => ({}))) as any }
}

const person = async (name: string) => {
  const t = await token(name)
  const team = (await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })).value.personal_team as string
  return { t, team }
}

const meter = (team: string) => testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team))

afterEach(() => {
  vi.restoreAllMocks()
})

describe("any amount (paid-plans §6.2)", () => {
  it("takes any amount with at most two decimals inside the range, and refuses the rest", async () => {
    const { t } = await person("credits-any")
    const made = fakeStripe()
    expect((await call("POST", "/v1/credits/topup", t, { usd: 37.5 })).status).toBe(200)
    expect(made[0]!.form["line_items[0][price_data][unit_amount]"]).toBe("3750")
    expect((await call("POST", "/v1/credits/topup", t, { usd: 2500 })).status).toBe(200)
    for (const usd of [4.99, 2500.01, 10.001, -5, "20"]) expect((await call("POST", "/v1/credits/topup", t, { usd })).status).toBe(400)
  })

  it("the balance read and a top-up save the card for auto-reload and name the range", async () => {
    const { t } = await person("credits-range")
    const made = fakeStripe()
    const r = await call("GET", "/v1/credits", t)
    expect(r.body.value.topup).toMatchObject({ min_usd: 5, max_usd: 2500 })
    await call("POST", "/v1/credits/topup", t, { usd: 10 })
    expect(made[0]!.form["payment_intent_data[setup_future_usage]"]).toBe("off_session")
  })
})

describe("auto-reload decision (paid-plans §6.3)", () => {
  const on = { enabled: true, threshold_micros: 5_000_000, amount_micros: 20_000_000, monthly_cap_micros: 50_000_000 }
  it("reloads below the threshold, inside the cap, with none in flight", () => {
    expect(autoReloadDecision(on, 4_000_000, 0, false)).toBe(20_000_000)
    expect(autoReloadDecision(on, 5_000_000, 0, false)).toBeNull()
    expect(autoReloadDecision(on, 4_000_000, 40_000_000, false)).toBeNull()
    expect(autoReloadDecision(on, 4_000_000, 0, true)).toBeNull()
    expect(autoReloadDecision({ ...on, enabled: false }, 0, 0, false)).toBeNull()
  })
})

describe("auto-reload settings and charge (paid-plans §6.3)", () => {
  it("refuses to turn on without a saved card", async () => {
    const { t } = await person("autoreload-nocard")
    fakeStripe({ card: false })
    const r = await call("PUT", "/v1/credits/auto-reload", t, { enabled: true, threshold_usd: 5, amount_usd: 20, monthly_cap_usd: 100 })
    expect(r.status).toBe(409)
    expect(r.body.error.code).toBe("credits.no_saved_card")
  })

  it("validates the settings", async () => {
    const { t, team } = await person("autoreload-bad")
    await inDO(meter(team), async (m) => m.setCreditCustomer(team, "test", "cus_TestAuto1"))
    fakeStripe()
    for (const bad of [
      { enabled: true, threshold_usd: 5, amount_usd: 2, monthly_cap_usd: 100 },
      { enabled: true, threshold_usd: -1, amount_usd: 20, monthly_cap_usd: 100 },
      { enabled: true, threshold_usd: 5, amount_usd: 20, monthly_cap_usd: 10 }
    ])
      expect((await call("PUT", "/v1/credits/auto-reload", t, bad)).status).toBe(400)
  })

  it("turning it on below the threshold reloads at once, once, and the read shows it", async () => {
    const { t, team } = await person("autoreload-now")
    await inDO(meter(team), async (m) => m.setCreditCustomer(team, "test", "cus_TestAuto2"))
    const made = fakeStripe()
    const r = await call("PUT", "/v1/credits/auto-reload", t, { enabled: true, threshold_usd: 5, amount_usd: 20, monthly_cap_usd: 30 })
    expect(r.status).toBe(200)
    const intents = made.filter((m) => m.path === "/v1/payment_intents")
    expect(intents).toHaveLength(1)
    expect(intents[0]!.form).toMatchObject({ amount: "2000", currency: "usd", customer: "cus_TestAuto2", payment_method: "pm_card_visa", off_session: "true", confirm: "true" })
    const read = await call("GET", "/v1/credits/auto-reload", t)
    expect(read.body.value).toMatchObject({ enabled: true, threshold_usd: 5, amount_usd: 20, monthly_cap_usd: 30, month_reloaded_usd: 20, last_error: null })
    const bal = await call("GET", "/v1/credits", t)
    expect(bal.body.value.available_usd).toBe(20)
  })

  it("a declined card turns auto-reload off with the reason", async () => {
    const { t, team } = await person("autoreload-decline")
    await inDO(meter(team), async (m) => m.setCreditCustomer(team, "test", "cus_TestAuto3"))
    fakeStripe({ decline: true })
    await call("PUT", "/v1/credits/auto-reload", t, { enabled: true, threshold_usd: 5, amount_usd: 20, monthly_cap_usd: 100 })
    const read = await call("GET", "/v1/credits/auto-reload", t)
    expect(read.body.value.enabled).toBe(false)
    expect(read.body.value.last_error).toMatch(/declined/)
  })

  it("a charge that drops the balance below the threshold reloads; the monthly cap stops the next", async () => {
    const { t, team } = await person("autoreload-settle")
    await inDO(meter(team), async (m) => {
      await m.setCreditCustomer(team, "test", "cus_TestAuto4")
      await m.creditAdd(team, "grant:seed", "grant", 30_000_000, "test", null)
    })
    const made = fakeStripe()
    expect((await call("PUT", "/v1/credits/auto-reload", t, { enabled: true, threshold_usd: 10, amount_usd: 20, monthly_cap_usd: 20 })).status).toBe(200)
    expect(made.filter((m) => m.path === "/v1/payment_intents")).toHaveLength(0)
    await inDO(meter(team), async (m) => {
      await m.creditSettle(team, "call-1", 25_000_000, 25_000_000, null, null)
      await m.autoReloadIdle()
    })
    expect(made.filter((m) => m.path === "/v1/payment_intents")).toHaveLength(1)
    await inDO(meter(team), async (m) => {
      await m.creditSettle(team, "call-2", 20_000_000, 20_000_000, null, null)
      await m.autoReloadIdle()
    })
    expect(made.filter((m) => m.path === "/v1/payment_intents")).toHaveLength(1)
  })
})
