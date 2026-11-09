import { env } from "cloudflare:workers"
import { afterEach, describe, expect, it, vi } from "vitest"
import { billedLevelMicros, defaultTeamCapPools, overageModelMarkup, teamCapApplies, usageMeterValueMicros } from "../src/billing-catalog.ts"
import { stackTeamIdFor, userIdFor } from "../src/domains/user.ts"
import { chat, inDO, paidPerson, post, testEnv } from "./setup/inference-person.ts"
import { fakeBoundaries, fakeStripe, nowS, sync } from "./setup/fake-stripe.ts"

/**
 * Leo 2026-11-09 (plans/team-plan/margins.md "Decided", sections 3 and 4): model overage at the provider's list
 * price + 10% under price set v2, and the team spending cap (refuse new model calls at the cap; cmux-platform
 * reads UsageMeterDO.teamCap to refuse machine starts and pause machines after a 15-minute warning).
 */

const M = 1_000_000
const v2Env = { ...(env as object), ENVIRONMENT: "staging", BILLING_USAGE_PRICE_SET: "v2" }
const stub = (team: string) => testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)) as any
const modelFact = (usd: number) => ({ key: `model:${crypto.randomUUID()}`, meter: "model.spend_usd", quantity: usd, source: "coderouter", observed_at: Date.now() })
const machineFact = (usd: number) => ({ key: `cloud:machine_${crypto.randomUUID()}:1:2026-11:${Math.round(usd * M)}`, meter: "cloud.machine_usd", quantity: usd, source: "cloud", observed_at: Date.now(), user: userIdFor(testEnv.STACK_PROJECT_ID, "cap-machine-creator") })
/** A fresh billable mark, as the usage sync writes it: the period started an hour ago and ends in 30 days. */
const markBillable = (team: string, mode: "per_seat" | "per_team", seats: number, includedUsd: number) =>
  stub(team).markBillable(team, `sub_${crypto.randomUUID()}`, nowS() + 30 * 86_400, { period_start: nowS() - 3600, mode, seats, included_usd: includedUsd })

afterEach(() => {
  vi.restoreAllMocks()
})

describe("model overage markup (billing-catalog.ts billedLevelMicros)", () => {
  it("is 1.10 under v2 only; v1 (production) and e2e stay pass-through", () => {
    expect(overageModelMarkup("v2")).toBe(1.1)
    expect(overageModelMarkup("v1")).toBe(1)
    expect(overageModelMarkup("e2e")).toBe(1)
  })

  it("v1: the billed level is the level at cost, above the pool too", () => {
    expect(billedLevelMicros(80 * M, 0, 75 * M, overageModelMarkup("v1"))).toBe(80 * M)
    expect(billedLevelMicros(60 * M, 40 * M, 75 * M, overageModelMarkup("v1"))).toBe(100 * M)
  })

  it("v2 under the pool: no markup", () => {
    expect(billedLevelMicros(50 * M, 20 * M, 75 * M, 1.1)).toBe(70 * M)
    expect(billedLevelMicros(75 * M, 0, 75 * M, 1.1)).toBe(75 * M)
  })

  it("v2 above the pool, models only: the overage x 1.10", () => {
    // 80 of models on 75 included: 75 + 5 x 1.1.
    expect(billedLevelMicros(80 * M, 0, 75 * M, 1.1)).toBe(80.5 * M)
  })

  it("v2 above the pool, machines only: at list, no markup", () => {
    expect(billedLevelMicros(0, 90 * M, 75 * M, 1.1)).toBe(90 * M)
  })

  it("v2 above the pool, mixed: the overage splits pro rata to the period's shares", () => {
    // 60 models + 40 machines = 100 on 75: overage 25 = 15 models + 10 machines; billed 75 + 16.5 + 10.
    expect(billedLevelMicros(60 * M, 40 * M, 75 * M, 1.1)).toBe(101.5 * M)
    // Integer micros: the models' share is floored, the machines take the rest, the markup rounds half up.
    // 1 micro of overage at a 1:2 split: 0 to models, 1 to machines.
    expect(billedLevelMicros(1_000_001, 2_000_000, 3 * M, 1.1)).toBe(3_000_001)
    // 10 micros of models overage x 1.1 = 11.
    expect(billedLevelMicros(10, 0, 0, 1.1)).toBe(11)
    // A large month stays exact (BigInt split).
    expect(billedLevelMicros(9_000_000 * M, 1_000_000 * M, 0, 1.1)).toBe(10_900_000 * M)
  })

  it("Stripe's (level - included) is the billed overage in both included modes", () => {
    // Per seat, 3 x 25: the sync subtracts included x seats.
    const perSeat = billedLevelMicros(60 * M, 40 * M, 75 * M, 1.1)
    expect(usageMeterValueMicros("per_seat", perSeat, 25, 3)).toBe(26.5 * M)
    // Per team (graduated, first 25 units free): the whole level is sent; Stripe bills level - 25.
    const perTeam = billedLevelMicros(24 * M, 6 * M, 25 * M, 1.1)
    expect(usageMeterValueMicros("per_team", perTeam, 25, 1)).toBe(perTeam)
    expect(perTeam - 25 * M).toBe(4 * M * 1.1 + 1 * M)
  })
})

