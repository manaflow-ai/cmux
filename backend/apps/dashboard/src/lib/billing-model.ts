/** The GET /v1/billing/summary answer (backend/apps/api/src/billing-summary.ts). */
export interface BillingSummary {
  readonly team: string
  readonly personal: boolean
  readonly plan: { readonly id: string | null; readonly name: string; readonly paid: boolean; readonly unavailable?: boolean }
  readonly usage: {
    readonly included_usd: number | null
    /** -1 when the meter did not answer. */
    readonly spent_usd: number
    readonly period_start: number | null
    readonly period_end: number
    readonly billed: boolean
    readonly stopped: boolean
  } | null
  readonly credits: {
    readonly available_usd: number
    readonly balance_usd: number
    readonly held_usd: number
    readonly entries: ReadonlyArray<{ readonly kind: string; readonly usd: number; readonly at: number }>
    readonly topup_amounts_usd: ReadonlyArray<number>
    readonly topup_min_usd?: number
    readonly topup_max_usd?: number
  } | null
  readonly upgrade: ReadonlyArray<{ readonly id: string; readonly name: string; readonly usd: number; readonly checkout_url: string | null }>
  readonly manage_url: string
  readonly pricing_url: string
  readonly test_mode: boolean
}

export interface UsageMeter {
  readonly spentUsd: number
  readonly includedUsd: number
  /** 0...1, for the bar. */
  readonly fraction: number
  readonly over: boolean
  readonly unknown: boolean
}

export interface PlanOffer {
  readonly id: string
  readonly name: string
  readonly usd: number
  /** The test-mode checkout link, else the pricing page. */
  readonly href: string
  /** The first offer to a free person. */
  readonly recommended: boolean
}

export interface BillingModel {
  readonly status: "free" | "paid" | "unknown"
  readonly meter: UsageMeter | null
  readonly offers: ReadonlyArray<PlanOffer>
  readonly canTopUp: boolean
}

/** What the billing page shows for one summary. */
export const billingModel = (s: BillingSummary): BillingModel => {
  const status = s.plan.unavailable ? "unknown" : s.plan.paid ? "paid" : "free"
  const u = s.usage
  const meter: UsageMeter | null =
    status === "paid" && u && u.included_usd !== null
      ? (() => {
          const unknown = u.spent_usd < 0
          const included = u.included_usd
          const fraction = unknown ? 0 : included <= 0 ? (u.spent_usd > 0 ? 1 : 0) : Math.min(1, u.spent_usd / included)
          return { spentUsd: u.spent_usd, includedUsd: included, fraction, over: !unknown && u.spent_usd > included, unknown }
        })()
      : null
  const offers =
    status === "unknown"
      ? []
      : s.upgrade.map((p, i) => ({ id: p.id, name: p.name, usd: p.usd, href: p.checkout_url ?? s.pricing_url, recommended: status === "free" && i === 0 }))
  return { status, meter, offers, canTopUp: (s.credits?.topup_amounts_usd.length ?? 0) > 0 }
}

/** Why a typed amount cannot be a top-up: not a number, not whole cents, or outside the range; null when it can. */
export const topupError = (input: string, min: number, max: number): "number" | "cents" | "range" | null => {
  const t = input.trim()
  if (!/^\d+(\.\d+)?$/.test(t)) return "number"
  if (!/^\d+(\.\d{1,2})?$/.test(t)) return "cents"
  const v = Number(t)
  return v < min || v > max ? "range" : null
}

/** The auto-reload form as typed. */
export interface AutoReloadForm {
  readonly enabled: boolean
  readonly threshold: string
  readonly amount: string
  readonly cap: string
}

/** The first field of an enabled form that cannot be saved; null when it can (an off form saves as is). */
export const autoReloadError = (f: AutoReloadForm, min: number, max: number): "threshold" | "amount" | "cap" | null => {
  if (!f.enabled) return null
  const n = (v: string) => (/^\d+(\.\d{1,2})?$/.test(v.trim()) ? Number(v) : NaN)
  const threshold = n(f.threshold), amount = n(f.amount), cap = n(f.cap)
  if (!(threshold >= 0 && threshold <= max)) return "threshold"
  if (!(amount >= min && amount <= max)) return "amount"
  if (!(cap >= amount && cap <= max * 20)) return "cap"
  return null
}
