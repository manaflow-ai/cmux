import type { Env } from "./env.ts"
import { personalTeamIdFor, stackTeamIdFor, userIdFor } from "./domains/user.ts"
import { INCLUDED_MODES, isIncludedMode, isUsagePlan, USAGE_PLANS, USAGE_PRICE_SET_NAMES, USAGE_PRODUCT_ID, USAGE_TEAM_MODE_PLANS, usageIncludedUsd, usageModesOf, usageMeterEvent, usageMeterValueMicros, usagePriceLookupKey, type IncludedMode, type UsagePlan, type UsagePriceSet } from "./billing-catalog.ts"

/**
 * The usage sync (cx-y79zh S4, plans/cmux-next/usage-billing.md section 3, placement option a): the
 * reconcile worker in the API Worker. Product code only records facts (UsageMeterDO); this run reads
 * each billed team's period level and sends it to the payment service. It never runs inside a
 * request's money path.
 *
 * One run, for every active cmux subscription (metadata app=cmux, a usage plan):
 * 1. The team: metadata stackTeamId (a shared team) or stackUserId (a personal team), mapped to the
 *    team id as the sign-in path does (domains/user.ts).
 * 2. The usage item: the subscription item whose price is the plan's metered usage price. A missing
 *    one is added, a usage item on another plan's usage price is moved to this plan's price, each with
 *    an idempotency key per subscription. The plan item is never changed.
 * 3. The level: UsageMeterDO.level for the usage item's current period, sent as a meter event (the
 *    meter aggregates `last`, so a repeat cannot double bill). The identifier names the level's state
 *    (period, micros, fact count, last fact time, and per seat the seats): the same state is the same
 *    event; any new fact, correction or seat change is a new event. Unchanged levels are not sent again.
 * 4. The included mode (billing-catalog.ts): per team, the whole level goes to the graduated price's
 *    meter; per seat, the level above included x seats goes to the flat price's meter. A Team
 *    customer's mode is the operator's setting in force at the period start; the usage item moves to
 *    the other mode's price only at the first run of a new period. Seats are the
 *    plan item's quantity, the most seen at any run in the period (a seat removed late in the period
 *    does not take its included amount back), and a closed period's final push reuses them.
 *
 * Keys: STRIPE_USAGE_KEY. This phase is test mode only: a live key is refused before any call, in
 * every environment (live objects and live subscriptions are Lawrence's step).
 */
const STRIPE = "https://api.stripe.com"
/** Stripe API version, pinned (the web billing code uses the same one): items carry current_period_*. */
export const STRIPE_API_VERSION = "2026-06-24.dahlia"

const ACTIVE = new Set(["active", "trialing", "past_due"])
const MAX_PAGES = 50
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export type KeyMode = "test" | "live" | "none" | "invalid"
export const stripeKeyMode = (key: string | undefined): KeyMode => {
  if (!key) return "none"
  if (/^(sk|rk)_test_/.test(key)) return "test"
  if (/^(sk|rk)_live_/.test(key)) return "live"
  return "invalid"
}

export interface SyncReport {
  readonly mode: KeyMode
  readonly refused?: string
  checked: number
  items_added: number
  items_moved: number
  pushed: number
  unchanged: number
  skipped: number
  failed: number
}

type StripeItem = { id: string; quantity?: number; price: { id: string; product: string | { id: string }; lookup_key?: string | null; recurring?: { interval?: string } | null }; current_period_start?: number; current_period_end?: number }
type StripeSubscription = { id: string; status: string; customer: string | { id: string }; metadata?: Record<string, string>; items: { data: StripeItem[] } }

export const stripeFetch = async (key: string, method: "GET" | "POST", path: string, form?: Record<string, string>, idempotencyKey?: string): Promise<any> => {
  const headers: Record<string, string> = { authorization: `Bearer ${key}`, "stripe-version": STRIPE_API_VERSION }
  if (form) headers["content-type"] = "application/x-www-form-urlencoded"
  if (idempotencyKey) headers["idempotency-key"] = idempotencyKey
  const res = await fetch(`${STRIPE}${path}`, { method, headers, ...(form ? { body: new URLSearchParams(form).toString() } : {}) })
  const body = (await res.json().catch(() => ({}))) as any
  if (!res.ok) throw Object.assign(new Error(`stripe ${method} ${path.split("?")[0]} ${res.status} ${body?.error?.code ?? ""}`), { status: res.status, stripeMessage: String(body?.error?.message ?? "") })
  return body
}