describe("the usage sync and the console under v2 bill the model overage at list + 10%", () => {
  it("sends the billed overage above 3 x 25 for models and machine time, and the console shows the same", async () => {
    const stackTeam = "a1b2c3d4-0e0f-4a1b-8c2d-0f1e2d3c4b5a"
    const team = stackTeamIdFor(testEnv.STACK_PROJECT_ID, stackTeam)
    const stripe = fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 })
    const sub = stripe.addSub("sub_markup_team", "cus_markup_team", { plan: "team", stackTeamId: stackTeam }, "cmux-team-monthly-20")
    sub.items.data[0].quantity = 3
    fakeBoundaries(stripe, 0)
    await stub(team).record(team, [modelFact(60), machineFact(40)])
    expect((await sync(v2Env)).body).toMatchObject({ checked: 1, pushed: 1, failed: 0 })
    expect(stripe.events).toEqual([expect.objectContaining({ event_name: "cmux_ai_usage_above_included", "payload[value]": "26.500000" })])
    const usage = await stub(team).teamUsage(team, "per_seat", true, overageModelMarkup("v2"))
    expect(usage.billable).toMatchObject({ mode: "per_seat", seats: 3, included_usd: 75, spent_usd: 101.5 })
    // The same period read at cost (markup 1, the default) is the level unchanged.
    expect((await stub(team).teamUsage(team, "per_seat", true)).billable.spent_usd).toBe(100)
  })
})

