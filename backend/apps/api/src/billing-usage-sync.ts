import type { Env } from "./env.ts"
import { personalTeamIdFor, stackTeamIdFor, userIdFor } from "./domains/user.ts"
import { isUsagePlan, USAGE_METER_EVENT, USAGE_PLANS, USAGE_PRODUCT_ID, usagePriceLookupKey, type UsagePlan, type UsagePriceSet } from "./billing-catalog.ts"

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
 *    (period, micros, fact count, last fact time): the same state is the same event; any new fact or
 *    correction is a new event. Unchanged levels are not sent again.
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

type StripeItem = { id: string; price: { id: string; product: string | { id: string }; lookup_key?: string | null; recurring?: { interval?: string } | null }; current_period_start?: number; current_period_end?: number }
type StripeSubscription = { id: string; status: string; customer: string | { id: string }; metadata?: Record<string, string>; items: { data: StripeItem[] } }

const stripeFetch = async (key: string, method: "GET" | "POST", path: string, form?: Record<string, string>, idempotencyKey?: string): Promise<any> => {
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
  // Every usage price of every set is a usage item (never a plan item); the set in force picks the target.
  const allSets: UsagePriceSet[] = ["v1", "e2e"]
  const priceList = await stripeFetch(key, "GET", `/v1/prices?active=true&limit=20&${allSets.flatMap((s) => USAGE_PLANS.map((p) => `lookup_keys[]=${encodeURIComponent(usagePriceLookupKey(p, s))}`)).join("&")}`)
  const priceOf = new Map<UsagePlan, string>()
  const usagePrices = new Set<string>()
  for (const p of priceList.data as Array<{ id: string; lookup_key: string }>) {
    usagePrices.add(p.id)
    for (const plan of USAGE_PLANS) if (p.lookup_key === usagePriceLookupKey(plan, set)) priceOf.set(plan, p.id)
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

  /** Sends the level of [start, end) for this subscription when it changed; `final` = a closed period's last push. */
  const pushLevel = async (team: string, sub: StripeSubscription, start: number, end: number) => {
    const meter = env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(team))
    const level = await meter.level(team, start * 1000, end * 1000)
    const identifier = `ai:${sub.id}:${start}:${level.micros}:${level.facts}:${level.last_at ?? 0}`
    const sent = await meter.pushedLevel(team, sub.id, start)
    if (sent === identifier || (sent === null && level.facts === 0)) return false
    const timestamp = Math.min(Math.floor(Date.now() / 1000), end - 1)
    try {
      await stripeFetch(key, "POST", "/v1/billing/meter_events", { event_name: USAGE_METER_EVENT, "payload[stripe_customer_id]": idOf(sub.customer), "payload[value]": (level.micros / 1_000_000).toFixed(6), identifier, timestamp: String(timestamp) }, identifier)
    } catch (e) {
      // The same identifier was already accepted (a run that died before it recorded the push).
      const err = e as { status?: number; stripeMessage?: string }
      if (!(err.status === 400 && /identifier/i.test(err.stripeMessage ?? "") && /(already|duplicate|exists)/i.test(err.stripeMessage ?? ""))) throw e
    }
    await meter.recordPush(team, sub.id, start, end, identifier, level.micros)
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
    const want = priceOf.get(plan)
    const why = !team ? "no_team" : !want ? "no_usage_price" : !planItem ? "no_plan_item" : planItem.price.recurring?.interval !== "month" ? "not_monthly" : (perCustomer.get(idOf(sub.customer)) ?? 0) > 1 ? "customer_has_several" : null
    if (why) {
      report.skipped++
      console.warn(JSON.stringify({ msg: "billing.usage_sync.skipped", subscription: sub.id, why }))
      continue
    }
    try {
      // The usage item only: an item on a usage price or the usage product. The plan item is never written.
      let item = sub.items.data.find(isUsageItem)
      const periodStart = planItem!.current_period_start
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
      const meter = env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(team!))
      // Period close (review P2): after a renewal, the closed period gets its final level once more,
      // dated inside it, while its invoice is still a draft (Stripe waits about an hour).
      const prev = await meter.previousPush(team!, sub.id, start)
      if (prev && (await pushLevel(team!, sub, prev.period_start, prev.period_end))) report.pushed++
      if (await pushLevel(team!, sub, start, end)) report.pushed++
      else report.unchanged++
    } catch (e) {
      report.failed++
      console.error(JSON.stringify({ msg: "billing.usage_sync.failed", subscription: sub.id, error: String(e).slice(0, 200) }))
    }
  }
  console.log(JSON.stringify({ msg: "billing.usage_sync", ...report }))
  return report
}
