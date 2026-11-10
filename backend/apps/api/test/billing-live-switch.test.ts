import { env } from "cloudflare:workers"
import { afterEach, describe, expect, it, vi } from "vitest"
import { liveAllowList, syncUsage, USAGE_LIVE_ENABLED, usageKeyRefusal } from "../src/billing-usage-sync.ts"
import { fakeBoundaries, fakeStripe, nowS, sync } from "./setup/fake-stripe.ts"

// The usage sync's live switch (plans/cmux-next/usage-billing.md section 12): code, not configuration, off until the
// founders' go (plans/cmux-next/billing-go-live.md). A live run needs the bundle constant, the production Worker and
// a restricted key; it reads only live objects, keeps to the allowlist, and a dry run writes nothing.

const LIVE = "rk_live_0123456789abcdef"
const prod = (extra: Record<string, unknown> = {}) => ({ ...(env as object), ENVIRONMENT: "production", STRIPE_USAGE_KEY: LIVE, ...extra }) as any
/** The fake payment service answering as live mode: every object it returns says livemode. */
const liveStripe = (stripe: ReturnType<typeof fakeStripe>) => {
  const handle = stripe.handle
  stripe.handle = async (url, init) => {
    const res = await handle(url, init)
    const body = (await res.json()) as any
    const mark = (o: any) => (o && typeof o === "object" ? { ...o, livemode: true } : o)
    return Response.json(Array.isArray(body?.data) ? { ...body, data: body.data.map(mark) } : mark(body), { status: res.status })
  }
  return stripe
}
const writes = (stripe: ReturnType<typeof fakeStripe>) => stripe.calls.filter((c) => c.method === "POST")

afterEach(() => vi.restoreAllMocks())

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