describe("the team spending cap (UsageMeterDO.teamCap)", () => {
  it("a team with no cap is under, cap null; v1 and e2e have no default cap", async () => {
    const team = stackTeamIdFor(testEnv.STACK_PROJECT_ID, "a1b2c3d4-0e0f-4a1b-8c2d-000000000001")
    const fresh = await stub(team).teamCap(team, true, "v2")
    expect(fresh).toMatchObject({ state: "under", spent_usd: 0, cap_usd: null })
    await stub(team).record(team, [modelFact(500)])
    await markBillable(team, "per_seat", 2, 25)
    expect(await stub(team).teamCap(team, false, "v1")).toMatchObject({ state: "under", spent_usd: 500, cap_usd: null })
    expect(defaultTeamCapPools("v1")).toBeNull()
    expect(defaultTeamCapPools("e2e")).toBeNull()
    expect(teamCapApplies("v1")).toBe(false)
  })

  it("v2 Team defaults to 2x the pool (50 x seats) once the sync marked its seats, through under, near and at_cap", async () => {
    const team = stackTeamIdFor(testEnv.STACK_PROJECT_ID, "a1b2c3d4-0e0f-4a1b-8c2d-000000000002")
    const meter = stub(team)
    // No mark yet: seats unknown, no default.
    await meter.record(team, [machineFact(1)])
    expect(await meter.teamCap(team, true, "v2")).toMatchObject({ state: "under", cap_usd: null })
    await markBillable(team, "per_seat", 2, 25)
    const under = await meter.teamCap(team, true, "v2")
    expect(under).toMatchObject({ state: "under", spent_usd: 1, cap_usd: 100 })
    expect(under.period_end).toBe((nowS() + 30 * 86_400) * 1000)
    // 49 models + 1 machine = 50 = the pool, at cost.
    await meter.record(team, [modelFact(49)])
    expect(await meter.teamCap(team, true, "v2")).toMatchObject({ state: "under", spent_usd: 50 })
    // 75 models + 5 machines = 80 at cost; overage 30 = 28.125 models + 1.875 machines; billed 50 + 30.9375 + 1.875.
    await meter.record(team, [modelFact(26), machineFact(4)])
    expect(await meter.teamCap(team, true, "v2")).toMatchObject({ state: "near", spent_usd: 82.8125, cap_usd: 100 })
    // Without machine time (the caller's choice) only the models count.
    expect((await meter.teamCap(team, false, "v2")).spent_usd).toBe(50 + 25 * 1.1)
    await meter.record(team, [modelFact(20)])
    expect(await meter.teamCap(team, true, "v2")).toMatchObject({ state: "at_cap", cap_usd: 100 })
    // A per-team mark (not Team per seat) gets no default.
    const other = stackTeamIdFor(testEnv.STACK_PROJECT_ID, "a1b2c3d4-0e0f-4a1b-8c2d-000000000003")
    await stub(other).record(other, [modelFact(100)])
    await markBillable(other, "per_team", 1, 20)
    expect(await stub(other).teamCap(other, true, "v2")).toMatchObject({ state: "under", cap_usd: null })
  })

  it("an admin-set cap wins over the default and keeps working as today, counting machine time", async () => {
    const { t, team } = await paidPerson("team-cap-admin")
    expect((await post("/v1/ops", t, { op: "usage.cap.set", params: { cap_usd: 10 }, idempotency_key: crypto.randomUUID(), origin: "cli" })).ok).toBe(true)
    const meter = stub(team)
    await meter.record(team, [modelFact(4), machineFact(4)])
    expect(await meter.teamCap(team, true, "v2")).toMatchObject({ state: "near", spent_usd: 8, cap_usd: 10 })
    expect(await meter.teamCap(team, false, "v1")).toMatchObject({ state: "under", spent_usd: 4, cap_usd: 10 })
    // The hard cap (A18) counts machine time too: 8 of 10 still allowed, 10 stopped.
    expect((await meter.check(team)).allowed).toBe(true)
    await meter.record(team, [machineFact(2)])
    expect((await meter.check(team)).allowed).toBe(false)
    expect(await meter.teamCap(team, true, "v2")).toMatchObject({ state: "at_cap", cap_usd: 10 })
  })

  it("refuses new model calls for every member at the cap under v2, priced with the markup; v1 keeps today's check", async () => {
    const { t, team } = await paidPerson("team-cap-router")
    expect((await post("/v1/ops", t, { op: "usage.cap.set", params: { cap_usd: 20 }, idempotency_key: crypto.randomUUID(), origin: "cli" })).ok).toBe(true)
    fakeBoundaries(fakeStripe({ start: nowS() - 3600, end: nowS() + 30 * 86_400 }), 0.000007)
    // 19.5 at cost is under the cap (and the test ceiling, 25); billed with a 10 USD pool it is 10 + 9.5 x 1.1 = 20.45.
    await stub(team).record(team, [modelFact(19.5)])
    await markBillable(team, "per_seat", 1, 10)
    // The test Worker is v1 (its sign-in keys need ENVIRONMENT=test): the router's check is today's, and the call goes.
    expect((await chat(t)).status).toBe(200)
    // The router's check under v2 (route.ts passes { machineTime: poolsMachineTime(set), set } when teamCapApplies):
    // refused, with the cap state for the 402 details; the same team under v1 is allowed.
    expect(teamCapApplies("v2")).toBe(true)
    const v2 = await stub(team).check(team, { machineTime: true, set: "v2" })
    expect(v2).toMatchObject({ allowed: false, cap: { state: "at_cap", cap_usd: 20 } })
    expect(v2.cap.spent_usd).toBeCloseTo(20.45 + 0.000007 * 1.1, 6)
    expect((await stub(team).check(team)).allowed).toBe(true)
  })
})

describe("member budget (C): machine time counts, and the stop refuses only new calls", () => {
  it("a member at their limit is refused a new call; open calls and machine facts still settle", async () => {
    const team = stackTeamIdFor(testEnv.STACK_PROJECT_ID, "a1b2c3d4-0e0f-4a1b-8c2d-000000000004")
    const user = userIdFor(testEnv.STACK_PROJECT_ID, "cap-machine-creator")
    const meter = stub(team)
    expect(await meter.reserveUser(team, user, "budget-open", 1 * M, 10 * M)).toEqual({ ok: true })
    // Machine time of the member's machines lands on their spend while the call is open.
    await meter.record(team, [machineFact(9.5)])
    expect(await meter.reserveUser(team, user, "budget-new", 1 * M, 10 * M)).toMatchObject({ ok: false, spent_usd: 9.5, limit_usd: 10 })
    // The open call is not cut: it settles, and machine facts keep being recorded (nothing is paused).
    await meter.settleCall(team, "budget-open", 0.5 * M)
    expect((await meter.record(team, [machineFact(1)])).recorded).toBe(1)
    let open = -1
    await inDO(meter, async (m) => {
      open = m.ctx.storage.sql.exec(`SELECT COUNT(*) AS n FROM user_reservation`).one().n
    })
    expect(open).toBe(0)
    expect((await meter.userSpends(team, [user]))[user]).toBe(11)
  })
})
