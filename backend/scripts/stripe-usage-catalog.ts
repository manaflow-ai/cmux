#!/usr/bin/env bun
/**
 * Test-mode Stripe catalog for usage billing (cx-y79zh S3, plans/cmux-next/usage-billing.md).
 * Idempotent: finds each object first and creates only what is missing.
 *
 *   STRIPE_USAGE_KEY=<sk_test_...> bun backend/scripts/stripe-usage-catalog.ts [--check]
 *
 * - Meters, aggregation `last` (the reconcile worker sends levels, never deltas):
 *   `cmux_ai_usage` (the period's whole AI usage level, per-team prices) and
 *   `cmux_ai_usage_above_included` (the level above included x seats, per-seat prices).
 * - Product `cmux_ai_usage` ("cmux AI usage") and one metered price per plan in the plan's included
 *   mode it can bill in (billing-catalog.ts usageModesOf: Team both, the others per team):
 *   per team: graduated, lookup key `cmux-ai-usage-<plan>-incl<N>-<set>`, the first N units at 0,
 *   then 1.00 USD per unit; per seat: flat 1.00 USD per unit, lookup key
 *   `cmux-ai-usage-<plan>-seat<N>-<set>` (the sync subtracts N x seats). One unit = one USD of AI
 *   usage at our cost (pass-through, Lawrence 2026-10-13).
 *
 * Refuses any live key: live objects are Lawrence's step. Prints object ids and settings only.
 */
import { INCLUDED_MODES, USAGE_PRICE_SETS, USAGE_PRODUCT_ID as PRODUCT_ID, usageMeterEvent, usageModesOf, usagePriceLookupKey, type IncludedMode, type UsagePriceSet } from "../apps/api/src/billing-catalog.ts"
// --set e2e: the end-to-end price set (1 USD included), test mode only like everything here.
const SET: UsagePriceSet = process.argv.includes("--set=e2e") ? "e2e" : "v1"
const INCLUDED_USD = USAGE_PRICE_SETS[SET]
const key = process.env.STRIPE_USAGE_KEY ?? ""
const check = process.argv.includes("--check")
if (!/^(sk|rk)_test_/.test(key)) {
  console.error("stripe-usage-catalog: STRIPE_USAGE_KEY must be a test-mode key (sk_test_ or rk_test_); live objects are not made here")
  process.exit(2)
}


const api = async (method: "GET" | "POST", path: string, form?: Record<string, string>, idempotency?: string): Promise<any> => {
  const headers: Record<string, string> = { authorization: `Bearer ${key}` }
  if (form) headers["content-type"] = "application/x-www-form-urlencoded"
  if (idempotency) headers["idempotency-key"] = idempotency
  const res = await fetch(`https://api.stripe.com${path}`, { method, headers, ...(form ? { body: new URLSearchParams(form).toString() } : {}) })
  const body = await res.json()
  if (!res.ok && !(res.status === 404 && method === "GET")) throw new Error(`${method} ${path}: ${res.status} ${body?.error?.code ?? ""} ${body?.error?.message ?? ""}`)
  return res.ok ? body : null
}

const findMeter = async (eventName: string) => {
  let after: string | undefined
  for (;;) {
    const page = await api("GET", `/v1/billing/meters?status=active&limit=100${after ? `&starting_after=${after}` : ""}`)
    const hit = page.data.find((m: any) => m.event_name === eventName)
    if (hit || !page.has_more) return hit ?? null
    after = page.data.at(-1).id
  }
}

const meters = {} as Record<IncludedMode, any>
for (const mode of INCLUDED_MODES) {
  const eventName = usageMeterEvent(mode)
  let meter = await findMeter(eventName)
  if (!meter && !check) {
    meter = await api("POST", "/v1/billing/meters", {
      display_name: mode === "per_seat" ? "cmux AI usage above included" : "cmux AI usage",
      event_name: eventName,
      "default_aggregation[formula]": "last",
      "customer_mapping[type]": "by_id",
      "customer_mapping[event_payload_key]": "stripe_customer_id",
      "value_settings[event_payload_key]": "value"
    }, `meter-${eventName}-v1`)
  }
  if (meter && meter.default_aggregation?.formula !== "last") throw new Error(`meter ${meter.id} aggregates ${meter.default_aggregation?.formula}, expected last`)
  meters[mode] = meter
}

