// cx-y79zh end-to-end run, Stripe TEST MODE only, against the development Worker (BILLING_USAGE_PRICE_SET=e2e).
// One test clock, two teams side by side (cx-y79zh.1, Lawrence 2026-10-14):
// - "team" (per team): the agent's personal team on a Pro plan item; the graduated price, 1 USD included.
// - "seat" (per seat): the agent's shared e2e team (sign-in service team E2E_STACK_TEAM, cmuxPlan=team) on a
//   Team plan item with 2 seats; the operator setting per_seat (POST /v1/internal/billing/team-mode) is made
//   before the subscription starts, so it is in force from the first period; the flat price, 2 x 0.5 USD.
// Run on a Freestyle VM, one phase per call, in order: PHASE=a, PHASE=more (repeat until both levels pass
// their included amounts), PHASE=b, PHASE=c, PHASE=cleanup.
// /root/.wt/secrets.json (written 0600 and shredded by the VM helper): { stripe, levels, project, publishable,
// email, password }. Nothing here prints a secret; it prints ids and amounts only.
import { existsSync, readFileSync, writeFileSync } from "node:fs"
const sec = JSON.parse(readFileSync("/root/.wt/secrets.json", "utf8"))
if (!/^(sk|rk)_test_/.test(sec.stripe)) throw new Error("test key only")
if (sec.project !== "454ecd03-1db2-4050-845e-4ce5b0cd9895") throw new Error("dev sign-in project only")
const ORIGIN = "https://cmux-api-development.debussy.workers.dev"
const V = "2026-06-24.dahlia"
const STACK_TEAM = process.env.E2E_STACK_TEAM ?? "e8733fff-8ce2-457b-9d6a-d20223d46a71"
const SEATS = 2
/** The e2e set's included amounts (billing-catalog.ts): Pro 1 per team, Team 0.5 per seat. */
const INCLUDED = { team: 1, seat: 0.5 * SEATS } as const
const log = (k: string, v: unknown) => console.log(JSON.stringify({ [k]: v }))
const stripe = async (method: string, path: string, form?: Record<string, string>) => {
  const res = await fetch(`https://api.stripe.com${path}`, { method, headers: { authorization: `Bearer ${sec.stripe}`, "stripe-version": V, ...(form ? { "content-type": "application/x-www-form-urlencoded" } : {}) }, ...(form ? { body: new URLSearchParams(form).toString() } : {}) })
  const b = (await res.json()) as any
  if (!res.ok) throw new Error(`${method} ${path.split("?")[0]} ${res.status} ${b?.error?.code} ${b?.error?.message}`)
  return b
}
const clockReady = async (id: string) => {
  for (let i = 0; i < 150; i++) {
    const c = await stripe("GET", `/v1/test_helpers/test_clocks/${id}`)
    if (c.status === "ready") return c
    // Bounded wait (why, cx-y79zh S5 review): a test clock advance is asynchronous, and its only push signal is the
    // test_helpers.test_clock.ready webhook, which this script (no public endpoint) cannot receive. It reads the
    // clock's own status instead, every 2 s, at most 5 min.
    await new Promise((r) => setTimeout(r, 2000))
  }
  throw new Error("clock not ready")
}
const advance = async (id: string, to: number) => {
  await stripe("POST", `/v1/test_helpers/test_clocks/${id}/advance`, { frozen_time: String(to) })
  return clockReady(id)
}
const signIn = async () => {
  const res = await fetch("https://api.stack-auth.com/api/v1/auth/password/sign-in", { method: "POST", headers: { "content-type": "application/json", "x-stack-project-id": sec.project, "x-stack-access-type": "client", "x-stack-publishable-client-key": sec.publishable }, body: JSON.stringify({ email: sec.email, password: sec.password }) })
  const b = (await res.json()) as any
  if (!res.ok) throw new Error(`sign-in ${res.status} ${b?.code}`)
  return { token: b.access_token as string, stackUser: b.user_id as string }
}
const internal = async (path: string, body: unknown) => (await (await fetch(`${ORIGIN}${path}`, { method: "POST", headers: { authorization: `Bearer ${sec.levels}`, "content-type": "application/json" }, body: JSON.stringify(body) })).json()) as any
const filler = "The quick brown fox jumps over the lazy dog. ".repeat(Number(process.env.E2E_REPEAT ?? "26000"))
/** One AI call for the personal team, or (team set) for the shared team named in x-cmux-team. */
const chat = async (token: string, team?: string) => {
  const res = await fetch(`${ORIGIN}/v1/inference/chat/completions`, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json", ...(team ? { "x-cmux-team": team } : {}) }, body: JSON.stringify({ model: "deepseek/deepseek-v4-pro", max_tokens: 8, messages: [{ role: "user", content: `${filler}\nReply with ok.` }] }) })
  const text = await res.text()
  return res.status === 200 ? 200 : `${res.status} ${text.slice(0, 160)}`
}
const meterId = async (event: string): Promise<string> => {
  const m = (await stripe("GET", "/v1/billing/meters?status=active&limit=100")).data.find((x: any) => x.event_name === event)
  if (!m) throw new Error(`no test meter ${event} (run stripe-usage-catalog.ts --set=e2e)`)
  return m.id
}
/** The first active monthly licensed (plan) price whose lookup key starts with `prefix` (the search API has no prefix match on lookup keys). */
const planPrice = async (prefix: string) => {
  const found: any[] = []
  let after: string | undefined
  for (let page = 0; page < 10 && found.length === 0; page++) {
    const list = await stripe("GET", `/v1/prices?active=true&type=recurring&limit=100${after ? `&starting_after=${after}` : ""}`)
    found.push(...list.data.filter((p: any) => typeof p.lookup_key === "string" && p.lookup_key.startsWith(prefix) && p.recurring?.interval === "month" && p.recurring?.usage_type !== "metered"))
    if (!list.has_more) break
    after = list.data.at(-1).id
  }
  if (!found[0]) throw new Error(`no monthly test plan price with lookup key ${prefix}*`)
  return found[0]
}

const STATE = "/root/e2e-state-both.json"
const phase = process.env.PHASE ?? "a"
const st: any = existsSync(STATE) ? JSON.parse(readFileSync(STATE, "utf8")) : {}
const save = () => writeFileSync(STATE, JSON.stringify(st))
const { token, stackUser } = await signIn()
const METERS = { team: await meterId("cmux_ai_usage"), seat: await meterId("cmux_ai_usage_above_included") }
type Side = "team" | "seat"
const SIDES: ReadonlyArray<Side> = ["team", "seat"]
const levelItem = (side: Side) => (side === "team" ? { stack_user: stackUser } : { stack_team: STACK_TEAM })
const levelNow = async (side: Side) => (await internal("/v1/internal/billing/levels", { items: [{ ...levelItem(side), from: st[side].start * 1000, to: st[side].end * 1000 }] })).levels[0]
const sync = (side: Side) => internal("/v1/internal/billing/sync", { subscription: st[side].sub })
const call = (side: Side) => chat(token, side === "seat" ? st.team_id : undefined)
/** What each meter should show: the whole level per team, the level above included x seats per seat. */
const meterValue = (side: Side, usd: number) => (side === "seat" ? Math.max(0, Math.round((usd - INCLUDED.seat) * 1e6) / 1e6) : usd)
/** Stripe aggregates meter events asynchronously (45-50 s measured): wait, bounded, until the summary shows the level sent. */
const settledSummary = async (side: Side, usd: number) => {
  for (let i = 0; i < 90; i++) {
    const s = await stripe("GET", `/v1/billing/meters/${METERS[side]}/event_summaries?customer=${st[side].cus}&start_time=${st[side].start}&end_time=${st[side].end}`)
    const v = s.data[0]?.aggregated_value
    if (typeof v === "number" && Math.abs(v - meterValue(side, usd)) < 1e-9) return { seconds: i * 5, value: v }
    await new Promise((r) => setTimeout(r, 5000))
  }
  return { seconds: null, value: null }
}
/**
 * A test clock stays at its frozen time, and the payment service refuses a meter event dated more than a few
 * minutes after the customer's clock time. The sync dates events at real time (live mode has no clock), so
 * before a sync in the running period the clock moves up to real time (never back, never past the period).
 */
const catchUp = async () => {
  const c = await stripe("GET", `/v1/test_helpers/test_clocks/${st.clock}`)
  const now = Math.floor(Date.now() / 1000)
  if (c.frozen_time < now - 60 && now < Math.min(st.team.end, st.seat.end) - 900) await advance(st.clock, now)
}
const syncAndLevel = async (label: string) => {
  await catchUp()
  for (const side of SIDES) {
    log(`${label}-${side}`, await sync(side))
    st[side].level = await levelNow(side)
  }
  save()
  log("levels", Object.fromEntries(SIDES.map((s) => [s, st[s].level.micros / 1e6])))
}

if (phase === "a") {
  // The operator setting first, so it is in force at the subscription's first period start.
  const set = await internal("/v1/internal/billing/team-mode", { stack_team: STACK_TEAM, mode: "per_seat", actor: "e2e-hq-84", reason: "cx-y79zh.1 e2e per-seat team" })
  log("team_mode", { team: set.team, before: set.before, mode: set.mode, changed: set.changed, applies: set.applies })
  st.team_id = set.team
  // The setting is recorded in ms and the clock's period starts at a whole second: a 2 s gap (deliberate, not a
  // synchronization wait) makes the period start later than the setting, so the setting is in force from it.
  await new Promise((r) => setTimeout(r, 2000))
  const prices = { team: await planPrice("cmux-pro-monthly"), seat: await planPrice("cmux-team-") }
  const clock = await stripe("POST", "/v1/test_helpers/test_clocks", { frozen_time: String(Math.floor(Date.now() / 1000)), name: "cx-y79zh.1 usage e2e team+seat" })
  st.clock = clock.id
  save()
  log("clock", clock.id)
  for (const side of SIDES) {
    const cus = await stripe("POST", "/v1/customers", { test_clock: clock.id, email: `usage-e2e-${side}@example.com`, payment_method: "pm_card_visa", "invoice_settings[default_payment_method]": "pm_card_visa", "metadata[purpose]": "cx-y79zh.1 e2e" })
    const meta = side === "team" ? { "metadata[plan]": "pro", "metadata[stackUserId]": stackUser } : { "metadata[plan]": "team", "metadata[stackTeamId]": STACK_TEAM }
    const sub = await stripe("POST", "/v1/subscriptions", { customer: cus.id, "items[0][price]": prices[side].id, "items[0][quantity]": String(side === "seat" ? SEATS : 1), "metadata[app]": "cmux", ...meta })
    st[side] = { sub: sub.id, cus: cus.id, start: sub.items.data[0].current_period_start, end: sub.items.data[0].current_period_end, plan_cents: prices[side].unit_amount * (side === "seat" ? SEATS : 1), plan_lookup: prices[side].lookup_key }
    save()
    log("subscription", { side, id: sub.id, customer: cus.id, plan: prices[side].lookup_key, start: st[side].start, end: st[side].end })
  }
  for (const side of SIDES) log(`chat-before-sync-${side}`, await call(side))
  await syncAndLevel("sync1")
}
if (phase === "more") {
  const n = Number(process.env.E2E_BIG_CALLS ?? "8")
  for (const side of (process.env.E2E_SIDE ? [process.env.E2E_SIDE as Side] : SIDES)) for (let i = 0; i < n; i++) log(`chat-${side}`, await call(side))
  await syncAndLevel("sync-more")
}
if (phase === "b") {
  for (const side of SIDES) log(`summary_before_end_${side}`, await settledSummary(side, st[side].level.micros / 1e6))
  const end = Math.min(st.team.end, st.seat.end)
  // The last 15 minutes of the period: usage arrives, the sync runs.
  await advance(st.clock, end - 600)
  for (const side of SIDES) log(`chat-last-15-min-${side}`, await call(side))
  await syncAndLevel("sync2")
  for (const side of SIDES) log(`summary_last_15_min_${side}`, await settledSummary(side, st[side].level.micros / 1e6))
  // Both periods end: Stripe renews and makes the draft invoices; one more call each before finalization.
  await advance(st.clock, Math.max(st.team.end, st.seat.end) + 60)
  for (const side of SIDES) log(`chat-after-renewal-${side}`, await call(side))
  await syncAndLevel("sync3")
  for (const side of SIDES) log(`summary_after_renewal_${side}`, await settledSummary(side, st[side].level.micros / 1e6))
}
if (phase === "c") {
  await advance(st.clock, Math.max(st.team.end, st.seat.end) + 3 * 3600)
  const checks: Record<string, unknown> = {}
  for (const side of SIDES) {
    const invs = (await stripe("GET", `/v1/invoices?subscription=${st[side].sub}&limit=5&expand[]=data.lines`)).data
    const renewal = invs.find((i: any) => i.billing_reason === "subscription_cycle")
    log(`invoice-${side}`, renewal && { id: renewal.id, status: renewal.status, total: renewal.total, lines: renewal.lines.data.map((l: any) => ({ description: l.description, quantity_decimal: l.quantity_decimal, amount: l.amount })) })
    const summary = await stripe("GET", `/v1/billing/meters/${METERS[side]}/event_summaries?customer=${st[side].cus}&start_time=${st[side].start}&end_time=${st[side].end}`)
    const usageCents = (renewal?.lines.data ?? []).filter((l: any) => /AI usage/i.test(l.description ?? "")).reduce((n: number, l: any) => n + l.amount, 0)
    const usd = st[side].level.micros / 1e6
    const expect = Math.round(Math.max(0, usd - INCLUDED[side]) * 100)
    checks[side] = { level_usd: usd, included_usd: INCLUDED[side], meter_summary: summary.data.map((x: any) => x.aggregated_value), expected_usage_cents: expect, invoice_usage_cents: usageCents, invoice_total: renewal?.total ?? null, pass: usageCents > 0 && usageCents === expect && renewal?.total === st[side].plan_cents + expect }
  }
  log("check", checks)
}
if (phase === "cleanup") {
  for (const side of SIDES) if (st[side]?.sub) await stripe("DELETE", `/v1/subscriptions/${st[side].sub}`).then(() => log("cleanup", `${side} subscription canceled`)).catch((e) => log("cleanup_error", String(e)))
  if (st.clock) await stripe("DELETE", `/v1/test_helpers/test_clocks/${st.clock}`).then(() => log("cleanup", `test clock ${st.clock} deleted`)).catch((e) => log("cleanup_error", String(e)))
  // The shared e2e team goes back to the per-team default (from its next period).
  const back = await internal("/v1/internal/billing/team-mode", { stack_team: STACK_TEAM, mode: "per_team", actor: "e2e-hq-84", reason: "cx-y79zh.1 e2e cleanup" })
  log("team_mode_reset", { before: back.before, mode: back.mode, changed: back.changed })
}
