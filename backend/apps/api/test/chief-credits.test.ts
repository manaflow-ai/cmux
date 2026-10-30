import { env } from "cloudflare:workers"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.ts"
import { CreditsGate } from "../src/chief-brain/credits-gate.ts"
import { mirrorCredits, mirrorDue, mirrorFailed } from "../src/credits-mirror.ts"
import { userIdFor } from "../src/domains/user.ts"
import { hmacHex } from "../src/ingress/verify.ts"
import { inDO, post, testEnv, token } from "./setup/inference-person.ts"

/**
 * Prepaid Cloud Chief credits (credits.ts, Lawrence 2026-10-15: "people must load credits to use
 * it"), at the Worker's boundaries: the member routes (GET /v1/credits, the signed top-up link, the
 * return page), the payment service's webhook and the operator route over HTTP, with the payment
 * service faked at api.stripe.com; and the brain's gate (chief-brain/credits-gate.ts, the class the
 * brain's model hooks call) against the team's real UsageMeterDO.
 */
const KEY = "test-billing-levels-key-0123456789abcdef"
const WEBHOOK = "whsec_test_credits_0123456789"
const ORIGIN = "https://api.test"
const runEnv = (extra: Record<string, string> = {}) => ({ ...env, CLOUD_API_ORIGIN: ORIGIN, STRIPE_CREDITS_WEBHOOK_SECRET: WEBHOOK, ...extra }) as any

const call = async (e: unknown, method: string, path: string, opts: { token?: string; body?: string; headers?: Record<string, string> } = {}) => {
  const ctx = createExecutionContext()
  const headers: Record<string, string> = { ...(opts.body ? { "content-type": "application/json" } : {}), ...(opts.token ? { authorization: `Bearer ${opts.token}` } : {}), ...opts.headers }
  const res = await worker.fetch!(new Request(`${ORIGIN}${path}`, { method, headers, redirect: "manual", ...(opts.body ? { body: opts.body } : {}) }) as any, e as any, ctx)
  const text = await res.text()
  await waitOnExecutionContext(ctx)
  let json: any = null
  try {
    json = JSON.parse(text)
  } catch {}
  return { status: res.status, text, json, location: res.headers.get("location") }
}
const admin = (e: unknown, body: unknown, key = KEY) => call(e, "POST", "/v1/internal/credits", { body: JSON.stringify(body), headers: { authorization: `Bearer ${key}` } })

const person = async (stackUser: string) => {
  const t = await token(stackUser)
  const ensured = await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })
  return { t, team: ensured.value.personal_team as string, user: userIdFor(testEnv.STACK_PROJECT_ID, stackUser) }
}

/** A priced model (USD per million tokens, pi-ai's table shape) and a provider message that cost `usd`. */
const MODEL = { id: "priced", name: "priced", api: "anthropic-messages", provider: "test", baseUrl: "https://x.test", reasoning: false, input: ["text"], cost: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 }, contextWindow: 200_000, maxTokens: 1000 } as any
const answered = (usd: number) => ({ role: "assistant", content: [{ type: "text", text: "ok" }], api: "anthropic-messages", provider: "test", model: "priced", stopReason: "stop", timestamp: Date.now(), usage: { input: 10, output: 5, cacheRead: 0, cacheWrite: 0, totalTokens: 15, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: usd } } }) as any
const MESSAGES = [{ role: "user", content: [{ type: "text", text: "is the release green?" }] }]

/** The payment service: Checkout sessions it makes and reads back (paid at once, like a test card). */
const fakeCheckout = () => {
  const made: Array<Record<string, string>> = []
  const sessions = new Map<string, any>()
  const real = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input))
    if (url.hostname !== "api.stripe.com") return real(input, init)
    if ((init?.method ?? "GET") === "POST" && url.pathname === "/v1/checkout/sessions") {
      const form = Object.fromEntries(new URLSearchParams(String(init?.body ?? "")))
      made.push(form)
      const id = `cs_test_${made.length}abc`
      const metadata = Object.fromEntries(Object.entries(form).filter(([k]) => k.startsWith("metadata[")).map(([k, v]) => [k.slice(9, -1), v]))
      sessions.set(id, { id, object: "checkout.session", livemode: false, customer: form.customer ?? `cus_T${made.length}fake`, mode: form.mode, payment_status: "paid", status: "complete", currency: form["line_items[0][price_data][currency]"], amount_subtotal: Number(form["line_items[0][price_data][unit_amount]"]), amount_total: Number(form["line_items[0][price_data][unit_amount]"]), metadata })
      return Response.json({ id, url: `https://checkout.test/pay/${id}` })
    }
    const one = url.pathname.match(/^\/v1\/checkout\/sessions\/(cs_test_[A-Za-z0-9]+)$/)
    if (one && sessions.has(one[1]!)) return Response.json(sessions.get(one[1]!))
    return Response.json({ error: { message: "no fake" } }, { status: 404 })
  })
  return { made, sessions }
}
const signed = async (body: string, secret = WEBHOOK) => {
  const t = Math.floor(Date.now() / 1000)
  return `t=${t},v1=${await hmacHex(secret, `${t}.${body}`)}`
}

