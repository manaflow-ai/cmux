import { describe, expect, it } from "vitest"
import { billedLevelMicros, defaultTeamCapPools, markupPriceVersion, overageModelMarkup, poolsMachineTime, teamCapApplies, teamCapUnpaidMaxPools, usageMeterValueMicros } from "../src/billing-catalog.ts"
import { paidRenewal } from "../src/billing-usage-sync.ts"
import { stackTeamIdFor, userIdFor } from "../src/domains/user.ts"
import { teamCapReached } from "../src/inference/included-stop.ts"
import { inDO, paidPerson, post, testEnv } from "./setup/inference-person.ts"

/**
 * Leo 2026-11-09 (plans/team-plan/margins.md "Decided", sections 3 and 4): model overage at the provider's list
 * price + 10% under price set v2, and the team spending cap (refuse new model calls at the cap; cmux-platform
 * reads UsageMeterDO.teamCap to refuse machine starts and pause machines after a 15-minute warning). Driven at the
 * DO's RPC surface; the sync and levels-read tests that fake the payment service live in inference-spend-facts.test.ts
 * (one file replaces globalThis.fetch).
 */

const M = 1_000_000
const V2_BP = 11_000
const stub = (team: string) => testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)) as any
const modelFact = (usd: number) => ({ key: `model:${crypto.randomUUID()}`, meter: "model.spend_usd", quantity: usd, source: "coderouter", observed_at: Date.now() })
const machineFact = (usd: number) => ({ key: `cloud:machine_${crypto.randomUUID()}:1:2026-11:${Math.round(usd * M)}`, meter: "cloud.machine_usd", quantity: usd, source: "cloud", observed_at: Date.now(), user: userIdFor(testEnv.STACK_PROJECT_ID, "cap-machine-creator") })
/** A fresh billable mark, as the usage sync writes it under v2 (markup pinned): the period started an hour ago, ends in 30 days. */
const markBillable = (team: string, mode: "per_seat" | "per_team", seats: number, includedUsd: number, markupBp: number | null = V2_BP) =>
  stub(team).markBillable(team, `sub_${crypto.randomUUID()}`, nowS() + 30 * 86_400, { period_start: nowS() - 3600, mode, seats, included_usd: includedUsd, ...(markupBp === null ? {} : { markup_bp: markupBp }) })
const nowS = () => Math.floor(Date.now() / 1000)
const setCap = async (t: string, usd: number) => expect((await post("/v1/ops", t, { op: "usage.cap.set", params: { cap_usd: usd }, idempotency_key: crypto.randomUUID(), origin: "cli" })).ok).toBe(true)

