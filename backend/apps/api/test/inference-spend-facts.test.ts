import { env } from "cloudflare:workers"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import worker from "../src/index.ts"
import { afterEach, describe, expect, it, vi } from "vitest"
import { chat, inDO, loopback, paidPerson, post, testEnv } from "./setup/inference-person.ts"
import { personalTeamIdFor, stackTeamIdFor, userIdFor } from "../src/domains/user.ts"
import { fakeBoundaries, fakeStripe, nowS, sync, SYNC_KEY } from "./setup/fake-stripe.ts"
import { handleBillingTeamMode } from "../src/billing-team-mode.ts"
import { handleBillingLevels } from "../src/billing-levels.ts"

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
    // One subscription's run (the invoice-created trigger) still sees the customer's other subscription.
    const one = await sync(env, JSON.stringify({ subscription: "sub_d1" }))
    expect(one.body).toMatchObject({ checked: 1, skipped: 1, pushed: 0, items_added: 0 })
    expect(stripe.calls.filter((c) => c.method === "POST")).toHaveLength(1)
  })

  it("uses the e2e price set only on the development Worker that asks for it", async () => {
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 })
    stripe.addSub("sub_e1", "cus_e1", { plan: "pro", stackUserId: "usage-sync-e2e" }, "cmux-pro-monthly-50")
    fakeBoundaries(stripe, 0)
    // Another environment with the same var keeps the v1 prices.
    expect((await sync({ ...(env as object), ENVIRONMENT: "staging", BILLING_USAGE_PRICE_SET: "e2e" })).body).toMatchObject({ items_added: 1 })
    expect(stripe.calls.filter((c) => c.method === "POST").map((c) => c.form.price)).toEqual(["price_u_pro"])
    // Development with the var moves the usage item to the e2e price; the plan item stays.
    expect((await sync({ ...(env as object), ENVIRONMENT: "development", BILLING_USAGE_PRICE_SET: "e2e" })).body).toMatchObject({ items_moved: 1 })
    expect(stripe.calls.filter((c) => c.method === "POST").map((c) => c.form.price)).toEqual(["price_u_pro", "price_e2e_pro"])
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

describe("the included-amount stop (cx-y79zh S5)", () => {
  const stopOn = { ...(env as object), USAGE_HARD_STOP_UNBILLED: "1" }
  const spend = async (team: string, usd: number) =>
    (testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)) as any).record(team, [{ key: `seed:${crypto.randomUUID()}`, meter: "model.spend_usd", quantity: usd, source: "coderouter", observed_at: Date.now() }])

  it("stops a team that cannot be billed at its plan's included amount, and lets it go once it is billable", async () => {
    const stackUser = "included-stop-pro"
    const { t, team } = await paidPerson(stackUser)
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 })
    fakeBoundaries(stripe, 0.000001)
    await spend(team, 19.99999)
    // Off by default: the member limit (200) is the only brake, as before.
    expect((await chat(t)).status).toBe(200)
    const stopped = await chat(t, stopOn)
    expect(stopped.status).toBe(402)
    const body = JSON.parse(stopped.text)
    expect(body.error).toMatchObject({ code: "usage.included_reached", details: { included_usd: 20 } })
    expect(body.error.message).not.toMatch(/stripe|openrouter|stack/i)
    // The usage sync sees the team on a subscription with a usage item: usage above the included amount is billed.
    stripe.addSub("sub_inc1", "cus_inc1", { plan: "pro", stackUserId: stackUser }, "cmux-pro-monthly-50")
    expect((await sync()).body).toMatchObject({ items_added: 1 })
    expect((await chat(t, stopOn)).status).toBe(200)
    // A mark the sync stopped renewing (canceled, moved off the card plan) expires: the stop applies again.
    await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)), async (m) => {
      m.ctx.storage.sql.exec(`UPDATE usage_billable SET seen_at = ?`, Date.now() - 3 * 3600_000)
    })
    expect((await chat(t, stopOn)).status).toBe(402)
  })

  it("gives Founders the Pro included amount", async () => {
    const { t, team } = await paidPerson("included-stop-founders", "founders")
    fakeBoundaries(fakeStripe({ start: 1, end: 2 }), 0.000001)
    expect((await chat(t, stopOn)).status).toBe(200)
    await spend(team, 20)
    const r = await chat(t, stopOn)
    expect(r.status).toBe(402)
    expect(JSON.parse(r.text).error).toMatchObject({ code: "usage.included_reached", details: { included_usd: 20 } })
  })
})