afterEach(() => vi.restoreAllMocks())

describe("prepaid Cloud Chief credits", { timeout: 60_000 }, () => {
  it("a team with no credits is refused before the model call, told once with a link, and a paid top-up adds credits once", async () => {
    const { t, team } = await person("credits-topup")
    const e = runEnv()
    const empty = await call(e, "GET", "/v1/credits", { token: t })
    expect(empty.status, empty.text).toBe(200)
    expect(empty.json.value).toMatchObject({ team, balance_usd: 0, available_usd: 0, chiefs: [], topup: { amounts_usd: [10, 20, 50, 100] } })
    expect(empty.json.value.topup.link).toMatch(/^https:\/\/api\.test\/v1\/credits\/checkout\//)
    expect((await call(e, "GET", "/v1/credits")).status).toBe(401)

    const gate = new CreditsGate(e, "brain-a", () => ({ team, chief: "agent_topup", conversation: "conv_topup" }))
    // The in-process test model costs nothing and is never gated; a real model is refused at 0.
    expect(await gate.before("task-1", MODEL, "fake", MESSAGES)).toEqual({ ok: true, skipped: true })
    expect(await gate.before("task-1", MODEL, "claude-opus-5-5", MESSAGES)).toMatchObject({ ok: false, available_usd: 0 })
    expect(await gate.canStart("claude-opus-5-5")).toBe(false)
    const notice = await gate.notice("conv_topup")
    expect(notice).toMatch(/^This team is out of Cloud credits, so I stopped here\. Add credits to continue: https:\/\/api\.test\/v1\/credits\/checkout\//)
    expect(notice).not.toMatch(/stripe/i)
    expect(await gate.notice("conv_topup")).toBeNull()

    // The link opens a payment page for the team (a one-time payment of the default 20 USD).
    const stripe = fakeCheckout()
    const link = new URL(notice!.split(" ").pop()!)
    const go = await call(e, "GET", `${link.pathname}`)
    expect(go.status).toBe(303)
    expect(go.location).toBe("https://checkout.test/pay/cs_test_1abc")
    expect(stripe.made[0]).toMatchObject({ mode: "payment", "line_items[0][price_data][unit_amount]": "2000", "line_items[0][price_data][currency]": "usd", "line_items[0][price_data][product_data][name]": "cmux Cloud credits", "metadata[team]": team, "metadata[kind]": "cmux_credits", client_reference_id: team })
    expect(stripe.made[0]!.success_url).toBe("https://api.test/v1/credits/checkout/done?session_id={CHECKOUT_SESSION_ID}")
    // A team without a customer gets one made by its first payment.
    expect(stripe.made[0]).toMatchObject({ customer_creation: "always" })
    expect(stripe.made[0]!.customer).toBeUndefined()
    // A tampered or foreign link opens nothing.
    expect((await call(e, "GET", `${link.pathname.slice(0, -4)}0000`)).status).toBe(404)

    // The return page reads the session back and adds the paid amount; a reload adds nothing.
    const done = await call(e, "GET", "/v1/credits/checkout/done?session_id=cs_test_1abc")
    expect(done.status, done.text).toBe(200)
    expect(done.text).toContain("20.00 USD of Cloud credits")
    expect((await call(e, "GET", "/v1/credits/checkout/done?session_id=cs_test_1abc")).status).toBe(200)
    // The webhook for the same session is accepted and adds nothing; a bad signature is refused.
    const event = JSON.stringify({ type: "checkout.session.completed", livemode: false, data: { object: stripe.sessions.get("cs_test_1abc") } })
    const hook = await call(e, "POST", "/v1/hooks/stripe/credits", { body: event, headers: { "stripe-signature": await signed(event) } })
    expect(hook.json).toEqual({ received: true, granted: false })
    expect((await call(e, "POST", "/v1/hooks/stripe/credits", { body: event, headers: { "stripe-signature": await signed(event, "whsec_wrong") } })).status).toBe(400)

    // A member's own top-up request (POST /v1/credits/topup) pays through the webhook path alone.
    const mine = await call(e, "POST", "/v1/credits/topup", { token: t, body: JSON.stringify({ usd: 10 }) })
    expect(mine.status, mine.text).toBe(200)
    expect(mine.json.value).toMatchObject({ url: "https://checkout.test/pay/cs_test_2abc", team, usd: 10 })
    // The team's next payment page uses the customer its first payment made (one customer per team).
    expect(stripe.made[1]).toMatchObject({ customer: "cus_T1fake" })
    expect(stripe.made[1]!.customer_creation).toBeUndefined()
    expect((await call(e, "POST", "/v1/credits/topup", { token: t, body: JSON.stringify({ usd: 4 }) })).status).toBe(400)
    const event2 = JSON.stringify({ type: "checkout.session.completed", livemode: false, data: { object: stripe.sessions.get("cs_test_2abc") } })
    expect((await call(e, "POST", "/v1/hooks/stripe/credits", { body: event2, headers: { "stripe-signature": await signed(event2) } })).json).toEqual({ received: true, granted: true })
    // A session whose paid total differs from its price (a discount) grants nothing.
    const discounted = JSON.stringify({ type: "checkout.session.completed", livemode: false, data: { object: { ...stripe.sessions.get("cs_test_2abc"), id: "cs_test_9abc", amount_total: 500 } } })
    expect((await call(e, "POST", "/v1/hooks/stripe/credits", { body: discounted, headers: { "stripe-signature": await signed(discounted) } })).json).toEqual({ received: true, granted: false })

    const after = await call(e, "GET", "/v1/credits", { token: t })
    expect(after.json.value).toMatchObject({ balance_usd: 30, available_usd: 30 })
    expect(after.json.value.entries.map((x: any) => x.kind)).toEqual(["topup", "topup"])
    expect(await gate.canStart("claude-opus-5-5")).toBe(true)
    expect(await gate.before("task-1", MODEL, "claude-opus-5-5", MESSAGES)).toEqual({ ok: true })

    // A test key on production is refused (test payments must not buy real spend), as is a live key anywhere.
    const prod = await call(runEnv({ ENVIRONMENT: "production" }), "GET", link.pathname)
    expect(prod.status, prod.text).toBe(503)
    expect(prod.text).toContain("Billing unavailable")
    // A live key is refused before any payment-service call.
    const live = runEnv({ STRIPE_USAGE_KEY: "sk_live_not_a_real_key" })
    const refused = await call(live, "POST", "/v1/credits/topup", { token: t, body: JSON.stringify({ usd: 10 }) })
    expect(refused.status).toBe(503)
    expect(refused.json.error.code).toBe("billing.unavailable")
    expect(stripe.made).toHaveLength(2)
  })

  it("each model call holds its maximum, is charged its real cost x margin once, and an unsettled hold is charged in full after an hour", async () => {
    const { t, team } = await person("credits-charge")
    const e = runEnv({ CHIEF_CREDITS_MARGIN: "1.5" })
    expect((await admin(e, { action: "grant", stack_user: "credits-charge", usd: 1, actor: "test", reason: "dogfood", key: "g1" }, "wrong-key-0123456789abcdef0123456789")).status).toBe(401)
    const g = await admin(e, { action: "grant", stack_user: "credits-charge", usd: 1, actor: "test", reason: "dogfood", key: "g1" })
    expect(g.json).toMatchObject({ team, added: true, usd: 1, balance_usd: 1 })
    expect((await admin(e, { action: "grant", stack_user: "credits-charge", usd: 1, actor: "test", reason: "dogfood", key: "g1" })).json).toMatchObject({ added: false, balance_usd: 1 })

    const gate = new CreditsGate(e, "brain-b", () => ({ team, chief: "agent_charge", conversation: "conv_charge" }))
    expect(await gate.before("task-1", MODEL, "claude-opus-5-5", MESSAGES)).toEqual({ ok: true })
    const held = (await call(e, "GET", "/v1/credits", { token: t })).json.value
    expect(held.held_usd).toBeGreaterThan(0.0225 - 0.0001)
    expect(held.available_usd).toBeCloseTo(1 - held.held_usd, 6)
    // Real cost 0.02 USD x 1.5; the same terminal message again charges nothing more.
    await gate.after("task-1", answered(0.02))
    await gate.after("task-1", answered(0.02))
    // pi-durable retries call beforeRequest again: a new attempt id, its own hold and charge.
    expect(await gate.before("task-1", MODEL, "claude-opus-5-5", MESSAGES)).toEqual({ ok: true })
    await gate.after("task-1", answered(0.01))
    let b = (await call(e, "GET", "/v1/credits", { token: t })).json.value
    expect(b.balance_usd).toBeCloseTo(1 - 0.03 - 0.015, 6)
    expect(b.held_usd).toBe(0)
    expect(b.chiefs).toEqual([expect.objectContaining({ chief: "agent_charge", spent_usd: 0.045, calls: 2 })])

    // An attempt sent but never answered keeps its hold; the retry holds a new id (two holds open).
    expect(await gate.before("task-3", MODEL, "claude-opus-5-5", MESSAGES)).toEqual({ ok: true })
    expect(await gate.before("task-3", MODEL, "claude-opus-5-5", MESSAGES)).toEqual({ ok: true })
    const two = (await call(e, "GET", "/v1/credits", { token: t })).json.value
    expect(two.held_usd).toBeCloseTo(2 * held.held_usd, 6)
    await gate.after("task-3", answered(0.01))
    // A restarted brain (attempt counter back at 0) does not reuse the earlier attempt's hold.
    const restarted = new CreditsGate(e, "brain-b", () => ({ team, chief: "agent_charge", conversation: "conv_charge" }))
    expect(await restarted.before("task-3", MODEL, "claude-opus-5-5", MESSAGES)).toEqual({ ok: true })
    expect((await call(e, "GET", "/v1/credits", { token: t })).json.value.held_usd).toBeCloseTo(2 * held.held_usd, 6)
    await restarted.after("task-3", answered(0.01))
    await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)), async (m) => m.onWake(Date.now() + 2 * 3600_000))
    const lostHold = held.held_usd
    // A call whose maximum is above the available balance is refused (nothing is sent).
    const big = { ...MODEL, maxTokens: 100_000 }
    expect(await gate.before("task-2", big, "claude-opus-5-5", MESSAGES)).toMatchObject({ ok: false })

    // A hold never settled (the brain was evicted mid-call) is charged in full by the alarm; the late settle corrects it.
    const lost = new CreditsGate(e, "brain-c", () => ({ team, chief: "agent_charge", conversation: "conv_charge" }))
    expect(await lost.before("task-9", MODEL, "claude-opus-5-5", MESSAGES)).toEqual({ ok: true })
    const holdUsd = (await call(e, "GET", "/v1/credits", { token: t })).json.value.held_usd as number
    await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)), async (m) => m.onWake(Date.now() + 2 * 3600_000))
    b = (await call(e, "GET", "/v1/credits", { token: t })).json.value
    expect(b.held_usd).toBe(0)
    // So far: 0.045 (task-1), 2 x 0.015 (task-3's answered attempts), task-3's lost attempt in full.
    expect(b.balance_usd).toBeCloseTo(1 - 0.075 - lostHold - holdUsd, 6)
    expect(b.entries[0]).toMatchObject({ kind: "expired", usd: -holdUsd })
    await lost.after("task-9", answered(0.004))
    b = (await call(e, "GET", "/v1/credits", { token: t })).json.value
    expect(b.balance_usd).toBeCloseTo(1 - 0.075 - lostHold - 0.006, 6)
    expect(b.chiefs[0]).toMatchObject({ chief: "agent_charge", calls: 6 })
    expect(b.chiefs[0].spent_usd).toBeCloseTo(0.081 + lostHold, 6)
  })

  it("production always enforces credits, even when CHIEF_CREDITS_ENFORCE says 0; other deployments may turn the gate off", async () => {
    const { team } = await person("credits-prod-enforce")
    const who = () => ({ team, chief: "agent_prod", conversation: "conv_prod" })
    // Staging with the gate off: an empty team's call passes (nothing is held).
    const off = new CreditsGate(runEnv({ CHIEF_CREDITS_ENFORCE: "0", ENVIRONMENT: "staging" }), "brain-p1", who)
    expect(await off.before("task-1", MODEL, "claude-opus-5-5", MESSAGES)).toEqual({ ok: true, skipped: true })
    expect(await off.canStart("claude-opus-5-5")).toBe(true)
    // Production with the same var: the empty team is refused before any provider call, and told once.
    const prod = new CreditsGate(runEnv({ CHIEF_CREDITS_ENFORCE: "0", ENVIRONMENT: "production" }), "brain-p2", who)
    expect(await prod.before("task-1", MODEL, "claude-opus-5-5", MESSAGES)).toMatchObject({ ok: false, available_usd: 0 })
    expect(await prod.canStart("claude-opus-5-5")).toBe(false)
    expect(await prod.notice("conv_prod")).toMatch(/^This team is out of Cloud credits/)
    // Once the team has credits, production holds and charges like everywhere else.
    expect((await admin(runEnv(), { action: "grant", team, usd: 5, actor: "test", reason: "prod enforce test", key: "prod-enforce-1" })).json).toMatchObject({ added: true })
    expect(await prod.before("task-1", MODEL, "claude-opus-5-5", MESSAGES)).toEqual({ ok: true })
    await prod.after("task-1", answered(0.01))
    expect((await admin(runEnv(), { action: "read", team })).json.balance_usd).toBeCloseTo(4.99, 6)
  })

  it("the mirror to the billing database sends each entry once, marks it only after the database took it, and backs off on failure", async () => {
    const { t, team } = await person("credits-mirror")
    const e = runEnv()
    expect((await admin(e, { action: "grant", team, usd: 2, actor: "test", reason: "mirror test", key: "m1" })).json).toMatchObject({ added: true })
    const gate = new CreditsGate(e, "brain-m", () => ({ team, chief: "agent_mirror", conversation: "conv_mirror" }))
    expect(await gate.before("task-1", MODEL, "claude-opus-5-5", MESSAGES)).toEqual({ ok: true })
    await gate.after("task-1", answered(0.01))
    const sent: Array<[string, Array<unknown>]> = []
    const ok = { query: async (q: string, v?: Array<unknown>) => void sent.push([q, v ?? []]) }
    const down = { query: async () => { throw Object.assign(new Error("connect ETIMEDOUT"), { code: "ETIMEDOUT" }) } }
    await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)), async (m) => {
      const storage = m.ctx.storage as DurableObjectStorage
      expect(mirrorDue(storage.sql)).not.toBeNull()
      // The database is down: nothing is marked, the next try waits.
      await expect(mirrorCredits(storage, team, down)).rejects.toThrow()
      const now = Date.now()
      expect(mirrorFailed(storage.sql, now)).toBe(1)
      expect(mirrorDue(storage.sql)).toBe(now + 5_000)
      expect(mirrorFailed(storage.sql, now)).toBe(2)
      expect(mirrorDue(storage.sql)).toBe(now + 10_000)
      // It is back: both entries go in seq order, with the balance at the state's version.
      const r = await mirrorCredits(storage, team, ok)
      expect(r.entries).toBe(2)
      expect(sent[0]![0]).toMatch(/^INSERT INTO credit_ledger .* ON DUPLICATE KEY UPDATE `entry_key` = IF\(`entry_key` = VALUES\(`entry_key`\), `entry_key`, NULL\)$/)
      expect(sent[0]![1].filter((_, i) => i % 12 === 1)).toEqual(["grant:m1", "charge:brain-m:task-1:0"])
      expect(sent[0]![1].filter((_, i) => i % 12 === 11)).toEqual([1, 2])
      expect(sent[1]![0]).toMatch(/^INSERT INTO credit_balance /)
      expect(sent[1]![1].slice(0, 3)).toEqual([team, 2_000_000 - 10_000, 0])
      expect(mirrorDue(storage.sql)).toBeNull()
      // Nothing new: a later run sends no ledger rows again.
      sent.length = 0
      await mirrorCredits(storage, team, ok)
      expect(sent.some(([q]) => q.includes("credit_ledger"))).toBe(false)
    })
    // A new hold is a change the mirror carries (the balance row's held amount), with no new ledger row.
    expect(await gate.before("task-2", MODEL, "claude-opus-5-5", MESSAGES)).toEqual({ ok: true })
    await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)), async (m) => {
      const storage = m.ctx.storage as DurableObjectStorage
      expect(mirrorDue(storage.sql)).not.toBeNull()
      sent.length = 0
      expect((await mirrorCredits(storage, team, ok)).entries).toBe(0)
      expect(sent.map(([q]) => q.split(" ").slice(0, 3).join(" "))).toEqual(["INSERT INTO credit_balance"])
      expect(Number(sent[0]![1][2])).toBeGreaterThan(0)
    })
    expect((await call(e, "GET", "/v1/credits", { token: t })).json.value.balance_usd).toBeCloseTo(1.99, 6)
  })

  it("a team whose mirror starts after rows were pruned gets one opening entry, so the mirrored ledger sums to its balance", async () => {
    const { team } = await person("credits-opening")
    const e = runEnv()
    expect((await admin(e, { action: "grant", team, usd: 3, actor: "test", reason: "opening test", key: "o1" })).json).toMatchObject({ added: true })
    const gate = new CreditsGate(e, "brain-o", () => ({ team, chief: "agent_open", conversation: "conv_open" }))
    expect(await gate.before("task-1", MODEL, "claude-opus-5-5", MESSAGES)).toEqual({ ok: true })
    await gate.after("task-1", answered(0.5))
    const sent: Array<[string, Array<unknown>]> = []
    const ok = { query: async (q: string, v?: Array<unknown>) => void sent.push([q, v ?? []]) }
    await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)), async (m) => {
      const storage = m.ctx.storage as DurableObjectStorage
      // The charge row left the hot copy before any mirror ran (the 400-day prune with the mirror off).
      storage.sql.exec(`DELETE FROM credit_entry WHERE kind = 'charge'`)
      const r = await mirrorCredits(storage, team, ok)
      expect(r.entries).toBe(2)
      const rows = sent[0]![1]
      const keys = rows.filter((_, i) => i % 12 === 1)
      const micros = rows.filter((_, i) => i % 12 === 3).map(Number)
      expect(keys).toEqual(["grant:o1", "opening:3"])
      expect(micros).toEqual([3_000_000, -500_000])
      expect(micros.reduce((x, y) => x + y, 0)).toBe(Number(sent[1]![1][1]))
      // Only once: a later run adds no second opening entry.
      sent.length = 0
      await mirrorCredits(storage, team, ok)
      expect(sent.some(([q]) => q.includes("credit_ledger"))).toBe(false)
    })
    // The balance itself never moved, and the opening entry is not a chief's spend.
    const b = (await call(e, "GET", "/v1/credits", { token: (await token("credits-opening")) })).json.value
    expect(b.balance_usd).toBeCloseTo(2.5, 6)
    expect(b.chiefs).toEqual([])
  })

  it("the operator's dogfood grant gives each configured team its amount once per round", async () => {
    const a = await person("credits-dogfood-a")
    const b = await person("credits-dogfood-b")
    const e = runEnv({ CHIEF_CREDITS_DOGFOOD: `${a.team}, ${b.user}, bogus`, CHIEF_CREDITS_DOGFOOD_USD: "25" })
    const first = await admin(e, { action: "dogfood", actor: "test" })
    expect(first.status, first.text).toBe(200)
    expect(first.json.grants).toEqual([expect.objectContaining({ team: a.team, added: true, usd: 25 }), expect.objectContaining({ team: b.team, added: true, usd: 25 })])
    expect((await admin(e, { action: "dogfood", actor: "test" })).json.grants.map((x: any) => x.added)).toEqual([false, false])
    expect((await admin(runEnv({ ...e, CHIEF_CREDITS_DOGFOOD: a.team, CHIEF_CREDITS_DOGFOOD_USD: "25", CHIEF_CREDITS_DOGFOOD_ROUND: "2" }), { action: "dogfood", actor: "test" })).json.grants[0]).toMatchObject({ added: true, balance_usd: 50 })
    expect((await admin(e, { action: "read", user: b.user })).json).toMatchObject({ team: b.team, balance_usd: 25 })
    expect((await call(e, "GET", "/v1/credits", { token: b.t })).json.value.entries[0]).toMatchObject({ kind: "grant", usd: 25, reason: "dogfood round 1" })
  })
})