const idOf = (v: string | { id: string }) => (typeof v === "string" ? v : v.id)

/** The team a cmux subscription bills, from its metadata (web checkout writes it). */
export const teamOfSubscription = (env: Env, sub: StripeSubscription, plan: UsagePlan): string | null => {
  const m = sub.metadata ?? {}
  // As stack-webhook.ts names a shared team (UUIDs lowercased) and auth.ts a person (the id as issued).
  if (plan === "team") return m.stackTeamId ? stackTeamIdFor(env.STACK_PROJECT_ID, UUID.test(m.stackTeamId) ? m.stackTeamId.toLowerCase() : m.stackTeamId) : null
  if (m.stackTeamId) return null
  return m.stackUserId ? personalTeamIdFor(userIdFor(env.STACK_PROJECT_ID, m.stackUserId)) : null
}

/** The plan of a cmux subscription from its plan item's lookup key, as web reads it (subscriptionPlan.ts); metadata only without one. */
export const planOfSubscription = (sub: StripeSubscription, planItem: StripeItem | undefined): UsagePlan | null => {
  const lookup = planItem?.price.lookup_key
  if (typeof lookup === "string" && lookup.trim()) {
    if (lookup.startsWith("cmux-go-")) return "go"
    if (lookup.startsWith("cmux-max-")) return "max"
    if (lookup.startsWith("cmux-pro-")) return "pro"
    if (lookup.startsWith("cmux-team-")) return "team"
    return null
  }
  const meta = sub.metadata?.plan
  return isUsagePlan(meta) ? meta : null
}

const listActive = async (key: string): Promise<{ subs: StripeSubscription[]; truncated: boolean }> => {
  const subs: StripeSubscription[] = []
  let truncated = false
  for (const status of ACTIVE) {
    let after: string | undefined
    let page = 0
    for (; page < MAX_PAGES; page++) {
      const list = await stripeFetch(key, "GET", `/v1/subscriptions?status=${status}&limit=100${after ? `&starting_after=${after}` : ""}`)
      subs.push(...(list.data as StripeSubscription[]))
      if (!list.has_more || list.data.length === 0) break
      after = list.data.at(-1).id
    }
    if (page === MAX_PAGES) truncated = true
  }
  return { subs, truncated }
}

/** The price set in force: `e2e` only on the development Worker that asks for it; every other environment gets v1. */
export const usagePriceSet = (env: Env): UsagePriceSet => (env.ENVIRONMENT === "development" && env.BILLING_USAGE_PRICE_SET === "e2e" ? "e2e" : "v1")

