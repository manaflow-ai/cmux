import { env } from "cloudflare:workers"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import worker from "../src/index.ts"
import { afterEach, describe, expect, it, vi } from "vitest"
import { chat, inDO, loopback, paidPerson, post, testEnv } from "./setup/inference-person.ts"

/**
 * cx-y79zh S1 (plans/cmux-next/usage-billing.md): one model router call is one fact, and the member's
 * monthly spend and the team's model spend read that same fact. Driven at the route
 * (POST /v1/inference/chat/completions) with the provider faked at its HTTP boundary.
 */

/** The provider's chat/completions endpoint answers `reply`; every other request goes out as usual. */
const fakeProvider = (reply: () => Response) => {
  const real = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input instanceof Request ? input.url : String(input)
    return url.startsWith("https://openrouter.ai/") ? reply() : real(input, init)
  })
}

const counters = async (t: string, team: string, user: string) => {
  const summary = await post("/v1/read", t, { op: "usage.summary", params: {} })
  const model = summary.value.meters.find((m: any) => m.meter === "model.spend_usd")
  const spends = await (testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)) as any).userSpends(team, [user])
  let facts: Array<{ key: string; user: string | null; quantity: number; source: string }> = []
  await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)), async (m) => {
    facts = m.ctx.storage.sql.exec(`SELECT key, user, quantity, source FROM usage_ledger WHERE meter = 'model.spend_usd'`).toArray()
  })
  return { team_usd: model.usd as number, member_usd: spends[user] as number, facts }
}

/** The provider answers only when the test releases it; `asked` resolves when the request arrived. */
const heldProvider = (reply: () => Response) => {
  const real = globalThis.fetch
  let release!: () => void
  let arrived!: () => void
  const gate = new Promise<void>((r) => (release = r))
  const asked = new Promise<void>((r) => (arrived = r))
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input instanceof Request ? input.url : String(input)
    if (!url.startsWith("https://openrouter.ai/")) return real(input, init)
    arrived()
    await gate
    return reply()
  })
  return { asked, release }
}

