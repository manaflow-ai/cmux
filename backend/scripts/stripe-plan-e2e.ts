// NEXT plan checkout end-to-end, Stripe TEST MODE only, against the development Worker (plan-checkout.ts).
// For each NEXT plan it signs a plan link the way TeamDO.nextPlanLink does (BILLING_LEVELS_KEY, `plan-link:`), opens it,
// takes the 303 to a Stripe Checkout Session, and reads that session back from Stripe: test mode, a monthly
// subscription at the plan's price, and the cmux_plan metadata the credits webhook grants from. Then it expires the
// session, so nothing is left open. Paying (the hosted page's card form) and the webhook grant are unit-tested
// (test/plan-checkout.test.ts); this proves the deployed link and session.
// Secrets: E2E_STRIPE_TEST_KEY and E2E_BILLING_LEVELS_KEY (the billing-e2e workflow). It prints ids and amounts only.
const ORIGIN = process.env.E2E_ORIGIN ?? "https://cmux-api-development.debussy.workers.dev"
const KEY = process.env.E2E_STRIPE_TEST_KEY ?? ""
const LEVELS = process.env.E2E_BILLING_LEVELS_KEY ?? ""
if (!/^(sk|rk)_test_/.test(KEY)) throw new Error("test key only")
if (LEVELS.length < 32) throw new Error("E2E_BILLING_LEVELS_KEY is missing")
if (!/^https:\/\/cmux-api-(development|staging)\./.test(ORIGIN)) throw new Error("development or staging only")
const PLANS = { next_plus: 20, next_pro: 50, next_max: 200 } as const
const TEAM = process.env.E2E_PLAN_TEAM ?? "team_e2e0000000000000000a"
const log = (k: string, v: unknown) => console.log(JSON.stringify({ [k]: v }))
const enc = new TextEncoder()
const hmacHex = async (secret: string, msg: string) => {
  const k = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", k, enc.encode(msg)))].map((b) => b.toString(16).padStart(2, "0")).join("")
}
const b64url = (s: string) => btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const stripe = async (method: string, path: string) => {
  const res = await fetch(`https://api.stripe.com${path}`, { method, headers: { authorization: `Bearer ${KEY}` } })
  const b = (await res.json()) as any
  if (!res.ok) throw new Error(`${method} ${path.split("?")[0]} ${res.status} ${b?.error?.code}`)
  return b
}
let failed = 0
for (const [plan, usd] of Object.entries(PLANS)) {
  const payload = b64url(JSON.stringify({ t: TEAM, p: plan, e: Date.now() + 3600_000 }))
  const res = await fetch(`${ORIGIN}/v1/billing/plan/${payload}.${await hmacHex(LEVELS, `plan-link:${payload}`)}`, { redirect: "manual" })
  const to = res.headers.get("location") ?? ""
  const id = /\/(cs_test_[A-Za-z0-9]+)/.exec(to)?.[1]
  if (res.status !== 303 || !id) {
    log("plan_checkout", { plan, pass: false, status: res.status, location_host: to ? new URL(to).host : null })
    failed++
    continue
  }
  const s = await stripe("GET", `/v1/checkout/sessions/${id}?expand[]=line_items`)
  const item = s.line_items?.data?.[0]
  const check = {
    plan,
    session: id,
    livemode: s.livemode,
    mode: s.mode,
    amount_total: s.amount_total,
    interval: item?.price?.recurring?.interval,
    metadata: { kind: s.metadata?.kind, team: s.metadata?.team, plan: s.metadata?.plan },
  }
  const pass = s.livemode === false && s.mode === "subscription" && s.amount_total === usd * 100 && check.interval === "month" &&
    s.metadata?.kind === "cmux_plan" && s.metadata?.team === TEAM && s.metadata?.plan === plan
  if (!pass) failed++
  log("plan_checkout", { ...check, pass })
  await stripe("POST", `/v1/checkout/sessions/${id}/expire`).then(() => log("cleanup", `${id} expired`)).catch((e) => log("cleanup_error", String(e)))
}
if (failed) {
  console.error(`::error::${failed} NEXT plan checkout(s) failed`)
  process.exit(1)
}
