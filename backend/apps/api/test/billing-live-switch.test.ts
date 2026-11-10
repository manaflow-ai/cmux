import { env } from "cloudflare:workers"
import { afterEach, describe, expect, it, vi } from "vitest"
import { liveAllowList, syncUsage, USAGE_LIVE_ENABLED, usageKeyRefusal } from "../src/billing-usage-sync.ts"
import { INCLUDED_MODES, USAGE_PLANS, usageIncludedUsd, usageMeterEvent, usageModesOf, usagePriceLookupKey } from "../src/billing-catalog.ts"
import { fakeBoundaries, fakeStripe, nowS, sync } from "./setup/fake-stripe.ts"
import { stackTeamIdFor } from "../src/domains/user.ts"

// The usage sync's live switch (plans/cmux-next/usage-billing.md section 12): code, not configuration, off until the
// founders' go (plans/cmux-next/billing-go-live.md). A live run needs the bundle constant, the production Worker and
// a restricted key; it reads only live objects, keeps to the allowlist, and a dry run writes nothing.

const LIVE = "rk_live_0123456789abcdef"
const prod = (extra: Record<string, unknown> = {}) => ({ ...(env as object), ENVIRONMENT: "production", STRIPE_USAGE_KEY: LIVE, BILLING_USAGE_PRICE_SET: "v2", ...extra }) as any
/** The live v2 catalog as backend/scripts/stripe-usage-catalog.ts makes it: two meters aggregating `last`, one metered price per plan and mode. */
const liveCatalog = () => {
  const meters = INCLUDED_MODES.map((m) => ({ id: `mtr_${m}`, event_name: usageMeterEvent(m), default_aggregation: { formula: "last" } }))
  const prices = USAGE_PLANS.flatMap((plan) =>
    usageModesOf(plan).map((m) => {
      const lookup_key = usagePriceLookupKey(plan, "v2", m)
      const recurring = { interval: "month", usage_type: "metered", meter: `mtr_${m}` }
      return m === "per_seat"
        ? { id: `price_live_${lookup_key}`, lookup_key, recurring, billing_scheme: "per_unit", unit_amount_decimal: "100", tiers_mode: null }
        : { id: `price_live_${lookup_key}`, lookup_key, recurring, billing_scheme: "tiered", tiers_mode: "graduated", unit_amount_decimal: null, tiers: [{ up_to: usageIncludedUsd(plan, "v2"), unit_amount_decimal: "0" }, { up_to: null, unit_amount_decimal: "100" }] }
    }),
  )
  return { meters, prices }
}
/** The fake payment service answering as live mode: every object it returns says livemode, and it holds the live catalog. */
const liveStripe = (stripe: ReturnType<typeof fakeStripe>, catalog: { meters: any[]; prices: any[] } = liveCatalog()) => {
  const handle = stripe.handle
  stripe.handle = async (url, init) => {
    const method = (init.method ?? "GET").toUpperCase()
    const asked = url.searchParams.getAll("lookup_keys[]")
    const res =
      method === "GET" && url.pathname === "/v1/prices"
        ? Response.json({ data: catalog.prices.filter((p) => asked.includes(p.lookup_key)) })
        : method === "GET" && url.pathname === "/v1/billing/meters"
          ? Response.json({ data: catalog.meters })
          : await handle(url, init)
    const body = (await res.json()) as any
    const mark = (o: any) => (o && typeof o === "object" ? { ...o, livemode: true } : o)
    return Response.json(Array.isArray(body?.data) ? { ...body, data: body.data.map(mark) } : mark(body), { status: res.status })
  }
  return stripe
}
const writes = (stripe: ReturnType<typeof fakeStripe>) => stripe.calls.filter((c) => c.method === "POST")

afterEach(() => vi.restoreAllMocks())
const spendOn = (team: string, usd: number) =>
  ((env as any).USAGE_METER_DO.get((env as any).USAGE_METER_DO.idFromName(team)) as any).record(team, [{ key: `live-switch:${crypto.randomUUID()}`, meter: "model.spend_usd", quantity: usd, source: "coderouter", observed_at: Date.now() }])

