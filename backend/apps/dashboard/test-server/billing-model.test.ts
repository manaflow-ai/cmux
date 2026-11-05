/**
 * The billing page's model (src/lib/billing-model.ts, paid-plans-DESIGN.md §3): what the page shows
 * for a GET /v1/billing/summary answer. Pure, so it runs without the built server.
 */
import { expect, test } from "bun:test"
import { billingModel, type BillingSummary } from "../src/lib/billing-model"

const base: BillingSummary = {
  team: "team_0123456789abcdef0123",
  personal: true,
  plan: { id: null, name: "Free", paid: false },
  usage: null,
  credits: { available_usd: 0, balance_usd: 0, held_usd: 0, entries: [], topup_amounts_usd: [10, 20, 50, 100] },
  upgrade: [
    { id: "pro", name: "cmux Pro", usd: 50, checkout_url: "https://api.test/v1/billing/plan/x.y" },
    { id: "max", name: "cmux Max", usd: 200, checkout_url: "https://api.test/v1/billing/plan/a.b" }
  ],
  manage_url: "https://cmux.com/dashboard/billing",
  pricing_url: "https://cmux.com/pricing",
  test_mode: true
}

test("a free person sees an upgrade offer first, with Pro recommended", () => {
  const m = billingModel(base)
  expect(m.status).toBe("free")
  expect(m.offers.map((o) => o.id)).toEqual(["pro", "max"])
  expect(m.offers[0]!.recommended).toBe(true)
  expect(m.offers[0]!.href).toBe("https://api.test/v1/billing/plan/x.y")
  expect(m.meter).toBeNull()
  expect(m.canTopUp).toBe(true)
})

test("an offer without a checkout link goes to the pricing page", () => {
  const m = billingModel({ ...base, upgrade: [{ ...base.upgrade[0]!, checkout_url: null }], test_mode: false })
  expect(m.offers[0]!.href).toBe("https://cmux.com/pricing")
  expect(m.canTopUp).toBe(true)
})

test("a paid person sees a usage meter against the included amount", () => {
  const m = billingModel({
    ...base,
    plan: { id: "pro", name: "cmux Pro", paid: true },
    usage: { included_usd: 20, spent_usd: 5, period_start: 0, period_end: 1, billed: false, stopped: false },
    upgrade: [base.upgrade[1]!]
  })
  expect(m.status).toBe("paid")
  expect(m.meter).toEqual({ spentUsd: 5, includedUsd: 20, fraction: 0.25, over: false, unknown: false })
  expect(m.offers.map((o) => o.id)).toEqual(["max"])
  expect(m.offers[0]!.recommended).toBe(false)
})

test("usage above the included amount caps the bar and says it is over", () => {
  const m = billingModel({ ...base, plan: { id: "pro", name: "cmux Pro", paid: true }, usage: { included_usd: 20, spent_usd: 30, period_start: 0, period_end: 1, billed: true, stopped: false } })
  expect(m.meter).toMatchObject({ fraction: 1, over: true })
})

test("a meter that did not answer (-1) shows as unknown, never as zero", () => {
  const m = billingModel({ ...base, plan: { id: "pro", name: "cmux Pro", paid: true }, usage: { included_usd: 20, spent_usd: -1, period_start: 0, period_end: 1, billed: false, stopped: false } })
  expect(m.meter).toMatchObject({ unknown: true, fraction: 0 })
})

test("a plan service outage is its own state, not Free", () => {
  const m = billingModel({ ...base, plan: { id: null, name: "Free", paid: false, unavailable: true } })
  expect(m.status).toBe("unknown")
  expect(m.offers).toEqual([])
})

test("no top-up amounts: no top-up button", () => {
  const m = billingModel({ ...base, credits: { ...base.credits!, topup_amounts_usd: [] } })
  expect(m.canTopUp).toBe(false)
})

import { autoReloadError, topupError } from "../src/lib/billing-model"

test("a custom top-up amount must be whole cents inside the range", () => {
  expect(topupError("37.50", 5, 2500)).toBeNull()
  expect(topupError("5", 5, 2500)).toBeNull()
  expect(topupError("4.99", 5, 2500)).toBe("range")
  expect(topupError("2500.01", 5, 2500)).toBe("range")
  expect(topupError("10.001", 5, 2500)).toBe("cents")
  expect(topupError("abc", 5, 2500)).toBe("number")
  expect(topupError("", 5, 2500)).toBe("number")
})

test("auto-reload settings: a reload amount in range, a threshold of 0 or more, a cap of at least one reload", () => {
  const ok = { enabled: true, threshold: "10", amount: "20", cap: "100" }
  expect(autoReloadError(ok, 5, 2500)).toBeNull()
  expect(autoReloadError({ ...ok, amount: "2" }, 5, 2500)).toBe("amount")
  expect(autoReloadError({ ...ok, threshold: "-1" }, 5, 2500)).toBe("threshold")
  expect(autoReloadError({ ...ok, cap: "10" }, 5, 2500)).toBe("cap")
  expect(autoReloadError({ ...ok, enabled: false, amount: "2" }, 5, 2500)).toBeNull()
})
