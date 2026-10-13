// cx-y79zh end-to-end run, Stripe TEST MODE only, against the development Worker
// (BILLING_USAGE_PRICE_SET=e2e: 1 USD included). Run on a Freestyle VM, one phase per call, in order:
// PHASE=a, PHASE=more (repeat until the level passes 1 USD), PHASE=b, PHASE=c, PHASE=cleanup.
// The secrets file is written and shredded by the VM exec helper; nothing here prints a secret.
// /root/.wt/secrets.json: { stripe, levels, project, publishable, email, password }. Prints ids and amounts only.
import { readFileSync } from "node:fs"
const sec = JSON.parse(readFileSync("/root/.wt/secrets.json", "utf8"))
if (!/^(sk|rk)_test_/.test(sec.stripe)) throw new Error("test key only")
if (sec.project !== "454ecd03-1db2-4050-845e-4ce5b0cd9895") throw new Error("dev sign-in project only")
const ORIGIN = "https://cmux-api-development.debussy.workers.dev"
const METER = "mtr_test_61VZNivVpiXTtlinB41LbtiW1udY8LPk"
const V = "2026-06-24.dahlia"
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
    await new Promise((r) => setTimeout(r, 2000)) // bounded wait on Stripe's own clock state (no product sync)
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
// One AI call; a long prompt so the period's usage crosses the e2e set's 1 USD included tier.
const filler = "The quick brown fox jumps over the lazy dog. ".repeat(Number(process.env.E2E_REPEAT ?? "26000"))
const chat = async (token: string, big: boolean) => {
  const res = await fetch(`${ORIGIN}/v1/inference/chat/completions`, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify({ model: "deepseek/deepseek-v4-pro", max_tokens: 8, messages: [{ role: "user", content: big ? `${filler}\nReply with ok.` : "Reply with ok." }] }) })
  const text = await res.text()
  return res.status === 200 ? 200 : `${res.status} ${text.slice(0, 160)}`
}

