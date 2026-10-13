#!/usr/bin/env bun
/**
 * Test-mode Stripe catalog for usage billing (cx-y79zh S3, plans/cmux-next/usage-billing.md).
 * Idempotent: finds each object first and creates only what is missing.
 *
 *   STRIPE_USAGE_KEY=<sk_test_...> bun backend/scripts/stripe-usage-catalog.ts [--check]
 *
 * - Meter `cmux_ai_usage`, aggregation `last`: the reconcile worker sends the period's billable
 *   level (USD above the plan's included amount), never deltas.
 * - Product `cmux_ai_usage` ("cmux AI usage") and one graduated metered price per plan, lookup key
 *   `cmux-ai-usage-<plan>-incl<N>-v1`: the first N units at 0, then 1.00 USD per unit; one unit =
 *   one USD of AI usage at our cost (pass-through, Lawrence 2026-10-13). The meter value is the
 *   period's whole AI usage level; the tier applies the plan's included amount. N are test-mode
 *   placeholders (Lawrence sets the real ones before live). Team's N is per team, not per seat.
 *
 * Refuses any live key: live objects are Lawrence's step. Prints object ids and settings only.
 */
import { USAGE_INCLUDED_USD as INCLUDED_USD, USAGE_METER_EVENT as METER_EVENT, USAGE_PRODUCT_ID as PRODUCT_ID, usagePriceLookupKey as priceLookupKey } from "../apps/api/src/billing-catalog.ts"
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

const findMeter = async () => {
  let after: string | undefined
  for (;;) {
    const page = await api("GET", `/v1/billing/meters?status=active&limit=100${after ? `&starting_after=${after}` : ""}`)
    const hit = page.data.find((m: any) => m.event_name === METER_EVENT)
    if (hit || !page.has_more) return hit ?? null
    after = page.data.at(-1).id
  }
}

let meter = await findMeter()
if (!meter && !check) {
  meter = await api("POST", "/v1/billing/meters", {
    display_name: "cmux AI usage",
    event_name: METER_EVENT,
    "default_aggregation[formula]": "last",
    "customer_mapping[type]": "by_id",
    "customer_mapping[event_payload_key]": "stripe_customer_id",
    "value_settings[event_payload_key]": "value"
  }, `meter-${METER_EVENT}-v1`)
}
if (meter && meter.default_aggregation?.formula !== "last") throw new Error(`meter ${meter.id} aggregates ${meter.default_aggregation?.formula}, expected last`)

let product = await api("GET", `/v1/products/${PRODUCT_ID}`)
if (!product && !check) product = await api("POST", "/v1/products", { id: PRODUCT_ID, name: "cmux AI usage", description: "AI model usage above your plan's included amount, at cost." }, `product-${PRODUCT_ID}-v1`)

const prices: Record<string, any> = {}
for (const plan of Object.keys(INCLUDED_USD) as Array<keyof typeof INCLUDED_USD>) {
  const lookup = priceLookupKey(plan)
  let price = (await api("GET", `/v1/prices?lookup_keys[]=${lookup}&active=true&expand[]=data.tiers`)).data[0] ?? null
  if (!price && !check && meter && product) {
    price = await api("POST", "/v1/prices?expand[]=tiers", {
      product: PRODUCT_ID,
      currency: "usd",
      lookup_key: lookup,
      nickname: `AI usage, ${plan}, ${INCLUDED_USD[plan]} USD included, pass-through v1`,
      billing_scheme: "tiered",
      tiers_mode: "graduated",
      "tiers[0][up_to]": String(INCLUDED_USD[plan]),
      "tiers[0][unit_amount_decimal]": "0",
      "tiers[1][up_to]": "inf",
      "tiers[1][unit_amount_decimal]": "100",
      "recurring[interval]": "month",
      "recurring[usage_type]": "metered",
      "recurring[meter]": meter.id,
      "metadata[plan]": plan,
      "metadata[price_version]": "ai-passthrough-v1"
    }, `price-${lookup}`)
  }
  const tiers = price?.tiers ?? []
  if (price && (price.recurring?.usage_type !== "metered" || price.recurring?.meter !== meter?.id || price.tiers_mode !== "graduated" || tiers[0]?.up_to !== INCLUDED_USD[plan] || tiers[1]?.unit_amount_decimal !== "100")) throw new Error(`price ${price.id} (${lookup}) does not match the catalog`)
  prices[plan] = price && { id: price.id, lookup_key: price.lookup_key, included_usd: tiers[0]?.up_to, then_cents_per_usd: tiers[1]?.unit_amount_decimal }
}

console.log(JSON.stringify({ livemode: false, meter: meter && { id: meter.id, event_name: meter.event_name, formula: meter.default_aggregation?.formula }, product: product && { id: product.id, name: product.name }, prices }, null, 2))
if (check && (!meter || !product || Object.values(prices).some((p) => !p))) process.exit(1)
