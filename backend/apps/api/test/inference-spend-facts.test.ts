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
 * (api.stripe.com) and the model provider faked as in inference-spend-facts.test.ts.
 */

const PLAN_PRICE = "price_plan_pro"
const USAGE_PRICES: Record<string, string> = { "cmux-ai-usage-go-incl5-v1": "price_u_go", "cmux-ai-usage-pro-incl20-v1": "price_u_pro", "cmux-ai-usage-max-incl100-v1": "price_u_max", "cmux-ai-usage-team-incl20-v1": "price_u_team" }

type Call = { method: string; path: string; form: Record<string, string>; idempotency: string | null }

/** An in-memory payment service: prices by lookup key, one subscription, subscription items, meter events. */
const fakeStripe = (stackUser: string, period: { start: number; end: number }) => {
  const calls: Call[] = []
  const events: Array<Record<string, string>> = []
  const sub = {
    id: "sub_test_1",
    status: "active",
    customer: "cus_test_1",
    metadata: { app: "cmux", plan: "pro", stackUserId: stackUser },
    items: { data: [{ id: "si_plan", quantity: 1, price: { id: PLAN_PRICE, product: "prod_pro" }, current_period_start: period.start, current_period_end: period.end }] as Array<any> }
  }
  const seenIdempotency = new Map<string, unknown>()
  const handle = async (url: URL, init: RequestInit): Promise<Response> => {
    const method = (init.method ?? "GET").toUpperCase()
    const form = Object.fromEntries(new URLSearchParams(typeof init.body === "string" ? init.body : ""))
    const idempotency = new Headers(init.headers).get("idempotency-key")
    calls.push({ method, path: url.pathname, form, idempotency })
    if (idempotency && seenIdempotency.has(idempotency)) return Response.json(seenIdempotency.get(idempotency))
    const ok = (body: unknown) => {
      if (idempotency) seenIdempotency.set(idempotency, body)
      return Response.json(body)
    }
    if (method === "GET" && url.pathname === "/v1/prices") {
      const keys = url.searchParams.getAll("lookup_keys[]")
      return ok({ data: keys.filter((k) => USAGE_PRICES[k]).map((k) => ({ id: USAGE_PRICES[k], lookup_key: k })) })
    }
    if (method === "GET" && url.pathname === "/v1/subscriptions") return ok({ data: [structuredClone(sub)], has_more: false })
    if (method === "POST" && url.pathname === "/v1/subscription_items") {
      const item = { id: "si_usage", price: { id: form.price, product: "cmux_ai_usage" }, current_period_start: period.start, current_period_end: period.end }
      sub.items.data.push(item)
      return ok(item)
    }
    if (method === "POST" && url.pathname === "/v1/billing/meter_events") {
      events.push(form)
      return ok({ object: "billing.meter_event", identifier: form.identifier })
    }
    return Response.json({ error: { code: "resource_missing", message: `no fake for ${method} ${url.pathname}` } }, { status: 404 })
  }
  return { calls, events, sub, handle }
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
const sync = async (runEnv: unknown = env) => {
  const ctx = createExecutionContext()
  const res = await worker.fetch!(new Request("https://api.test/v1/internal/billing/sync", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${LEVELS_KEY}` }, body: "{}" }) as any, runEnv as any, ctx)
  const body = (await res.json()) as any
  await waitOnExecutionContext(ctx)
  return { status: res.status, body }
}

describe("usage sync (cx-y79zh S4)", () => {
  it("refuses a live payment key before any call to the payment service", async () => {
    const stripe = fakeStripe("usage-sync-live", { start: 1, end: 2 })
    fakeBoundaries(stripe, 0)
    for (const live of ["sk_live_0123456789abcdef", "rk_live_0123456789abcdef"]) {
      const r = await sync({ ...(env as object), STRIPE_USAGE_KEY: live })
      expect(r.status).toBe(409)
      expect(r.body).toMatchObject({ mode: "live", refused: "live_key", checked: 0, pushed: 0 })
    }
    expect(stripe.calls).toHaveLength(0)
  })

  it("adds the usage item once, never changes the plan item, and sends each new level once", async () => {
    const stackUser = "usage-sync-person"
    const { t } = await paidPerson(stackUser)
    const now = Math.floor(Date.now() / 1000)
    const stripe = fakeStripe(stackUser, { start: now - 3600, end: now + 30 * 86_400 })
    fakeBoundaries(stripe, 0.000007)
    expect((await chat(t)).status).toBe(200)

    const first = await sync()
    expect(first.status).toBe(200)
    expect(first.body).toMatchObject({ mode: "test", checked: 1, items_added: 1, pushed: 1, failed: 0 })
    const added = stripe.calls.filter((c) => c.path === "/v1/subscription_items")
    expect(added).toEqual([expect.objectContaining({ method: "POST", idempotency: `usage-item:sub_test_1:price_u_pro`, form: expect.objectContaining({ subscription: "sub_test_1", price: "price_u_pro" }) })])
    // The plan item is never written: no call names si_plan or the plan price.
    expect(stripe.calls.some((c) => c.path.includes("si_plan") || Object.values(c.form).includes(PLAN_PRICE))).toBe(false)
    expect(stripe.events).toHaveLength(1)
    expect(stripe.events[0]).toMatchObject({ event_name: "cmux_ai_usage", "payload[stripe_customer_id]": "cus_test_1", "payload[value]": "0.000007" })

    // Nothing changed: no new item, no new event.
    const second = await sync()
    expect(second.body).toMatchObject({ checked: 1, items_added: 0, pushed: 0, unchanged: 1 })
    expect(stripe.events).toHaveLength(1)

    // A new fact: the new period level (the whole level, not a delta) is sent with a new identifier.
    expect((await chat(t)).status).toBe(200)
    const third = await sync()
    expect(third.body).toMatchObject({ pushed: 1, items_added: 0 })
    expect(stripe.events).toHaveLength(2)
    expect(stripe.events[1]!["payload[value]"]).toBe("0.000014")
    expect(stripe.events[1]!.identifier).not.toBe(stripe.events[0]!.identifier)
    expect(stripe.calls.filter((c) => c.path === "/v1/billing/meter_events").every((c) => c.idempotency === c.form.identifier)).toBe(true)
  })
})