describe("the usage sync's live switch", () => {
  it("ships off: the bundle constant is false, so every live key is refused before any call", async () => {
    expect(USAGE_LIVE_ENABLED).toBe(false)
    const stripe = fakeStripe({ start: 1, end: 2 })
    fakeBoundaries(stripe, 0)
    expect((await sync(prod())).body).toMatchObject({ mode: "live", refused: "live_key", checked: 0 })
    expect(stripe.calls).toHaveLength(0)
  })

  it("with the constant on, a live key runs only on production and only as a restricted key", () => {
    const at = (ENVIRONMENT: string, STRIPE_USAGE_KEY: string) => usageKeyRefusal({ ENVIRONMENT, STRIPE_USAGE_KEY }, true)
    expect(at("production", LIVE)).toBeNull()
    expect(at("production", "sk_live_0123456789abcdef")).toBe("live_full_key")
    expect(at("staging", LIVE)).toBe("live_key_off_production")
    expect(at("development", LIVE)).toBe("live_key_off_production")
    expect(at("production", "sk_test_0123456789abcdef")).toBeNull()
    expect(usageKeyRefusal({ ENVIRONMENT: "production", STRIPE_USAGE_KEY: LIVE }, false)).toBe("live_key")
    expect(usageKeyRefusal({ ENVIRONMENT: "production", STRIPE_USAGE_KEY: undefined }, true)).toBe("no_key")
  })

  it("a live run that reads a test-mode object refuses the whole run before any write", async () => {
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 })
    stripe.addSub("sub_lm1", "cus_lm1", { plan: "pro", stackUserId: "live-switch-mismatch" }, "cmux-pro-monthly-50")
    fakeBoundaries(stripe, 0)
    expect(await syncUsage(prod(), undefined, true)).toMatchObject({ mode: "live", refused: "livemode_mismatch", checked: 0 })
    expect(writes(stripe)).toHaveLength(0)
  })

  it("a test run that reads a live object refuses too", async () => {
    const stripe = liveStripe(fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 }))
    stripe.addSub("sub_lm2", "cus_lm2", { plan: "pro", stackUserId: "live-switch-mismatch-2" }, "cmux-pro-monthly-50")
    fakeBoundaries(stripe, 0)
    expect(await syncUsage({ ...(env as object), STRIPE_USAGE_KEY: "sk_test_0123456789abcdef" } as any)).toMatchObject({ refused: "livemode_mismatch" })
    expect(writes(stripe)).toHaveLength(0)
  })

  it("a live run keeps to BILLING_USAGE_LIVE_ALLOW", async () => {
    const stripe = liveStripe(fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 }))
    stripe.addSub("sub_staff1", "cus_staff1", { plan: "pro", stackUserId: "live-switch-staff" }, "cmux-pro-monthly-50")
    stripe.addSub("sub_other1", "cus_other1", { plan: "pro", stackUserId: "live-switch-other" }, "cmux-pro-monthly-50")
    fakeBoundaries(stripe, 0)
    const r = await syncUsage(prod({ BILLING_USAGE_LIVE_ALLOW: "sub_staff1" }), undefined, true)
    expect(r).toMatchObject({ mode: "live", checked: 2, items_added: 1, skipped: 1, failed: 0 })
    expect(writes(stripe).map((c) => c.form.subscription)).toEqual(["sub_staff1"])
    expect(liveAllowList(" sub_a, ,bad,sub_b ")).toEqual(new Set(["sub_a", "sub_b"]))
    expect(liveAllowList(undefined)).toBeNull()
    expect(liveAllowList("  ")).toBeNull()
  })

  it("a set allowlist with no well-formed id allows nothing (fails closed, #40319 F1)", async () => {
    expect(liveAllowList('"sub_staff2"')).toEqual(new Set())
    const stripe = liveStripe(fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 }))
    stripe.addSub("sub_staff2", "cus_staff2", { plan: "pro", stackUserId: "live-switch-staff-2" }, "cmux-pro-monthly-50")
    fakeBoundaries(stripe, 0)
    const r = await syncUsage(prod({ BILLING_USAGE_LIVE_ALLOW: '"sub_staff2"' }), undefined, true)
    expect(r).toMatchObject({ mode: "live", checked: 1, skipped: 1, items_added: 0, pushed: 0 })
    expect(writes(stripe)).toHaveLength(0)
  })

  it("a dry run sends what the real run then sends: the period's pinned included amount and seats (#40319 F2)", async () => {
    const uuid = "7c1d2e3f-4a5b-4c6d-8e7f-90a1b2c3d4e5"
    const team = stackTeamIdFor((env as any).STACK_PROJECT_ID, uuid)
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 })
    const sub = stripe.addSub("sub_pin1", "cus_pin1", { plan: "team", stackTeamId: uuid }, "cmux-team-monthly-25")
    sub.items.data[0].quantity = 3
    fakeBoundaries(stripe, 0)
    const test = { ...(env as object), STRIPE_USAGE_KEY: "sk_test_0123456789abcdef" }
    // Pushed under v2 (Team 25 per seat, per seat by default): the period pins 3 x 25 and the markup.
    await spendOn(team, 80)
    expect(await syncUsage({ ...test, ENVIRONMENT: "staging", BILLING_USAGE_PRICE_SET: "v2" } as any)).toMatchObject({ pushed: 1, failed: 0 })
    // The set moves to v1 (Team 20) mid-period; more usage. The dry run must preview what the real run then sends.
    await spendOn(team, 10)
    const v1 = { ...test, ENVIRONMENT: "staging" } as any
    const dry = await syncUsage(v1, { dryRun: true })
    expect(dry.would_send).toHaveLength(1)
    const before = stripe.events.length
    expect(await syncUsage(v1)).toMatchObject({ pushed: 1, failed: 0 })
    expect(stripe.events).toHaveLength(before + 1)
    expect(Number(stripe.events.at(-1)!["payload[value]"])).toBeCloseTo(dry.would_send![0]!.value_usd, 6)
  })

  it("a live run refuses a catalog that differs from the catalog code, before any write (#40319 F1)", async () => {
    const run = async (edit: (c: ReturnType<typeof liveCatalog>) => void, extra: Record<string, unknown> = {}) => {
      const catalog = liveCatalog()
      edit(catalog)
      const stripe = liveStripe(fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 }), catalog)
      stripe.addSub(`sub_cat${crypto.randomUUID().slice(0, 8)}`, "cus_cat1", { plan: "pro", stackUserId: "live-switch-catalog" }, "cmux-pro-monthly-50")
      fakeBoundaries(stripe, 0)
      const r = await syncUsage(prod(extra), undefined, true)
      expect(writes(stripe)).toHaveLength(0)
      return r
    }
    const pro = (c: ReturnType<typeof liveCatalog>) => c.prices.find((p) => p.lookup_key === usagePriceLookupKey("pro", "v2", "per_team"))!
    // A price that charges 100x, a pool that is too big, a summing meter, a meter that is gone, a missing price.
    expect(await run((c) => (pro(c).tiers[1].unit_amount_decimal = "10000"))).toMatchObject({ refused: "catalog_mismatch", checked: 0 })
    expect(await run((c) => (pro(c).tiers[0].up_to = 200))).toMatchObject({ refused: "catalog_mismatch" })
    expect(await run((c) => (c.meters[0]!.default_aggregation.formula = "sum"))).toMatchObject({ refused: "catalog_mismatch" })
    expect(await run((c) => c.meters.pop())).toMatchObject({ refused: "catalog_mismatch" })
    expect(await run((c) => c.prices.pop())).toMatchObject({ refused: "catalog_mismatch" })
    // Live bills v2 only.
    expect(await run(() => {}, { BILLING_USAGE_PRICE_SET: undefined })).toMatchObject({ refused: "catalog_mismatch" })
  })

  it("a one-subscription live run refuses when the customer's other subscriptions are in test mode (#40319 F2)", async () => {
    const stripe = liveStripe(fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 }))
    stripe.addSub("sub_one1", "cus_one1", { plan: "pro", stackUserId: "live-switch-one" }, "cmux-pro-monthly-50")
    const handle = stripe.handle
    // The customer listing answers a test-mode subscription; the subscription itself reads live.
    stripe.handle = async (url, init) => {
      const res = await handle(url, init)
      if (url.pathname !== "/v1/subscriptions" || !url.searchParams.get("customer")) return res
      const body = (await res.json()) as any
      return Response.json({ ...body, data: body.data.map((o: any) => ({ ...o, livemode: false })) })
    }
    fakeBoundaries(stripe, 0)
    expect(await syncUsage(prod(), { subscription: "sub_one1" }, true)).toMatchObject({ refused: "livemode_mismatch" })
    expect(writes(stripe)).toHaveLength(0)
  })

  it("a dry run reports what it would add and send, and writes nothing", async () => {
    const stripe = liveStripe(fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 }))
    stripe.addSub("sub_dry1", "cus_dry1", { plan: "pro", stackUserId: "live-switch-dry" }, "cmux-pro-monthly-50")
    fakeBoundaries(stripe, 0)
    const r = await syncUsage(prod(), { dryRun: true }, true)
    expect(r).toMatchObject({ mode: "live", dry_run: true, checked: 1, items_added: 1, failed: 0 })
    expect(writes(stripe)).toHaveLength(0)
    // The route takes dry_run, and refuses anything but a boolean.
    expect((await sync(prod(), JSON.stringify({ dry_run: "yes" }))).status).toBe(400)
  })
})
