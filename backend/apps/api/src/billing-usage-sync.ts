import type { Env } from "./env.ts"
import { personalTeamIdFor, stackTeamIdFor, userIdFor } from "./domains/user.ts"
import { isUsagePlan, USAGE_METER_EVENT, USAGE_PLANS, USAGE_PRODUCT_ID, usagePriceLookupKey, type UsagePlan } from "./billing-catalog.ts"

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

type StripeItem = { id: string; price: { id: string; product: string | { id: string } }; current_period_start?: number; current_period_end?: number }
type StripeSubscription = { id: string; status: string; customer: string | { id: string }; metadata?: Record<string, string>; items: { data: StripeItem[] } }

const stripeFetch = async (key: string, method: "GET" | "POST", path: string, form?: Record<string, string>, idempotencyKey?: string): Promise<any> => {
  const headers: Record<string, string> = { authorization: `Bearer ${key}` }
  if (form) headers["content-type"] = "application/x-www-form-urlencoded"
  if (idempotencyKey) headers["idempotency-key"] = idempotencyKey
  const res = await fetch(`${STRIPE}${path}`, { method, headers, ...(form ? { body: new URLSearchParams(form).toString() } : {}) })
  const body = (await res.json().catch(() => ({}))) as any
  if (!res.ok) throw Object.assign(new Error(`stripe ${method} ${path.split("?")[0]} ${res.status} ${body?.error?.code ?? ""}`), { status: res.status, stripeMessage: String(body?.error?.message ?? "") })
  return body
}

const idOf = (v: string | { id: string }) => (typeof v === "string" ? v : v.id)

/** The team a cmux subscription bills, from its metadata (web checkout writes it). */
export const teamOfSubscription = (env: Env, sub: StripeSubscription): string | null => {
  const m = sub.metadata ?? {}
  // As stack-webhook.ts names a shared team (UUIDs lowercased) and auth.ts a person (the id as issued).
  if (m.plan === "team") return m.stackTeamId ? stackTeamIdFor(env.STACK_PROJECT_ID, UUID.test(m.stackTeamId) ? m.stackTeamId.toLowerCase() : m.stackTeamId) : null
  return m.stackUserId ? personalTeamIdFor(userIdFor(env.STACK_PROJECT_ID, m.stackUserId)) : null
}

export const syncUsage = async (env: Env, only?: { readonly subscription?: string }): Promise<SyncReport> => {
  const mode = stripeKeyMode(env.STRIPE_USAGE_KEY)
  const report: SyncReport = { mode, checked: 0, items_added: 0, items_moved: 0, pushed: 0, unchanged: 0, skipped: 0, failed: 0 }
  if (mode !== "test") {
    if (mode !== "none") console.error(JSON.stringify({ msg: "billing.usage_sync.refused", mode }))
    return { ...report, refused: mode === "none" ? "no_key" : mode === "live" ? "live_key" : "invalid_key" }
  }
  const key = env.STRIPE_USAGE_KEY!
  const priceList = await stripeFetch(key, "GET", `/v1/prices?active=true&limit=10&${USAGE_PLANS.map((p) => `lookup_keys[]=${encodeURIComponent(usagePriceLookupKey(p))}`).join("&")}`)
  const priceOf = new Map<UsagePlan, string>()
  for (const p of priceList.data as Array<{ id: string; lookup_key: string }>) for (const plan of USAGE_PLANS) if (p.lookup_key === usagePriceLookupKey(plan)) priceOf.set(plan, p.id)
  const usagePrices = new Set(priceOf.values())

  const subs: StripeSubscription[] = []
  if (only?.subscription) subs.push(await stripeFetch(key, "GET", `/v1/subscriptions/${encodeURIComponent(only.subscription)}`))
  else {
    let after: string | undefined
    for (let page = 0; page < MAX_PAGES; page++) {
      const list = await stripeFetch(key, "GET", `/v1/subscriptions?status=all&limit=100${after ? `&starting_after=${after}` : ""}`)
      subs.push(...(list.data as StripeSubscription[]))
      if (!list.has_more || list.data.length === 0) break
      after = list.data.at(-1).id
    }
  }

  for (const sub of subs) {
    const plan = sub.metadata?.plan
    if (sub.metadata?.app !== "cmux" || !ACTIVE.has(sub.status) || !isUsagePlan(plan)) continue
    report.checked++
    const team = teamOfSubscription(env, sub)
    const want = priceOf.get(plan)
    if (!team || !want) {
      report.skipped++
      continue
    }
    try {
      // The usage item only: an item on a usage price or the usage product. The plan item is never touched.
      let item = sub.items.data.find((i) => usagePrices.has(i.price.id) || idOf(i.price.product) === USAGE_PRODUCT_ID)
      if (!item) {
        item = (await stripeFetch(key, "POST", "/v1/subscription_items", { subscription: sub.id, price: want, proration_behavior: "none" }, `usage-item:${sub.id}:${want}`)) as StripeItem
        report.items_added++
      } else if (item.price.id !== want) {
        item = (await stripeFetch(key, "POST", `/v1/subscription_items/${item.id}`, { price: want, proration_behavior: "none" }, `usage-item-move:${sub.id}:${item.id}:${want}`)) as StripeItem
        report.items_moved++
      }
      const start = item.current_period_start ?? sub.items.data[0]?.current_period_start
      const end = item.current_period_end ?? sub.items.data[0]?.current_period_end
      if (!start || !end) {
        report.skipped++
        continue
      }
      const meter = env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(team))
      const level = await meter.level(team, start * 1000, end * 1000)
      const identifier = `ai:${sub.id}:${start}:${level.micros}:${level.facts}:${level.last_at ?? 0}`
      const sent = await meter.pushedLevel(team, sub.id, start)
      if (sent === identifier || (sent === null && level.facts === 0)) {
        report.unchanged++
        continue
      }
      const timestamp = Math.min(Math.floor(Date.now() / 1000), end - 1)
      try {
        await stripeFetch(key, "POST", "/v1/billing/meter_events", { event_name: USAGE_METER_EVENT, "payload[stripe_customer_id]": idOf(sub.customer), "payload[value]": (level.micros / 1_000_000).toFixed(6), identifier, timestamp: String(timestamp) }, identifier)
      } catch (e) {
        // The same identifier was already accepted (a run that died before it recorded the push).
        if (!((e as { status?: number }).status === 400 && /identifier/i.test((e as { stripeMessage?: string }).stripeMessage ?? ""))) throw e
      }
      await meter.recordPush(team, sub.id, start, identifier, level.micros)
      report.pushed++
    } catch (e) {
      report.failed++
      console.error(JSON.stringify({ msg: "billing.usage_sync.failed", subscription: sub.id, error: String(e).slice(0, 200) }))
    }
  }
  console.log(JSON.stringify({ msg: "billing.usage_sync", ...report }))
  return report
}