const LEVELS_KEY = "test-billing-levels-key-0123456789abcdef"
/** The reconcile worker's read: POST /v1/internal/billing/levels. */
const levels = async (items: unknown, key = LEVELS_KEY) => {
  const res = await loopback.fetch("https://api.test/v1/internal/billing/levels", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${key}` }, body: JSON.stringify({ items }) })
  return { status: res.status, body: (await res.json()) as any }
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe("model router spend is one fact (cx-y79zh S1)", () => {
  it("a settled call writes one fact that the member spend and the team spend both count", async () => {
    const { t, team, user } = await paidPerson("spend-facts-settled")
    fakeProvider(() => Response.json({ id: "x", choices: [{ index: 0, message: { role: "assistant", content: "hello" } }], usage: { prompt_tokens: 10, completion_tokens: 5, cost: 0.000012 } }))
    const r = await chat(t)
    expect(r.status).toBe(200)
    const c = await counters(t, team, user)
    expect(c.facts).toHaveLength(1)
    expect(c.facts[0]).toMatchObject({ user, quantity: 0.000012, source: "coderouter" })
    expect(c.member_usd).toBeCloseTo(0.000012, 9)
    expect(c.team_usd).toBeCloseTo(0.000012, 9)
  })

  it("a call the provider may have billed (a broken body) is charged in full on both counters", async () => {
    const { t, team, user } = await paidPerson("spend-facts-charged")
    fakeProvider(() => new Response("not json", { status: 200, headers: { "content-type": "application/json" } }))
    const r = await chat(t)
    expect(r.status).toBe(502)
    const c = await counters(t, team, user)
    expect(c.facts).toHaveLength(1)
    expect(c.facts[0]).toMatchObject({ user, source: "coderouter" })
    expect(c.member_usd).toBeGreaterThan(0)
    // Before S1 the team counter stayed at 0 here: the member and the team disagreed.
    expect(c.team_usd).toBeCloseTo(c.member_usd, 6)
    expect(c.facts[0]!.quantity).toBeCloseTo(c.member_usd, 6)
  })

  it("a billable fact outlives the 35-day dedupe window (S2: nothing deletes a bill's input)", async () => {
    const { t, team, user } = await paidPerson("spend-facts-kept")
    fakeProvider(() => Response.json({ id: "x", choices: [{ index: 0, message: { role: "assistant", content: "kept" } }], usage: { prompt_tokens: 10, completion_tokens: 5, cost: 0.000004 } }))
    expect((await chat(t)).status).toBe(200)
    const stub = testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)) as any
    await stub.record(team, [{ key: "step:run_kept:s1", meter: "automation.steps", quantity: 1, source: "step", observed_at: Date.now() }])
    // The alarm 40 days later prunes old dedupe keys (the step row); the call's money fact stays.
    let steps = -1
    await inDO(stub, async (m) => {
      await m.onWake(Date.now() + 40 * 86_400_000)
      steps = Number(m.ctx.storage.sql.exec(`SELECT COUNT(*) AS n FROM usage_ledger WHERE meter = 'automation.steps'`).one().n)
    })
    expect(steps).toBe(0)
    const c = await counters(t, team, user)
    expect(c.facts).toHaveLength(1)
    expect(c.facts[0]).toMatchObject({ user, quantity: 0.000004, source: "coderouter" })
  })

  it("a reservation that expires is charged in full, and a late settle is a correction fact on both counters", async () => {
    const { t, team, user } = await paidPerson("spend-facts-late")
    const held = heldProvider(() => Response.json({ id: "x", choices: [{ index: 0, message: { role: "assistant", content: "late" } }], usage: { prompt_tokens: 10, completion_tokens: 5, cost: 0.000003 } }))
    const call = chat(t)
    await held.asked
    // The alarm runs past the reservation TTL while the provider has not answered yet.
    await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)), async (m) => m.onWake(Date.now() + 2 * 3600_000))
    const expired = await counters(t, team, user)
    expect(expired.facts.map((f) => f.source)).toEqual(["coderouter.expired"])
    expect(expired.team_usd).toBeCloseTo(expired.member_usd, 9)
    expect(expired.member_usd).toBeGreaterThan(0.000003)
    held.release()
    expect((await call).status).toBe(200)
    const settled = await counters(t, team, user)
    expect(settled.facts.map((f) => f.source).sort()).toEqual(["coderouter.expired", "coderouter.late"])
    expect(settled.facts.every((f) => f.user === user)).toBe(true)
    expect(settled.member_usd).toBeCloseTo(0.000003, 9)
    expect(settled.team_usd).toBeCloseTo(0.000003, 9)
    // The bill's level reads the same facts: the expired charge plus its correction is the real cost.
    // The expired fact is recorded at the alarm's time (2 h ahead in this test), so the window covers it.
    const l = await levels([{ stack_user: "spend-facts-late", from: 0, to: Date.now() + 3 * 3600_000 }])
    expect(l.body.levels[0]).toMatchObject({ team, micros: 3, facts: 2, price_version: "ai-passthrough-v1" })
  })

  it("the billing level of a period is the sum of the facts recorded in it, read with the service key only", async () => {
    const { t, team } = await paidPerson("spend-facts-level")
    const before = Date.now()
    fakeProvider(() => Response.json({ id: "x", choices: [{ index: 0, message: { role: "assistant", content: "a" } }], usage: { prompt_tokens: 10, completion_tokens: 5, cost: 0.000005 } }))
    expect((await chat(t)).status).toBe(200)
    expect((await chat(t)).status).toBe(200)
    const after = Date.now() + 1
    const r = await levels([
      { stack_user: "spend-facts-level", from: before, to: after },
      { stack_user: "spend-facts-level", from: 0, to: before },
      { stack_team: "no-such-team", from: before, to: after }
    ])
    expect(r.status).toBe(200)
    expect(r.body.levels[0]).toMatchObject({ team, micros: 10, facts: 2 })
    expect(r.body.levels[1]).toMatchObject({ team, micros: 0, facts: 0, last_at: null })
    expect(r.body.levels[2]).toMatchObject({ micros: 0, facts: 0 })
    // Asking twice gives the same level (the worker sends levels, never deltas).
    expect((await levels([{ stack_user: "spend-facts-level", from: before, to: after }])).body.levels[0].micros).toBe(10)
    expect((await levels([{ stack_user: "spend-facts-level", from: before, to: after }], "wrong-key-0123456789abcdef0123456789")).status).toBe(401)
    expect((await levels([{ stack_user: "x", stack_team: "y", from: 0, to: 1 }])).status).toBe(400)
  })
})

// One file on purpose: these tests replace globalThis.fetch, which test files share in this pool.
/**
 * cx-y79zh S4 (plans/cmux-next/usage-billing.md section 3): the usage sync in the API Worker, driven
 * at its route POST /v1/internal/billing/sync with the payment service faked at its HTTP boundary
 * (api.stripe.com) and the model provider faked as above.
 */

const SYNC_KEY = "test-billing-levels-key-0123456789abcdef"
const USAGE_PRICES: Record<string, string> = { "cmux-ai-usage-go-incl5-v1": "price_u_go", "cmux-ai-usage-pro-incl20-v1": "price_u_pro", "cmux-ai-usage-max-incl100-v1": "price_u_max", "cmux-ai-usage-team-incl20-v1": "price_u_team" }

type Call = { method: string; path: string; form: Record<string, string>; idempotency: string | null; version: string | null }
type FakeSub = { id: string; status: string; customer: string; metadata: Record<string, string>; items: { data: Array<any> } }

/** An in-memory payment service: prices by lookup key, subscriptions, subscription items, meter events. */
const fakeStripe = (period: { start: number; end: number }) => {
  const calls: Call[] = []
  const events: Array<Record<string, string>> = []
  const subs: FakeSub[] = []
  const seen = new Map<string, unknown>()
  const addSub = (id: string, customer: string, metadata: Record<string, string>, planLookup: string, extra: Array<any> = []) => {
    const sub: FakeSub = { id, status: "active", customer, metadata: { app: "cmux", ...metadata }, items: { data: [{ id: `si_plan_${id}`, quantity: 1, price: { id: `price_plan_${id}`, product: "prod_plan", lookup_key: planLookup, recurring: { interval: "month" } } }, ...extra] } }
    subs.push(sub)
    return sub
  }
  const withPeriod = (sub: FakeSub) => ({ ...structuredClone(sub), items: { data: sub.items.data.map((i) => ({ ...structuredClone(i), current_period_start: period.start, current_period_end: period.end })) } })
  const handle = async (url: URL, init: RequestInit): Promise<Response> => {
    const method = (init.method ?? "GET").toUpperCase()
    const form = Object.fromEntries(new URLSearchParams(typeof init.body === "string" ? init.body : ""))
    const headers = new Headers(init.headers)
    const idempotency = headers.get("idempotency-key")
    calls.push({ method, path: url.pathname, form, idempotency, version: headers.get("stripe-version") })
    if (idempotency && seen.has(idempotency)) return Response.json(seen.get(idempotency))
    const ok = (body: unknown) => {
      if (idempotency) seen.set(idempotency, body)
      return Response.json(body)
    }
    if (method === "GET" && url.pathname === "/v1/prices") return ok({ data: url.searchParams.getAll("lookup_keys[]").filter((k) => USAGE_PRICES[k]).map((k) => ({ id: USAGE_PRICES[k], lookup_key: k })) })
    if (method === "GET" && url.pathname === "/v1/subscriptions") return ok({ data: subs.filter((x) => x.status === url.searchParams.get("status")).map(withPeriod), has_more: false })
    if (method === "POST" && url.pathname === "/v1/subscription_items") {
      const item = { id: `si_usage_${form.subscription}`, price: { id: form.price, product: "cmux_ai_usage", recurring: { interval: "month" } } }
      subs.find((x) => x.id === form.subscription)!.items.data.push(item)
      return ok({ ...item, current_period_start: period.start, current_period_end: period.end })
    }
    const moved = url.pathname.match(/^\/v1\/subscription_items\/(.+)$/)
    if (method === "POST" && moved) {
      const item = subs.flatMap((x) => x.items.data).find((i) => i.id === moved[1])
      item.price = { ...item.price, id: form.price }
      return ok({ ...structuredClone(item), current_period_start: period.start, current_period_end: period.end })
    }
    if (method === "POST" && url.pathname === "/v1/billing/meter_events") {
      events.push(form)
      return ok({ object: "billing.meter_event", identifier: form.identifier })
    }
    return Response.json({ error: { code: "resource_missing", message: `no fake for ${method} ${url.pathname}` } }, { status: 404 })
  }
  return { calls, events, subs, addSub, period, handle }
}

/** Fakes both boundaries: the model provider answers `cost`, the payment service is `stripe`. */
const fakeBoundaries = (stripe: ReturnType<typeof fakeStripe>, cost: number) => {
  const real = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input))
    if (url.hostname === "api.stripe.com") return stripe.handle(url, init ?? {})
    if (url.hostname === "openrouter.ai") return Response.json({ id: "x", choices: [{ index: 0, message: { role: "assistant", content: "ok" } }], usage: { prompt_tokens: 10, completion_tokens: 5, cost } })
    return real(input, init)
  })
}

/** One usage sync run through the Worker's fetch handler (POST /v1/internal/billing/sync). */
const sync = async (runEnv: unknown = env, body = "{}") => {
  const ctx = createExecutionContext()
  const res = await worker.fetch!(new Request("https://api.test/v1/internal/billing/sync", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${SYNC_KEY}` }, body }) as any, runEnv as any, ctx)
  const out = (await res.json()) as any
  await waitOnExecutionContext(ctx)
  return { status: res.status, body: out }
}