import { writeFileSync, existsSync } from "node:fs"
const STATE = "/root/e2e-state.json"
const phase = process.env.PHASE ?? "a"
const st: any = existsSync(STATE) ? JSON.parse(readFileSync(STATE, "utf8")) : {}
const save = () => writeFileSync(STATE, JSON.stringify(st))
const { token, stackUser } = await signIn()
/** Stripe aggregates meter events asynchronously: wait (bounded) until its summary shows the level the sync sent. */
const settledSummary = async (cus: string, start: number, end: number, usd: number) => {
  for (let i = 0; i < 90; i++) {
    const s = await stripe("GET", `/v1/billing/meters/${METER}/event_summaries?customer=${cus}&start_time=${start}&end_time=${end}`)
    const v = s.data[0]?.aggregated_value
    if (typeof v === "number" && Math.abs(v - usd) < 1e-9) return { seconds: i * 5, value: v }
    await new Promise((r) => setTimeout(r, 5000))
  }
  return { seconds: null, value: null }
}
const levelNow = async (stackUser: string) => (await internal("/v1/internal/billing/levels", { items: [{ stack_user: stackUser, from: st.start * 1000, to: st.end * 1000 }] })).levels[0]
const internalSync = () => internal("/v1/internal/billing/sync", { subscription: st.sub })
if (phase === "a") {
  log("agent", { stack_user: stackUser })
  const plan = (await stripe("GET", "/v1/prices?lookup_keys[]=cmux-pro-monthly-50&active=true")).data[0]
  if (!plan) throw new Error("no test pro price (cmux-pro-monthly-50)")
  const now = Math.floor(Date.now() / 1000)
  const clock = await stripe("POST", "/v1/test_helpers/test_clocks", { frozen_time: String(now), name: "cx-y79zh usage e2e" })
  st.clock = clock.id; save()
  log("clock", clock.id)
  const cus = await stripe("POST", "/v1/customers", { test_clock: clock.id, email: "usage-e2e@example.com", payment_method: "pm_card_visa", "invoice_settings[default_payment_method]": "pm_card_visa", "metadata[purpose]": "cx-y79zh e2e" })
  const sub = await stripe("POST", "/v1/subscriptions", { customer: cus.id, "items[0][price]": plan.id, "metadata[app]": "cmux", "metadata[plan]": "pro", "metadata[stackUserId]": stackUser })
  Object.assign(st, { sub: sub.id, cus: cus.id, start: sub.items.data[0].current_period_start, end: sub.items.data[0].current_period_end, plan_amount: plan.unit_amount }); save()
  log("subscription", { id: sub.id, customer: cus.id, start: st.start, end: st.end })
  for (let i = 0; i < Number(process.env.E2E_BIG_CALLS ?? "3"); i++) log("chat", await chat(token, true))
  log("sync1", await internalSync())
  log("sync1-again", await internalSync())
}
if (phase === "more") {
  for (let i = 0; i < Number(process.env.E2E_BIG_CALLS ?? "10"); i++) log("chat", await chat(token, true))
  log("sync-more", await internalSync())
  st.level = await levelNow(stackUser); save()
  log("level", st.level)
}
if (phase === "b") {
  log("summary_settled_before_end", await settledSummary(st.cus, st.start, st.end, st.level.micros / 1e6))
  // The last 15 minutes of the period: the clock stands 10 minutes before the end; usage arrives; the sync runs.
  await advance(st.clock, st.end - 600)
  log("chat-last-15-min", await chat(token, true))
  log("sync2", await internalSync())
  st.level = await levelNow(stackUser); save()
  log("summary_settled_last_15_min", await settledSummary(st.cus, st.start, st.end, st.level.micros / 1e6))
  // The period ends: Stripe renews and makes the draft invoice; one more call lands before finalization.
  await advance(st.clock, st.end + 60)
  log("chat-after-renewal", await chat(token, true))
  log("sync3", await internalSync())
  st.level = await levelNow(stackUser); save()
  log("level_closed_period", st.level)
  log("summary_settled_after_renewal", await settledSummary(st.cus, st.start, st.end, st.level.micros / 1e6))
  const drafts = (await stripe("GET", `/v1/invoices?subscription=${st.sub}&limit=5`)).data
  log("invoices_before_finalize", drafts.map((i: any) => ({ id: i.id, status: i.status, billing_reason: i.billing_reason })))
}
if (phase === "c") {
  await advance(st.clock, st.end + 3 * 3600)
  const invs = (await stripe("GET", `/v1/invoices?subscription=${st.sub}&limit=5&expand[]=data.lines`)).data
  for (const inv of invs) log("invoice", { id: inv.id, status: inv.status, billing_reason: inv.billing_reason, total: inv.total, lines: inv.lines.data.map((l: any) => ({ description: l.description, quantity: l.quantity, quantity_decimal: l.quantity_decimal, amount: l.amount, period: l.period })) })
  const summary = await stripe("GET", `/v1/billing/meters/${METER}/event_summaries?customer=${st.cus}&start_time=${st.start}&end_time=${st.end}`)
  log("meter_summary", summary.data.map((x: any) => x.aggregated_value))
  const renewal = invs.find((i: any) => i.billing_reason === "subscription_cycle")
  // The usage lines (one per graduated tier) together bill the level above the included 1 USD.
  const usageLines = (renewal?.lines.data ?? []).filter((l: any) => /AI usage/i.test(l.description ?? ""))
  const usageCents = usageLines.reduce((n: number, l: any) => n + l.amount, 0)
  const usd = st.level.micros / 1_000_000
  const expectCents = Math.round(Math.max(0, usd - 1) * 100)
  log("check", { level_usd: usd, expected_usage_cents: expectCents, invoice_usage_cents: usageCents, invoice_total: renewal?.total ?? null, invoice_status: renewal?.status ?? null, pass: usageLines.length > 0 && usageCents === expectCents && renewal?.total === st.plan_amount + expectCents })
}
if (phase === "cleanup") {
  if (st.sub) await stripe("DELETE", `/v1/subscriptions/${st.sub}`).then(() => log("cleanup", "subscription canceled")).catch((e) => log("cleanup_error", String(e)))
  if (st.clock) await stripe("DELETE", `/v1/test_helpers/test_clocks/${st.clock}`).then(() => log("cleanup", `test clock ${st.clock} deleted`)).catch((e) => log("cleanup_error", String(e)))
}