/**
 * cx-y79zh.1 included modes (Lawrence 2026-10-14): a Team customer's mode is an operator setting per team
 * (POST /v1/internal/billing/team-mode); new teams are per team; a change applies from the next period
 * start. Per seat: the sync sends the level above included x seats (the most seats of the period) to the
 * per-seat meter; per team: the whole level to the graduated price's meter. Payment service faked at HTTP.
 */
const MODE_KEY = SYNC_KEY
const teamMode = async (body: unknown, key = MODE_KEY) => {
  const res = await loopback.fetch("https://api.test/v1/internal/billing/team-mode", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${key}` }, body: JSON.stringify(body) })
  return { status: res.status, body: (await res.json()) as any }
}
/** Places the team's settings before every period of the fake (as if the operator set it last month). */
const settingBeforePeriods = (team: string) =>
  inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)), async (m) => {
    m.ctx.storage.sql.exec(`UPDATE usage_mode_setting SET set_at = 0`)
  })
const spendOn = (team: string, usd: number) =>
  (testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)) as any).record(team, [{ key: `mode:${crypto.randomUUID()}`, meter: "model.spend_usd", quantity: usd, source: "coderouter", observed_at: Date.now() }])

describe("team included mode per team or per seat (cx-y79zh.1)", () => {
  const e2eEnv = { ...(env as object), ENVIRONMENT: "development", BILLING_USAGE_PRICE_SET: "e2e" }

  it("the operator route needs the key and an actor, records every change and says it applies from the next period", async () => {
    const stackTeam = "1d2c3b4a-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    expect((await teamMode({ stack_team: stackTeam, mode: "per_seat", actor: "ops" }, "wrong-key-0123456789abcdef0123456789")).status).toBe(401)
    expect((await teamMode({ stack_team: stackTeam, mode: "per_seat" })).status).toBe(400)
    expect((await teamMode({ stack_team: stackTeam, mode: "per_head", actor: "ops" })).status).toBe(400)
    const before = await teamMode({ stack_team: stackTeam, actor: "ops" })
    expect(before.body).toMatchObject({ requested: "per_team", in_force_now: "per_team", changes: [] })
    const set = await teamMode({ stack_team: stackTeam.toUpperCase(), mode: "per_seat", actor: "ops", reason: "contract" })
    expect(set.body).toMatchObject({ team: stackTeamIdFor(testEnv.STACK_PROJECT_ID, stackTeam), before: "per_team", mode: "per_seat", changed: true, applies: "next_period_start", requested: "per_seat", in_force_now: "per_team" })
    expect(set.body.changes[0]).toMatchObject({ mode: "per_seat", actor: "ops", reason: "contract" })
    expect((await teamMode({ stack_team: stackTeam, mode: "per_seat", actor: "ops" })).body).toMatchObject({ changed: false })
  })

  it("a mode change in a running period applies from the next period start, and the closed period keeps its mode", async () => {
    const stackTeam = "2e3d4c5b-6f7a-4b8c-9d0e-1f2a3b4c5d6e"
    const team = stackTeamIdFor(testEnv.STACK_PROJECT_ID, stackTeam)
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 120 })
    const sub = stripe.addSub("sub_mode1", "cus_mode1", { plan: "team", stackTeamId: stackTeam }, "cmux-team-monthly-20")
    sub.items.data[0].quantity = 2
    fakeBoundaries(stripe, 0)
    await spendOn(team, 2.5)
    // New team: per team. The operator asks for per seat in the middle of the period.
    expect((await teamMode({ stack_team: stackTeam, mode: "per_seat", actor: "ops" })).body).toMatchObject({ changed: true, in_force_now: "per_team" })
    await sync()
    expect(stripe.calls.filter((c) => c.path === "/v1/subscription_items").map((c) => c.form.price)).toEqual(["price_u_team"])
    expect(stripe.events).toEqual([expect.objectContaining({ event_name: "cmux_ai_usage", "payload[value]": "2.500000" })])
    // More usage in the same period, and another run: still per team, the item does not move.
    await spendOn(team, 0.5)
    await sync()
    expect(stripe.events.at(-1)).toMatchObject({ event_name: "cmux_ai_usage", "payload[value]": "3.000000" })
    expect(stripe.calls.filter((c) => /^\/v1\/subscription_items\/.+/.test(c.path))).toHaveLength(0)
    // The renewal: the new period starts after the change, so it is per seat; the item moves once, at its first run.
    const closedEnd = stripe.period.end
    stripe.period.start = closedEnd
    stripe.period.end = closedEnd + 30 * 86_400
    await sync()
    expect(stripe.calls.filter((c) => /^\/v1\/subscription_items\/.+/.test(c.path)).map((c) => c.form.price)).toEqual(["price_u_team_seat"])
    // The closed period's final level stays on its own (per-team) meter; the new period has no usage yet.
    expect(stripe.events.every((e) => e.event_name === "cmux_ai_usage")).toBe(true)
    expect((await teamMode({ stack_team: stackTeam, actor: "ops" })).body).toMatchObject({ in_force_now: "per_seat" })
    expect(planItemsUntouched(stripe)).toBe(true)
  })

  it("syncs a per-team team and a per-seat team side by side, each on its own meter, with the most seats of the period", async () => {
    // As the e2e: a Pro personal team (per team) beside a Team-plan team set per seat.
    const person = "usage-side-person"
    const perSeat = "4a5f6e7d-8b9c-4d0e-9f1a-3b4c5d6e7f80"
    const teamA = personalTeamIdFor(userIdFor(testEnv.STACK_PROJECT_ID, person))
    const teamB = stackTeamIdFor(testEnv.STACK_PROJECT_ID, perSeat)
    await teamMode({ stack_team: perSeat, mode: "per_seat", actor: "ops" })
    await settingBeforePeriods(teamB)
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 })
    const a = stripe.addSub("sub_side_a", "cus_side_a", { plan: "pro", stackUserId: person }, "cmux-pro-monthly-50")
    const b = stripe.addSub("sub_side_b", "cus_side_b", { plan: "team", stackTeamId: perSeat }, "cmux-team-monthly-20")
    a.items.data[0].quantity = 2
    b.items.data[0].quantity = 2
    fakeBoundaries(stripe, 0)
    await spendOn(teamA, 2.5)
    await spendOn(teamB, 2.5)
    expect((await sync(e2eEnv)).body).toMatchObject({ checked: 2, items_added: 2, pushed: 2, failed: 0 })
    const added = Object.fromEntries(stripe.calls.filter((c) => c.path === "/v1/subscription_items").map((c) => [c.form.subscription, c.form.price]))
    expect(added).toEqual({ sub_side_a: "price_e2e_pro", sub_side_b: "price_e2e_team_seat" })
    const byCustomer = (cus: string) => stripe.events.filter((e) => e["payload[stripe_customer_id]"] === cus)
    // e2e bills by v2's rules: model overage at list + 10%. Per team: the whole billed level, whatever the seats,
    // 1 + 1.5 x 1.1 = 2.65. Per seat: the pool is 2 x 0.5 = 1, so 1 + 1.5 x 1.1 - 1 = 1.65.
    expect(byCustomer("cus_side_a")).toEqual([expect.objectContaining({ event_name: "cmux_ai_usage", "payload[value]": "2.650000" })])
    expect(byCustomer("cus_side_b")).toEqual([expect.objectContaining({ event_name: "cmux_ai_usage_above_included", "payload[value]": "1.650000" })])
    // A third seat for both: per team nothing changes; per seat the pool is 1.5, 1.5 + 1.0 x 1.1 - 1.5 = 1.1, and
    // leaving again keeps 3 seats.
    a.items.data[0].quantity = 3
    b.items.data[0].quantity = 3
    await sync(e2eEnv)
    expect(byCustomer("cus_side_a")).toHaveLength(1)
    expect(byCustomer("cus_side_b").at(-1)).toMatchObject({ "payload[value]": "1.100000" })
    b.items.data[0].quantity = 2
    await sync(e2eEnv)
    expect(byCustomer("cus_side_b")).toHaveLength(2)
    expect(planItemsUntouched(stripe)).toBe(true)
  })
})

/** Price set v2 (Leo 2026-11-09): Team 25 USD per seat, pooled; a Team team with no setting is per seat. Staging only here. */
describe("price set v2: Team 25 USD per seat, per seat by default", () => {
  const v2Env = { ...(env as object), ENVIRONMENT: "staging", BILLING_USAGE_PRICE_SET: "v2" }

  it("syncs a 3-seat Team team with no setting per seat against 75 USD under v2, and per team under v1", async () => {
    const v2Team = "5b6a7f8e-9c0d-4e1f-8a2b-4c5d6e7f8091"
    const v1Team = "6c7b8a9f-0d1e-4f2a-9b3c-5d6e7f809102"
    const teamV2 = stackTeamIdFor(testEnv.STACK_PROJECT_ID, v2Team)
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 })
    const sub = stripe.addSub("sub_v2_team", "cus_v2_team", { plan: "team", stackTeamId: v2Team }, "cmux-team-monthly-20")
    sub.items.data[0].quantity = 3
    fakeBoundaries(stripe, 0)
    await spendOn(teamV2, 80)
    expect((await sync(v2Env)).body).toMatchObject({ checked: 1, items_added: 1, pushed: 1, failed: 0 })
    expect(stripe.calls.filter((c) => c.path === "/v1/subscription_items").map((c) => c.form.price)).toEqual(["price_v2_team_seat"])
    // 80 - 3 x 25 = 5 of model overage, at list + 10% under v2 (Leo 2026-11-09): 5.5 on the per-seat meter.
    expect(stripe.events).toEqual([expect.objectContaining({ event_name: "cmux_ai_usage_above_included", "payload[value]": "5.500000" })])
    const usage = await (testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(teamV2)) as any).teamUsage(teamV2)
    expect(usage.billable).toMatchObject({ mode: "per_seat", seats: 3, included_usd: 75 })
    // The operator read under v2 says per seat for a team with no setting.
    const read = await handleBillingTeamMode(new Request("https://api.test/v1/internal/billing/team-mode", { method: "POST", headers: { authorization: `Bearer ${MODE_KEY}` }, body: JSON.stringify({ stack_team: v2Team, actor: "ops" }) }), v2Env as any)
    expect(await read.json()).toMatchObject({ requested: "per_seat", in_force_now: "per_seat", changes: [] })

    // The same kind of team under v1 (this pool's env): per team, on the graduated price.
    const v1Sub = stripe.addSub("sub_v1team", "cus_v1_team", { plan: "team", stackTeamId: v1Team }, "cmux-team-monthly-20")
    v1Sub.items.data[0].quantity = 3
    await spendOn(stackTeamIdFor(testEnv.STACK_PROJECT_ID, v1Team), 1)
    expect((await sync(env, JSON.stringify({ subscription: "sub_v1team" }))).body).toMatchObject({ checked: 1, items_added: 1, failed: 0 })
    expect(stripe.calls.filter((c) => c.path === "/v1/subscription_items" && c.form.subscription === "sub_v1team").map((c) => c.form.price)).toEqual(["price_u_team"])
    expect((await teamMode({ stack_team: v1Team, actor: "ops" })).body).toMatchObject({ requested: "per_team", in_force_now: "per_team" })
  })

  it("records the first paid renewal from the subscription list (the raise lock), never the sign-up invoice", async () => {
    const lockTeam = "f1e2d3c4-b5a6-4978-8a6b-5c4d3e2f1a0b"
    const teamId = stackTeamIdFor(testEnv.STACK_PROJECT_ID, lockTeam)
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 })
    const sub: any = stripe.addSub("sub_lockteam1", "cus_lockteam1", { plan: "team", stackTeamId: lockTeam }, "cmux-team-monthly-20")
    sub.latest_invoice = { id: "in_signup", status: "paid", billing_reason: "subscription_create", amount_paid: 2500, status_transitions: { paid_at: nowS() - 3600 } }
    fakeBoundaries(stripe, 0)
    await spendOn(teamId, 1)
    const paid = async () => {
      let rows: unknown[] = []
      await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(teamId)), async (m: any) => {
        rows = m.ctx.storage.sql.exec(`SELECT invoice, subscription, amount_paid FROM usage_paid_invoice`).toArray()
      })
      return rows
    }
    expect((await sync(v2Env)).body).toMatchObject({ checked: 1, failed: 0 })
    expect(await paid()).toEqual([])
    sub.latest_invoice = { id: "in_renewal", status: "paid", billing_reason: "subscription_cycle", amount_paid: 2500, status_transitions: { paid_at: nowS() } }
    expect((await sync(v2Env)).body).toMatchObject({ checked: 1, failed: 0 })
    expect((await sync(v2Env, JSON.stringify({ subscription: "sub_lockteam1" }))).body).toMatchObject({ checked: 1, failed: 0 })
    expect(await paid()).toEqual([{ invoice: "in_renewal", subscription: "sub_lockteam1", amount_paid: 2500 }])
  })

  it("keeps a pushed per-seat period's included amount when the price set changes inside the period", async () => {
    const pinTeam = "8e9d0c1b-2f3a-4b4c-9d5e-7f8091021324"
    const teamId = stackTeamIdFor(testEnv.STACK_PROJECT_ID, pinTeam)
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 })
    const sub = stripe.addSub("sub_v2pin", "cus_v2_pin", { plan: "team", stackTeamId: pinTeam }, "cmux-team-monthly-20")
    sub.items.data[0].quantity = 3
    fakeBoundaries(stripe, 0)
    await spendOn(teamId, 80)
    expect((await sync(v2Env, JSON.stringify({ subscription: "sub_v2pin" }))).body).toMatchObject({ pushed: 1, failed: 0 })
    // The set goes back to v1 mid-period: the period stays per seat (pinned) and keeps 3 x 25, not 3 x 20, and keeps
    // v2's markup (pinned too): 90 - 75 = 15 of model overage x 1.1 = 16.5, never lowered to 15 mid-period.
    await spendOn(teamId, 10)
    expect((await sync({ ...(env as object), ENVIRONMENT: "staging" }, JSON.stringify({ subscription: "sub_v2pin" }))).body).toMatchObject({ pushed: 1, failed: 0 })
    expect(stripe.events.filter((e) => e["payload[stripe_customer_id]"] === "cus_v2_pin").map((e) => e["payload[value]"])).toEqual(["5.500000", "16.500000"])
    const usage = await (testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(teamId)) as any).teamUsage(teamId)
    expect(usage.billable).toMatchObject({ mode: "per_seat", seats: 3, included_usd: 75 })
  })

  it("stops an unbilled Team team with no setting at 25 x its last seats under v2, and at 25 under v1", async () => {
    const team = stackTeamIdFor(testEnv.STACK_PROJECT_ID, "7d8c9b0a-1e2f-4a3b-8c4d-6e7f80910213")
    const meter = testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)) as any
    await spendOn(team, 70)
    // A lapsed 3-seat subscription (its mark is not fresh, so the stop applies).
    await inDO(meter, async (m) => {
      m.ctx.storage.sql.exec(`INSERT INTO usage_billable (subscription, period_end, seen_at, period_start, mode, seats, included_usd) VALUES ('sub_v2_lapsed', ?, ?, ?, 'per_seat', 3, 25)`, Math.floor((Date.now() - 3 * 3600_000) / 1000), Date.now() - 3 * 3600_000, Math.floor((Date.now() - 30 * 86_400_000) / 1000))
    })
    const included = 25_000_000
    expect(await meter.reserveUser(team, "user_a", "v2-call-1", 4_000_000, 200_000_000, included, "per_seat")).toEqual({ ok: true })
    await meter.settleCall(team, "v2-call-1", null)
    expect(await meter.reserveUser(team, "user_a", "v2-call-2", 6_000_000, 200_000_000, included, "per_seat")).toMatchObject({ ok: false, included: true, limit_usd: 75 })
    expect(await meter.reserveUser(team, "user_a", "v1-call", 1_000_000, 200_000_000, included, "per_team")).toMatchObject({ ok: false, included: true, limit_usd: 25 })
    expect(await meter.reserveUser(team, "user_a", "old-call", 1_000_000, 200_000_000, included)).toMatchObject({ ok: false, included: true, limit_usd: 25 })
  })
})

describe("a retried level is the same request (cx-y79zh.1 e2e finding)", () => {
  it("after a failed send, the next run sends the identical meter event, so the idempotency key matches", async () => {
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 })
    stripe.addSub("sub_retry1", "cus_retry1", { plan: "pro", stackUserId: "usage-retry-person" }, "cmux-pro-monthly-50")
    fakeBoundaries(stripe, 0)
    const team = personalTeamIdFor(userIdFor(testEnv.STACK_PROJECT_ID, "usage-retry-person"))
    await spendOn(team, 1.25)
    stripe.control.failMeterEvents = 1
    expect((await sync()).body).toMatchObject({ failed: 1, pushed: 0 })
    // Time passes between runs; the retry must not change the request (the timestamp is the level's last fact).
    await new Promise((r) => setTimeout(r, 1100))
    expect((await sync()).body).toMatchObject({ failed: 0, pushed: 1 })
    expect(stripe.attempts).toHaveLength(2)
    expect(stripe.attempts[1]).toEqual(stripe.attempts[0])
    expect(stripe.events).toEqual([expect.objectContaining({ "payload[value]": "1.250000" })])
  })
})

describe("the included-amount stop of a per-seat team (cx-y79zh.1)", () => {
  it("a per-seat team that is not billable stops at the amount x its last billable seats, and a lapsed subscription's seats stop counting", async () => {
    // Go (5 USD): 3 seats stay under the test pool's team usage cap (25 USD).
    const { t, team } = await paidPerson("included-stop-per-seat", "go")
    const stopOn = { ...(env as object), USAGE_HARD_STOP_UNBILLED: "1" }
    fakeBoundaries(fakeStripe({ start: 1, end: 2 }), 0.000001)
    const meter = testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)) as any
    // The operator's per-seat setting (in force before this month), and a subscription with 3 seats whose mark expired.
    await meter.setIncludedMode(team, "per_seat", "ops", null)
    await inDO(meter, async (m) => {
      m.ctx.storage.sql.exec(`UPDATE usage_mode_setting SET set_at = 0`)
      m.ctx.storage.sql.exec(`INSERT INTO usage_billable (subscription, period_end, seen_at, period_start, mode, seats, included_usd) VALUES ('sub_lapsed', ?, ?, ?, 'per_seat', 3, 5)`, Math.floor((Date.now() - 3 * 3600_000) / 1000), Date.now() - 3 * 3600_000, Math.floor((Date.now() - 30 * 86_400_000) / 1000))
    })
    await spendOn(team, 12)
    // 12 of 3 x 5 = 15: the call passes (a per-team team would stop at 5).
    const passed = await chat(t, stopOn)
    expect({ status: passed.status, text: passed.status === 200 ? "" : passed.text }).toEqual({ status: 200, text: "" })
    await spendOn(team, 3)
    const stopped = await chat(t, stopOn)
    expect(stopped.status).toBe(402)
    expect(JSON.parse(stopped.text).error).toMatchObject({ code: "usage.included_reached", details: { included_usd: 15 } })
    // The subscription's period ended more than 35 days ago: its seats no longer count, the stop is at 1 x 5.
    await inDO(meter, async (m) => {
      m.ctx.storage.sql.exec(`UPDATE usage_billable SET period_end = ?`, Math.floor((Date.now() - 40 * 86_400_000) / 1000))
    })
    expect(JSON.parse((await chat(t, stopOn)).text).error).toMatchObject({ code: "usage.included_reached", details: { included_usd: 5 } })
  })
})

/** team.ai_limit.get through the Worker's fetch handler with `runEnv` (the stop is a Worker var). */
const aiLimits = async (t: string, runEnv: unknown) => {
  const ctx = createExecutionContext()
  const res = await worker.fetch!(new Request("https://api.test/v1/read", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify({ op: "team.ai_limit.get", params: {} }) }) as any, runEnv as any, ctx)
  const out = (await res.json()) as any
  await waitOnExecutionContext(ctx)
  return out
}

describe("the console's team usage line (cx-y79zh S5)", () => {
  it("shows the team's usage against its included amount, the stop, and the billing period once it is billable", async () => {
    const stackUser = "usage-line-pro"
    const { t, team } = await paidPerson(stackUser)
    // TeamDO answers with its own env, where the stop is off in this pool: the line says so (stop_applies false).
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 })
    fakeBoundaries(stripe, 0)
    const meter = testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)) as any
    await meter.record(team, [{ key: `line:${crypto.randomUUID()}`, meter: "model.spend_usd", quantity: 12.5, source: "coderouter", observed_at: Date.now() }])
    const before = await aiLimits(t, env)
    expect(before.value.team_usage).toMatchObject({ billed: false, included_usd: 20, per_seat: false, seats: 1, spent_usd: 12.5, stop_applies: false, stopped: false })
    expect(before.value.team_usage.period_end).toBe(before.value.resets_at)
    await meter.record(team, [{ key: `line:${crypto.randomUUID()}`, meter: "model.spend_usd", quantity: 7.5, source: "coderouter", observed_at: Date.now() }])
    expect((await aiLimits(t, env)).value.team_usage).toMatchObject({ spent_usd: 20, stopped: false })
    // Billable: the billing period, the amount the bill uses, and no stop.
    stripe.addSub("sub_line1", "cus_line1", { plan: "pro", stackUserId: stackUser }, "cmux-pro-monthly-50")
    await sync()
    const billed = (await aiLimits(t, env)).value.team_usage
    expect(billed).toMatchObject({ billed: true, included_usd: 20, per_seat: false, seats: 1, spent_usd: 20, period_start: stripe.period.start * 1000, period_end: stripe.period.end * 1000, stop_applies: false, stopped: false })
  })
})

/**
 * Model overage at list + 10% under price set v2 (Leo 2026-11-09, cmuxterm-hq plans/team-plan/margins.md "Decided"):
 * the sync sends the billed level, pinned per period like the included amount; the levels read answers the same.
 */
describe("model overage markup in the sync and the levels read (v2)", () => {
  const v2Env = { ...(env as object), ENVIRONMENT: "staging", BILLING_USAGE_PRICE_SET: "v2" }
  const v1Env = { ...(env as object), ENVIRONMENT: "staging" }
  const M = 1_000_000
  const meterOf = (team: string) => testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)) as any
  const machineOn = (team: string, usd: number) => meterOf(team).record(team, [{ key: `cloud:machine_${crypto.randomUUID()}:1:2026-11:1`, meter: "cloud.machine_usd", quantity: usd, source: "cloud", observed_at: Date.now(), user: "user_machine_creator" }])
  const levelsRead = async (runEnv: unknown, item: unknown) => (await (await handleBillingLevels(new Request("https://api.test/v1/internal/billing/levels", { method: "POST", headers: { authorization: `Bearer ${SYNC_KEY}` }, body: JSON.stringify({ items: [item] }) }), runEnv as any)).json()) as any

  it("sends the billed overage above 3 x 25 for models and machine time; the console and the levels read agree", async () => {
    const stackTeam = "a1b2c3d4-0e0f-4a1b-8c2d-0f1e2d3c4b5a"
    const team = stackTeamIdFor(testEnv.STACK_PROJECT_ID, stackTeam)
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 })
    const sub = stripe.addSub("sub_markup_team", "cus_markup_team", { plan: "team", stackTeamId: stackTeam }, "cmux-team-monthly-20")
    sub.items.data[0].quantity = 3
    fakeBoundaries(stripe, 0)
    await spendOn(team, 60)
    await machineOn(team, 40)
    expect((await sync(v2Env)).body).toMatchObject({ checked: 1, pushed: 1, failed: 0 })
    // Overage 25 = 15 models + 10 machines: 15 x 1.1 + 10.
    expect(stripe.events).toEqual([expect.objectContaining({ event_name: "cmux_ai_usage_above_included", "payload[value]": "26.500000" })])
    expect((await meterOf(team).teamUsage(team, "per_seat", true)).billable).toMatchObject({ mode: "per_seat", seats: 3, included_usd: 75, spent_usd: 101.5 })
    const item = { stack_team: stackTeam, from: stripe.period.start * 1000, to: stripe.period.end * 1000 }
    const v2Read = await levelsRead(v2Env, item)
    expect(v2Read.levels[0]).toMatchObject({ team, micros: 101.5 * M, cost_micros: 100 * M, models_micros: 60 * M, machine_micros: 40 * M, included_micros: 75 * M, meter_micros: 26.5 * M, markup_bp: 11_000, facts: 2, price_version: "ai-overage-models110-v2" })
    expect((v2Read.levels[0].meter_micros / M).toFixed(6)).toBe(stripe.events[0]!["payload[value]"])
    // Read under v1 the period keeps its pinned markup; v1 does not pool machine time, so 60 of models sits under 75.
    expect((await levelsRead(env, item)).levels[0]).toMatchObject({ micros: 60 * M, cost_micros: 60 * M, machine_micros: 0, included_micros: 75 * M, meter_micros: 0, markup_bp: 11_000 })
    // A period the sync never saw has no pool: the level at cost, the pass-through version.
    expect((await levelsRead(v2Env, { ...item, from: item.from - 86_400_000 })).levels[0]).toMatchObject({ micros: 100 * M, cost_micros: 100 * M, included_micros: null, meter_micros: 100 * M, markup_bp: 10_000, price_version: "ai-passthrough-v1" })
  })

  it("a period that started under v1 keeps pass-through after the set flips to v2, until it closes", async () => {
    const stackTeam = "b2c3d4e5-1f0a-4b2c-9d3e-1a2b3c4d5e6f"
    const team = stackTeamIdFor(testEnv.STACK_PROJECT_ID, stackTeam)
    // Set per seat (as v2 would default) before the period, so v1 bills it per seat on the 20 USD price.
    await teamMode({ stack_team: stackTeam, mode: "per_seat", actor: "ops" })
    await settingBeforePeriods(team)
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 })
    stripe.addSub("sub_pinv1", "cus_pin_v1", { plan: "team", stackTeamId: stackTeam }, "cmux-team-monthly-20")
    fakeBoundaries(stripe, 0)
    await spendOn(team, 30)
    expect((await sync(v1Env, JSON.stringify({ subscription: "sub_pinv1" }))).body).toMatchObject({ pushed: 1, failed: 0 })
    // The set flips to v2 mid-period: the period keeps 1 x 20 included and pass-through (40 - 20 = 20, not 22).
    await spendOn(team, 10)
    expect((await sync(v2Env, JSON.stringify({ subscription: "sub_pinv1" }))).body).toMatchObject({ pushed: 1, failed: 0 })
    expect(stripe.events.map((e) => e["payload[value]"])).toEqual(["10.000000", "20.000000"])
    expect((await meterOf(team).teamUsage(team, "per_seat", false)).billable).toMatchObject({ included_usd: 20, spent_usd: 40 })
    expect((await meterOf(team).teamCap(team, false, "v2")).spent_usd).toBe(40)
  })

  it("a v1 period's identifier is unchanged across the deploy: an unchanged level from before pinning is not sent again", async () => {
    const person = "usage-markup-v1-ident"
    const { t, team } = await paidPerson(person)
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 })
    stripe.addSub("sub_identv1", "cus_ident_v1", { plan: "pro", stackUserId: person }, "cmux-pro-monthly-50")
    fakeBoundaries(stripe, 0.000007)
    expect((await chat(t)).status).toBe(200)
    expect((await sync(env, JSON.stringify({ subscription: "sub_identv1" }))).body).toMatchObject({ pushed: 1 })
    let row: any = null
    await inDO(meterOf(team), async (m) => {
      row = m.ctx.storage.sql.exec(`SELECT period_start, identifier, micros FROM usage_push WHERE subscription = 'sub_identv1'`).one()
      // As a row written before this change: no pinned markup on the push or the mark.
      m.ctx.storage.sql.exec(`UPDATE usage_push SET markup_bp = NULL`)
      m.ctx.storage.sql.exec(`UPDATE usage_billable SET markup_bp = NULL`)
    })
    const level = await meterOf(team).level(team, row.period_start * 1000, (nowS() + 30 * 86_400) * 1000)
    // The S4 identifier form, over the level at cost.
    expect(row.identifier).toBe(`ai:sub_identv1:${row.period_start}:${level.micros}:${level.facts}:${level.last_at}`)
    expect(row.micros).toBe(7)
    // The deployed sync (production's v1) reads the same identifier and sends nothing; the run pins pass-through.
    expect((await sync(env, JSON.stringify({ subscription: "sub_identv1" }))).body).toMatchObject({ pushed: 0, unchanged: 1 })
    expect(stripe.events).toHaveLength(1)
    await inDO(meterOf(team), async (m) => {
      expect(m.ctx.storage.sql.exec(`SELECT markup_bp FROM usage_billable WHERE subscription = 'sub_identv1'`).one().markup_bp).toBe(10_000)
    })
  })
})
