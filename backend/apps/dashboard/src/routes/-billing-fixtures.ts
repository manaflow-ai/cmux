import type { BillingSummary } from "../lib/billing-model"

const DAY = 86_400_000
const NOW = Date.UTC(2026, 9, 27)

const free: BillingSummary = {
  team: "team_0123456789abcdef0123",
  personal: true,
  plan: { id: null, name: "Free", paid: false },
  usage: null,
  credits: { available_usd: 0, balance_usd: 0, held_usd: 0, entries: [], topup_amounts_usd: [10, 20, 50, 100], topup_min_usd: 5, topup_max_usd: 2500 },
  upgrade: [
    { id: "pro", name: "cmux Pro", usd: 50, checkout_url: "#checkout-pro" },
    { id: "max", name: "cmux Max", usd: 200, checkout_url: "#checkout-max" }
  ],
  manage_url: "https://cmux.com/dashboard/billing",
  pricing_url: "https://cmux.com/pricing",
  test_mode: true
}

/** Sample answers of GET /v1/billing/summary for the gallery (/preview/billing). */
export const BILLING_STATES: Record<string, { note: string; data: BillingSummary }> = {
  free: { note: "Free plan, no credits: upgrade first", data: free },
  pro: {
    note: "cmux Pro, a quarter of the included amount used, credits topped up",
    data: {
      ...free,
      plan: { id: "pro", name: "cmux Pro", paid: true },
      usage: { included_usd: 20, spent_usd: 5.12, period_start: NOW - 26 * DAY, period_end: NOW + 5 * DAY, billed: true, stopped: false },
      credits: { ...free.credits!, available_usd: 18.4, balance_usd: 19.99, held_usd: 1.59, entries: [{ kind: "charge", usd: -0.01, at: NOW - DAY }, { kind: "topup", usd: 10, at: NOW - 3 * DAY }, { kind: "topup", usd: 10, at: NOW - 4 * DAY }] },
      upgrade: [free.upgrade[1]!]
    }
  },
  over: {
    note: "cmux Pro above its included amount (billed at cost)",
    data: { ...free, plan: { id: "pro", name: "cmux Pro", paid: true }, usage: { included_usd: 20, spent_usd: 27.3, period_start: NOW - 26 * DAY, period_end: NOW + 5 * DAY, billed: true, stopped: false }, upgrade: [free.upgrade[1]!] }
  },
  unknown: { note: "The plan service did not answer", data: { ...free, plan: { id: null, name: "Free", paid: false, unavailable: true } } }
}
export const BILLING_STATE_NAMES = Object.keys(BILLING_STATES)

/** The auto-reload panel's sample (on, one reload this month). */
export const AUTO_RELOAD_SAMPLE = { enabled: true, threshold_usd: 10, amount_usd: 20, monthly_cap_usd: 100, month_reloaded_usd: 20, last_error: null }