let product = await api("GET", `/v1/products/${PRODUCT_ID}`)
if (!product && !check) product = await api("POST", "/v1/products", { id: PRODUCT_ID, name: "cmux AI usage", description: "AI model usage above your plan's included amount, at cost." }, `product-${PRODUCT_ID}-v1`)

const prices: Record<string, any> = {}
for (const plan of Object.keys(INCLUDED_USD) as Array<keyof typeof INCLUDED_USD>) for (const mode of usageModesOf(plan)) {
  const meter = meters[mode]
  const lookup = usagePriceLookupKey(plan, SET, mode)
  // A graduated tier ends at a whole unit (Stripe): a fractional amount has the per-seat price only.
  if (mode === "per_team" && !Number.isInteger(INCLUDED_USD[plan])) {
    prices[`${plan}:${mode}`] = { skipped: `${INCLUDED_USD[plan]} USD is not a whole unit; per seat only` }
    continue
  }
  let price = (await api("GET", `/v1/prices?lookup_keys[]=${lookup}&active=true&expand[]=data.tiers`)).data[0] ?? null
  if (!price && !check && meter && product) {
    const common = {
      product: PRODUCT_ID,
      currency: "usd",
      lookup_key: lookup,
      nickname: `AI usage, ${plan}, ${INCLUDED_USD[plan]} USD included ${mode === "per_seat" ? "per seat" : "per team"}, pass-through ${SET}`,
      "recurring[interval]": "month",
      "recurring[usage_type]": "metered",
      "recurring[meter]": meter.id,
      "metadata[plan]": plan,
      "metadata[included_mode]": mode,
      "metadata[price_version]": `ai-passthrough-${SET}`
    }
    price = mode === "per_seat"
      ? await api("POST", "/v1/prices", { ...common, billing_scheme: "per_unit", unit_amount_decimal: "100" }, `price-${lookup}`)
      : await api("POST", "/v1/prices?expand[]=tiers", { ...common, billing_scheme: "tiered", tiers_mode: "graduated", "tiers[0][up_to]": String(INCLUDED_USD[plan]), "tiers[0][unit_amount_decimal]": "0", "tiers[1][up_to]": "inf", "tiers[1][unit_amount_decimal]": "100" }, `price-${lookup}`)
  }
  const tiers = price?.tiers ?? []
  const matches = !price || (price.recurring?.usage_type === "metered" && price.recurring?.meter === meter?.id && (mode === "per_seat" ? price.billing_scheme === "per_unit" && price.unit_amount_decimal === "100" : price.tiers_mode === "graduated" && tiers[0]?.up_to === INCLUDED_USD[plan] && tiers[1]?.unit_amount_decimal === "100"))
  if (!matches) throw new Error(`price ${price.id} (${lookup}) does not match the catalog`)
  prices[`${plan}:${mode}`] = price && { id: price.id, lookup_key: price.lookup_key, mode, included_usd: INCLUDED_USD[plan], then_cents_per_usd: mode === "per_seat" ? price.unit_amount_decimal : tiers[1]?.unit_amount_decimal }
}

console.log(JSON.stringify({ livemode: false, meters: Object.fromEntries(INCLUDED_MODES.map((m) => [m, meters[m] && { id: meters[m].id, event_name: meters[m].event_name, formula: meters[m].default_aggregation?.formula }])), product: product && { id: product.id, name: product.name }, prices }, null, 2))
if (check && (INCLUDED_MODES.some((m) => !meters[m]) || !product || Object.values(prices).some((p) => !p))) process.exit(1)