const nowS = () => Math.floor(Date.now() / 1000)
/** No call of the run wrote a plan item or named a plan price. */
const planItemsUntouched = (stripe: ReturnType<typeof fakeStripe>) => stripe.calls.every((c) => !c.path.includes("si_plan") && !Object.values(c.form).some((v) => v.startsWith("price_plan")))

describe("usage sync (cx-y79zh S4)", () => {
  it("refuses a live payment key before any call to the payment service", async () => {
    const stripe = fakeStripe({ start: 1, end: 2 })
    fakeBoundaries(stripe, 0)
    for (const live of ["sk_live_0123456789abcdef", "rk_live_0123456789abcdef"]) {
      const r = await sync({ ...(env as object), STRIPE_USAGE_KEY: live })
      expect(r.status).toBe(409)
      expect(r.body).toMatchObject({ mode: "live", refused: "live_key", checked: 0, pushed: 0 })
    }
    expect(stripe.calls).toHaveLength(0)
    expect((await sync(env, "null")).status).toBe(400)
  })

  it("adds the usage item once, never changes the plan item, and sends each new level once", async () => {
    const { t } = await paidPerson("usage-sync-person")
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 })
    stripe.addSub("sub_p1", "cus_p1", { plan: "pro", stackUserId: "usage-sync-person" }, "cmux-pro-monthly-50")
    fakeBoundaries(stripe, 0.000007)
    expect((await chat(t)).status).toBe(200)

    const first = await sync()
    expect(first.body).toMatchObject({ mode: "test", checked: 1, items_added: 1, pushed: 1, failed: 0 })
    expect(stripe.calls.filter((c) => c.path === "/v1/subscription_items")).toEqual([expect.objectContaining({ idempotency: "usage-item:sub_p1:price_u_pro", form: expect.objectContaining({ subscription: "sub_p1", price: "price_u_pro" }) })])
    expect(stripe.events).toEqual([expect.objectContaining({ event_name: "cmux_ai_usage", "payload[stripe_customer_id]": "cus_p1", "payload[value]": "0.000007" })])

    const second = await sync()
    expect(second.body).toMatchObject({ checked: 1, items_added: 0, pushed: 0, unchanged: 1 })
    expect(stripe.events).toHaveLength(1)

    expect((await chat(t)).status).toBe(200)
    const third = await sync()
    expect(third.body).toMatchObject({ pushed: 1, items_added: 0 })
    expect(stripe.events[1]!["payload[value]"]).toBe("0.000014")
    expect(stripe.events[1]!.identifier).not.toBe(stripe.events[0]!.identifier)
    expect(stripe.calls.filter((c) => c.path === "/v1/billing/meter_events").every((c) => c.idempotency === c.form.identifier)).toBe(true)
    expect(stripe.calls.every((c) => c.version === "2026-06-24.dahlia")).toBe(true)
    expect(planItemsUntouched(stripe)).toBe(true)
  })

  it("reads the plan from the plan item, moves a usage item to the right plan's price, and skips a customer with two subscriptions", async () => {
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 })
    // Upgraded to Max in the portal: the metadata still says pro, the plan item says max.
    stripe.addSub("sub_m1", "cus_m1", { plan: "pro", stackUserId: "usage-sync-max" }, "cmux-max-monthly-200", [{ id: "si_usage_m1", price: { id: "price_u_pro", product: "cmux_ai_usage", recurring: { interval: "month" } } }])
    stripe.addSub("sub_d1", "cus_dup", { plan: "pro", stackUserId: "usage-sync-dup-a" }, "cmux-pro-monthly-50")
    stripe.addSub("sub_d2", "cus_dup", { plan: "pro", stackUserId: "usage-sync-dup-b" }, "cmux-pro-monthly-50")
    fakeBoundaries(stripe, 0)
    const r = await sync()
    expect(r.body).toMatchObject({ checked: 3, items_moved: 1, items_added: 0, skipped: 2, failed: 0 })
    const writes = stripe.calls.filter((c) => c.method === "POST")
    expect(writes).toEqual([expect.objectContaining({ path: "/v1/subscription_items/si_usage_m1", form: expect.objectContaining({ price: "price_u_max" }) })])
    expect(planItemsUntouched(stripe)).toBe(true)
  })

  it("after a renewal, the closed period gets its final level once more, dated inside that period", async () => {
    const { t } = await paidPerson("usage-sync-renew")
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 120 })
    stripe.addSub("sub_r1", "cus_r1", { plan: "pro", stackUserId: "usage-sync-renew" }, "cmux-pro-monthly-50")
    fakeBoundaries(stripe, 0.000005)
    expect((await chat(t)).status).toBe(200)
    expect((await sync()).body).toMatchObject({ pushed: 1 })
    // Usage in the last minutes of the period, then the renewal before the next run.
    expect((await chat(t)).status).toBe(200)
    const closedEnd = stripe.period.end
    stripe.period.start = closedEnd
    stripe.period.end = closedEnd + 30 * 86_400
    const after = await sync()
    expect(after.body).toMatchObject({ pushed: 1, failed: 0 })
    expect(stripe.events).toHaveLength(2)
    expect(stripe.events[1]).toMatchObject({ "payload[value]": "0.000010" })
    expect(Number(stripe.events[1]!.timestamp)).toBeLessThan(closedEnd)
  })
})