describe("model overage markup (billing-catalog.ts billedLevelMicros)", () => {
  it("is 1.10 under v2's rules (v2 and its test-mode twin e2e); v1 stays pass-through", () => {
    expect(overageModelMarkup("v2")).toBe(1.1)
    expect(overageModelMarkup("e2e")).toBe(1.1)
    expect(overageModelMarkup("v1")).toBe(1)
  })

  it("e2e bills by v2's rules end to end: pooled machine time, the default cap and the model-call cap", () => {
    expect(poolsMachineTime("e2e")).toBe(true)
    expect(defaultTeamCapPools("e2e")).toBe(2)
    expect(teamCapApplies("e2e")).toBe(true)
    // A test-mode Pro team (1 USD included): 1.5 of models and 0.5 of machine time is 0.75 + 0.25 above the pool.
    expect(billedLevelMicros(1.5 * M, 0.5 * M, 1 * M, overageModelMarkup("e2e"))).toBe(2_075_000)
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

describe("the team spending cap (UsageMeterDO.teamCap)", () => {
  it("a team with no cap is under, cap null; v1 has no default cap", async () => {
    const team = stackTeamIdFor(testEnv.STACK_PROJECT_ID, "a1b2c3d4-0e0f-4a1b-8c2d-000000000001")
    const fresh = await stub(team).teamCap(team, true, "v2")
    expect(fresh).toMatchObject({ state: "under", spent_usd: 0, cap_usd: null })
    await stub(team).record(team, [modelFact(500)])
    // As a v1 sync marks it: pass-through pinned.
    await markBillable(team, "per_seat", 2, 25, 10_000)
    expect(await stub(team).teamCap(team, false, "v1")).toMatchObject({ state: "under", spent_usd: 500, cap_usd: null })
    expect(defaultTeamCapPools("v1")).toBeNull()
    expect(teamCapApplies("v1")).toBe(false)
  })

  it("v2 defaults to 2x the pool (50 x seats for a Team) once the sync marked it, through under, near and at_cap", async () => {
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
    // A per-team mark (a personal plan) gets the same default: twice its pool (Leo 2026-11-10, no machine-count cap, so
    // the spending cap is the stop for every account).
    const other = stackTeamIdFor(testEnv.STACK_PROJECT_ID, "a1b2c3d4-0e0f-4a1b-8c2d-000000000003")
    // 33 of models on a 20 pool: 20 + 13 x 1.1 = 34.3 billed, past 80% of 40.
    await stub(other).record(other, [modelFact(33)])
    await markBillable(other, "per_team", 1, 20)
    expect(await stub(other).teamCap(other, true, "v2")).toMatchObject({ state: "near", cap_usd: 40 })
    await stub(other).record(other, [modelFact(10)])
    expect(await stub(other).teamCap(other, true, "v2")).toMatchObject({ state: "at_cap", cap_usd: 40 })
  })

  it("a new account cannot raise its cap past 4 pools until its first paid renewal invoice", async () => {
    const { t, team } = await paidPerson("team-cap-raise-lock")
    const meter = stub(team)
    await markBillable(team, "per_team", 1, 20, 10_000)
    // The default, 2 x 20, is under the lock.
    expect(await meter.teamCap(team, false, "v2")).toMatchObject({ cap_usd: 40 })
    expect((await meter.teamCap(team, false, "v2")).raise_locked).toBeUndefined()
    // Raised to 60: under 4 x 20 = 80, kept.
    await setCap(t, 60)
    expect(await meter.teamCap(team, false, "v2")).toMatchObject({ cap_usd: 60 })
    // Raised to 10000: held at 80 until a renewal is paid; the model router stops there too.
    await setCap(t, 10_000)
    expect(await meter.teamCap(team, false, "v2")).toMatchObject({ cap_usd: 80, raise_locked: true })
    await meter.record(team, [modelFact(79.5)])
    expect(await meter.reserveUser(team, "user_a", "lock-1", 1 * M, 500 * M, undefined, "per_team", false, "v2")).toMatchObject({ ok: false, team_cap: true, cap_usd: 80 })
    // v1 (production) has no default cap and no lock: the admin's cap as set.
    expect(await meter.teamCap(team, false, "v1")).toMatchObject({ cap_usd: 10_000 })
    // The first paid renewal lifts the lock for good.
    await meter.markPaidInvoice(team, "sub_lock", "in_renewal_1", 2000, nowS())
    await meter.markPaidInvoice(team, "sub_lock", "in_renewal_1", 2000, nowS())
    const lifted = await meter.teamCap(team, false, "v2")
    expect(lifted).toMatchObject({ state: "under", cap_usd: 10_000 })
    expect(lifted.raise_locked).toBeUndefined()
    expect(await meter.reserveUser(team, "user_a", "lock-2", 1 * M, 500 * M, undefined, "per_team", false, "v2")).toEqual({ ok: true })
  })

  it("the lock's size is env config: an integer of 2 to 1000 pools, else 4", () => {
    expect(teamCapUnpaidMaxPools(undefined)).toBe(4)
    expect(teamCapUnpaidMaxPools("10")).toBe(10)
    expect(teamCapUnpaidMaxPools(" 2 ")).toBe(2)
    for (const bad of ["", "1", "0", "1001", "2.5", "-3", "x"]) expect(teamCapUnpaidMaxPools(bad)).toBe(4)
  })

  it("only a renewal paid with money lifts the lock, not the sign-up invoice", () => {
    expect(paidRenewal({ id: "in_1", status: "paid", billing_reason: "subscription_cycle", amount_paid: 2000 })?.id).toBe("in_1")
    expect(paidRenewal({ id: "in_2", status: "paid", billing_reason: "subscription_create", amount_paid: 2000 })).toBeNull()
    expect(paidRenewal({ id: "in_3", status: "paid", billing_reason: "subscription_cycle", amount_paid: 0 })).toBeNull()
    expect(paidRenewal({ id: "in_4", status: "open", billing_reason: "subscription_cycle", amount_paid: 0 })).toBeNull()
    expect(paidRenewal("in_5")).toBeNull()
    expect(paidRenewal(null)).toBeNull()
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

  it("refuses a new model call for every member inside the reservation (v2): open calls count at their maximum", async () => {
    const { t, team } = await paidPerson("team-cap-router")
    await setCap(t, 20)
    // 19.5 at cost is under the cap (and the test ceiling, 25); billed with a 10 USD pool it is 10 + 9.5 x 1.1 = 20.45.
    await stub(team).record(team, [modelFact(19.5)])
    await markBillable(team, "per_seat", 1, 10)
    expect(teamCapApplies("v2")).toBe(true)
    // Without the cap (v1: route.ts passes no set) the call is reserved as today; the hard cap (A18) still allows it.
    expect((await stub(team).check(team)).allowed).toBe(true)
    expect(await stub(team).reserveUser(team, "user_a", "cap-v1", 1_000, 200 * M, undefined, "per_team", true)).toEqual({ ok: true })
    await stub(team).settleCall(team, "cap-v1", null)
    // Under v2: refused in the reservation's transaction, with the period's billed spend and end.
    const refused = await stub(team).reserveUser(team, "user_b", "cap-v2", 1_000, 200 * M, undefined, "per_team", true, "v2")
    expect(refused).toMatchObject({ ok: false, team_cap: true, cap_usd: 20, period_end: (nowS() + 30 * 86_400) * 1000 })
    expect(refused.spent_usd).toBeCloseTo(20.45, 6)
  })

  it("open calls count at their maximum, so concurrent calls cannot all pass just under the cap", async () => {
    const { t, team } = await paidPerson("team-cap-open-calls")
    await setCap(t, 10)
    const meter = stub(team)
    await meter.record(team, [modelFact(6)])
    // 6 settled + 3 reserved = 9: under, then near (>= 8).
    expect(await meter.reserveUser(team, "user_a", "open-1", 3 * M, 200 * M, undefined, "per_team", false, "v2")).toEqual({ ok: true })
    expect(await meter.teamCap(team, false, "v2")).toMatchObject({ state: "near", spent_usd: 9, cap_usd: 10 })
    // A second call of up to 3 would reach 12: refused while the first is open, though settled spend is only 6.
    expect(await meter.reserveUser(team, "user_b", "open-2", 3 * M, 200 * M, undefined, "per_team", false, "v2")).toMatchObject({ ok: false, team_cap: true, spent_usd: 9, cap_usd: 10 })
    // A call of up to 1 still fits (9 + 1 = 10, not past the cap) and brings the state to at_cap.
    expect(await meter.reserveUser(team, "user_b", "open-3", 1 * M, 200 * M, undefined, "per_team", false, "v2")).toEqual({ ok: true })
    expect(await meter.teamCap(team, false, "v2")).toMatchObject({ state: "at_cap", spent_usd: 10 })
    // The first call settles at 0.5: its reservation's 3 leave, the fact's 0.5 stays.
    await meter.settleCall(team, "open-1", 0.5 * M)
    expect(await meter.teamCap(team, false, "v2")).toMatchObject({ state: "under", spent_usd: 7.5 })
  })

  it("a stale billable mark falls back to the UTC month at cost, with the admin cap", async () => {
    const { t, team } = await paidPerson("team-cap-stale-mark")
    await setCap(t, 30)
    const meter = stub(team)
    await meter.record(team, [modelFact(20), machineFact(5)])
    // A mark last seen 3 hours ago (past BILLABLE_GRACE_MS): no billing period, no pool, no markup.
    await inDO(meter, async (m) => {
      m.ctx.storage.sql.exec(`INSERT INTO usage_billable (subscription, period_end, seen_at, period_start, mode, seats, included_usd, markup_bp) VALUES ('sub_stale', ?, ?, ?, 'per_seat', 1, 10, 11000)`, nowS() + 30 * 86_400, Date.now() - 3 * 3600_000, nowS() - 3600)
    })
    const d = new Date()
    const nextMonth = Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1)
    expect(await meter.teamCap(team, true, "v2")).toMatchObject({ state: "near", spent_usd: 25, cap_usd: 30, period_end: nextMonth })
    expect(await meter.teamCap(team, false, "v2")).toMatchObject({ state: "under", spent_usd: 20, cap_usd: 30 })
  })

  it("the 402 of the team cap names the spend, the cap and when the period ends", async () => {
    const res = teamCapReached(20.45, 20, 1_800_000_000_000)
    expect(res.status).toBe(402)
    expect(await res.json()).toEqual({ error: { code: "team.cap_reached", message: "Your team reached its spending cap for this billing period. A team admin can raise it.", type: "insufficient_quota", details: { spent_usd: 20.45, cap_usd: 20, resets_at: 1_800_000_000_000 } } })
  })

  it("reads the period's settled spend from its running total, not by summing facts per call", async () => {
    const { t, team } = await paidPerson("team-cap-running-total")
    await setCap(t, 1_000)
    const meter = stub(team)
    await meter.record(team, [modelFact(3), machineFact(2)])
    await markBillable(team, "per_seat", 1, 25)
    await meter.record(team, [modelFact(1)])
    await meter.reserveUser(team, "user_a", "rt-1", 1 * M, 200 * M)
    await meter.settleCall(team, "rt-1", 0.25 * M)
    let row: any = null
    await inDO(meter, async (m) => {
      row = m.ctx.storage.sql.exec(`SELECT models_micros, machine_micros FROM usage_period_spend`).one()
    })
    // Seeded at the mark (3 + 2), then each fact added in its own write (record, settle).
    expect(row).toEqual({ models_micros: 4.25 * M, machine_micros: 2 * M })
    expect((await meter.teamCap(team, true, "v2")).spent_usd).toBe(6.25)
  })

  it("uses the markup pinned to the period: a mark from before pinning (none) is pass-through", async () => {
    const team = stackTeamIdFor(testEnv.STACK_PROJECT_ID, "a1b2c3d4-0e0f-4a1b-8c2d-000000000005")
    const meter = stub(team)
    await meter.record(team, [modelFact(20)])
    await markBillable(team, "per_seat", 1, 10, null)
    // 20 on a 10 pool at pass-through: 20, though the set in force (v2) marks up.
    expect((await meter.teamCap(team, false, "v2")).spent_usd).toBe(20)
    expect((await meter.teamUsage(team, "per_seat", false)).billable.spent_usd).toBe(20)
    expect(markupPriceVersion(V2_BP)).toBe("ai-overage-models110-v2")
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