export const syncUsage = async (env: Env, only?: { readonly subscription?: string }): Promise<SyncReport> => {
  const mode = stripeKeyMode(env.STRIPE_USAGE_KEY)
  const report: SyncReport = { mode, checked: 0, items_added: 0, items_moved: 0, pushed: 0, unchanged: 0, skipped: 0, failed: 0 }
  if (mode !== "test") {
    if (mode !== "none") console.error(JSON.stringify({ msg: "billing.usage_sync.refused", mode }))
    return { ...report, refused: mode === "none" ? "no_key" : mode === "live" ? "live_key" : "invalid_key" }
  }
  const key = env.STRIPE_USAGE_KEY!
  const set = usagePriceSet(env)
  // Every usage price of every set and mode is a usage item (never a plan item); the set in force picks the target.
  const asked = [...new Set(USAGE_PRICE_SET_NAMES.flatMap((s) => USAGE_PLANS.flatMap((p) => INCLUDED_MODES.map((m) => usagePriceLookupKey(p, s, m)))))]
  const askedSet = new Set(asked)
  /** The usage price in force per plan and mode (`<plan>:<mode>`). */
  const priceOf = new Map<string, string>()
  const usagePrices = new Set<string>()
  // At most 10 lookup keys per request (Stripe).
  for (let i = 0; i < asked.length; i += 10) {
    const priceList = await stripeFetch(key, "GET", `/v1/prices?active=true&limit=20&${asked.slice(i, i + 10).map((k) => `lookup_keys[]=${encodeURIComponent(k)}`).join("&")}`)
    for (const p of priceList.data as Array<{ id: string; lookup_key: string }>) {
      if (!askedSet.has(p.lookup_key)) continue
      usagePrices.add(p.id)
      for (const plan of USAGE_PLANS) for (const m of usageModesOf(plan)) if (p.lookup_key === usagePriceLookupKey(plan, set, m)) priceOf.set(`${plan}:${m}`, p.id)
    }
  }
  const isUsageItem = (i: StripeItem) => usagePrices.has(i.price.id) || idOf(i.price.product) === USAGE_PRODUCT_ID

  const listed = only?.subscription ? { subs: [(await stripeFetch(key, "GET", `/v1/subscriptions/${encodeURIComponent(only.subscription)}`)) as StripeSubscription], truncated: false } : await listActive(key)
  if (listed.truncated) console.error(JSON.stringify({ msg: "billing.usage_sync.truncated", pages: MAX_PAGES }))
  const isCmux = (sub: StripeSubscription) => sub.metadata?.app === "cmux" && ACTIVE.has(sub.status)
  const cmux = listed.subs.filter(isCmux)
  // One usage subscription per customer: meter events are per customer, so two would bill one total twice (review P2).
  // One subscription's run counts its customer's other subscriptions too (review P2, the invoice-created path).
  const counted = only?.subscription && cmux[0] ? (await Promise.all([...ACTIVE].map(async (status) => (await stripeFetch(key, "GET", `/v1/subscriptions?customer=${encodeURIComponent(idOf(cmux[0]!.customer))}&status=${status}&limit=100`)).data as StripeSubscription[]))).flat().filter(isCmux) : cmux
  const perCustomer = new Map<string, number>()
  for (const sub of counted) perCustomer.set(idOf(sub.customer), (perCustomer.get(idOf(sub.customer)) ?? 0) + 1)

  /**
   * Sends the level of [start, end) for this subscription when it changed, in the period's mode: per team the
   * whole level, per seat the level above included x seats (`seats` = the most the period has seen).
   */
  const pushLevel = async (team: string, sub: StripeSubscription, start: number, end: number, mode: IncludedMode, includedUsd: number, seatsNow: number) => {
    const meter = env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(team))
    const level = await meter.level(team, start * 1000, end * 1000)
    const sent = await meter.pushState(team, sub.id, start)
    const seats = mode === "per_seat" ? Math.max(seatsNow, sent?.mode === "per_seat" ? sent.seats : 1) : 1
    // per_team keeps the S4 identifier form, so a deploy does not resend every unchanged level.
    const identifier = mode === "per_seat" ? `ais:${sub.id}:${start}:${level.micros}:${level.facts}:${level.last_at ?? 0}:${seats}` : `ai:${sub.id}:${start}:${level.micros}:${level.facts}:${level.last_at ?? 0}`
    if (sent?.identifier === identifier || (sent === null && level.facts === 0)) return false
    const value = usageMeterValueMicros(mode, level.micros, includedUsd, seats)
    // Deterministic (cx-y79zh.1 e2e finding): the identifier is also the idempotency key, so a retry of the same
    // level must be the same request. The event is dated at the level's last fact, after the period's previous
    // event (a seat-only change is then still the latest, for the meter's `last`), and inside the period.
    const timestamp = Math.min(end - 1, Math.max(start, Math.floor((level.last_at ?? start * 1000) / 1000), sent?.event_ts != null ? sent.event_ts + 1 : start))
    try {
      await stripeFetch(key, "POST", "/v1/billing/meter_events", { event_name: usageMeterEvent(mode), "payload[stripe_customer_id]": idOf(sub.customer), "payload[value]": (value / 1_000_000).toFixed(6), identifier, timestamp: String(timestamp) }, identifier)
    } catch (e) {
      // The same identifier was already accepted (a run that died before it recorded the push).
      const err = e as { status?: number; stripeMessage?: string }
      if (!(err.status === 400 && /identifier/i.test(err.stripeMessage ?? "") && /(already|duplicate|exists)/i.test(err.stripeMessage ?? ""))) throw e
    }
    await meter.recordPush(team, sub.id, start, end, identifier, level.micros, { mode, seats, included_usd: includedUsd, sent_micros: value, event_ts: timestamp })
    return true
  }

  for (const sub of cmux) {
    const planItem = sub.items.data.find((i) => !isUsageItem(i))
    const plan = planOfSubscription(sub, planItem)
    report.checked++
    if (!plan) {
      report.skipped++
      console.warn(JSON.stringify({ msg: "billing.usage_sync.skipped", subscription: sub.id, why: "unknown_plan" }))
      continue
    }
    const team = teamOfSubscription(env, sub, plan)
    const skip = (why: string) => {
      report.skipped++
      console.warn(JSON.stringify({ msg: "billing.usage_sync.skipped", subscription: sub.id, why }))
    }
    const why = !team ? "no_team" : !planItem ? "no_plan_item" : planItem.price.recurring?.interval !== "month" ? "not_monthly" : (perCustomer.get(idOf(sub.customer)) ?? 0) > 1 ? "customer_has_several" : null
    if (why) {
      skip(why)
      continue
    }
    try {
      const meter = env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(team!))
      // The period's mode: a Team customer's operator setting in force at the period start (a change applies from
      // the next period; a period already pushed keeps its mode); every other plan is per team.
      const periodStart = planItem!.current_period_start
      const mode: IncludedMode = USAGE_TEAM_MODE_PLANS.has(plan) && periodStart ? await meter.periodMode(team!, sub.id, periodStart) : "per_team"
      const want = priceOf.get(`${plan}:${mode}`)
      if (!want) {
        skip("no_usage_price")
        continue
      }
      const includedUsd = usageIncludedUsd(plan, set)
      // Period close first (review P2, and before any item move, cx-y79zh.1 review): after a renewal, the closed
      // period gets its final level once more, dated inside it, in its own mode, seats and meter, while its
      // invoice is still a draft (Stripe waits about an hour).
      const prev = periodStart ? await meter.previousPush(team!, sub.id, periodStart) : null
      if (prev) {
        const prevMode = isIncludedMode(prev.mode) ? prev.mode : "per_team"
        if (await pushLevel(team!, sub, prev.period_start, prev.period_end, prevMode, prev.included_usd ?? includedUsd, prev.seats)) report.pushed++
      }
      // The usage item only: an item on a usage price or the usage product. The plan item is never written.
      let item = sub.items.data.find(isUsageItem)
      if (!item) {
        item = (await stripeFetch(key, "POST", "/v1/subscription_items", { subscription: sub.id, price: want!, proration_behavior: "none" }, `usage-item:${sub.id}:${want}`)) as StripeItem
        report.items_added++
      } else if (item.price.id !== want) {
        item = (await stripeFetch(key, "POST", `/v1/subscription_items/${item.id}`, { price: want!, proration_behavior: "none" }, `usage-item-move:${sub.id}:${item.id}:${want}:${periodStart ?? 0}`)) as StripeItem
        report.items_moved++
      }
      const start = item.current_period_start ?? periodStart
      const end = item.current_period_end ?? planItem!.current_period_end
      if (!start || !end) {
        report.skipped++
        continue
      }
      // The period's seats: the plan item's quantity, or more when the period already saw more (the bill and the console agree, review P3).
      const quantity = Math.max(1, Math.floor(Number(planItem!.quantity ?? 1)) || 1)
      const seen = mode === "per_seat" ? await meter.pushState(team!, sub.id, start) : null
      const seats = seen?.mode === "per_seat" ? Math.max(quantity, seen.seats) : quantity
      // The team can be billed above its included amount until this period ends (inference/included-stop.ts);
      // the mark also names the period's included amount for the console (team.ai_limit.get).
      await meter.markBillable(team!, sub.id, end, { period_start: start, mode, seats, included_usd: includedUsd })
      if (await pushLevel(team!, sub, start, end, mode, includedUsd, seats)) report.pushed++
      else report.unchanged++
    } catch (e) {
      report.failed++
      console.error(JSON.stringify({ msg: "billing.usage_sync.failed", subscription: sub.id, error: String(e).slice(0, 200) }))
    }
  }
  console.log(JSON.stringify({ msg: "billing.usage_sync", ...report }))
  return report
}
