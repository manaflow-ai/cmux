import { describe, expect, it } from "vitest"
import { inDO, testEnv } from "./setup/inference-person.ts"
import { stackTeamIdFor, userIdFor } from "../src/domains/user.ts"

/**
 * Team plan (Leo 2026-11-09): the included amount pools model spend and Cloud machine time. CloudDO
 * (cmux-platform) records machine time into the team's UsageMeterDO as `cloud.machine_usd` facts at
 * list price, keyed `cloud:<machine>:<open_rev>:<YYYY-MM>:<level micros>`, naming the machine's creator.
 * Driven at the DO's RPC surface, the way CloudDO calls it.
 */

const stub = (team: string) => testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)) as any
const machineFact = (key: string, usd: number, user: string) => ({ key, meter: "cloud.machine_usd", quantity: usd, source: "cloud", observed_at: Date.now(), user })
const modelFact = (usd: number) => ({ key: `model:${crypto.randomUUID()}`, meter: "model.spend_usd", quantity: usd, source: "coderouter", observed_at: Date.now() })
const ledger = async (team: string, meter: string) => {
  let rows: Array<{ key: string; user: string | null; quantity: number; source: string }> = []
  await inDO(stub(team), async (m) => {
    rows = m.ctx.storage.sql.exec(`SELECT key, user, quantity, source FROM usage_ledger WHERE meter = ?`, meter).toArray()
  })
  return rows
}

describe("Cloud machine time joins the team pool (cloud.machine_usd)", () => {
  it("counts in the billing level, the team's spend and the member's spend, once per key", async () => {
    const team = stackTeamIdFor(testEnv.STACK_PROJECT_ID, "c1a0d0e0-0000-4000-8000-000000000001")
    // The creator id as CloudDO and the model router both derive it (userIdFor: `user_` + 20 hex).
    const user = userIdFor(testEnv.STACK_PROJECT_ID, "cloud-machine-creator")
    expect(user).toMatch(/^user_[0-9a-f]{20}$/)
    const meter = stub(team)
    const from = Date.now()
    const key = "cloud:machine_abc:3:2026-11:1250000"
    const first = await meter.record(team, [machineFact(key, 1.25, user), modelFact(2)])
    expect(first).toMatchObject({ recorded: 2, duplicates: 0, invalid: 0 })
    expect(first.summary.meters.find((l: any) => l.meter === "cloud.machine_usd")).toMatchObject({ unit: "usd", quantity: 1.25, usd: 1.25 })
    // CloudDO retries the same level: counted once.
    const again = await meter.record(team, [machineFact(key, 1.25, user)])
    expect(again).toMatchObject({ recorded: 0, duplicates: 1 })
    expect(await ledger(team, "cloud.machine_usd")).toEqual([{ key, user, quantity: 1.25, source: "cloud" }])

    // Price set v2 (Team) pools machine time: callers pass poolsMachineTime(set).
    const level = await meter.level(team, from, Date.now() + 1, true)
    expect(level).toMatchObject({ micros: 3_250_000, facts: 2 })
    const usage = await meter.teamUsage(team, "per_team", true)
    expect(usage.month_spent_usd).toBe(3.25)
    expect((await meter.userSpends(team, [user]))[user]).toBe(1.25)
  })

  it("a Team per-seat team that cannot be billed stops at its included amount across models and machine time", async () => {
    const team = stackTeamIdFor(testEnv.STACK_PROJECT_ID, "c1a0d0e0-0000-4000-8000-000000000002")
    const creator = userIdFor(testEnv.STACK_PROJECT_ID, "cloud-pool-creator")
    const caller = userIdFor(testEnv.STACK_PROJECT_ID, "cloud-pool-caller")
    const meter = stub(team)
    // 40 of models, 30 of machine time: 70 of 3 seats x 25.
    await meter.record(team, [modelFact(40), machineFact("cloud:machine_pool:1:2026-11:30000000", 30, creator)])
    // A lapsed 3-seat subscription (its mark is not fresh, so the stop applies).
    await inDO(meter, async (m) => {
      m.ctx.storage.sql.exec(`INSERT INTO usage_billable (subscription, period_end, seen_at, period_start, mode, seats, included_usd) VALUES ('sub_cloud_pool', ?, ?, ?, 'per_seat', 3, 25)`, Math.floor((Date.now() - 3 * 3600_000) / 1000), Date.now() - 3 * 3600_000, Math.floor((Date.now() - 30 * 86_400_000) / 1000))
    })
    const included = 25_000_000
    expect(await meter.reserveUser(team, caller, "pool-call-1", 4_000_000, 200_000_000, included, "per_seat", true)).toEqual({ ok: true })
    await meter.settleCall(team, "pool-call-1", null)
    // Without machine time this call would pass (40 + 6 <= 75).
    expect(await meter.reserveUser(team, caller, "pool-call-2", 6_000_000, 200_000_000, included, "per_seat", true)).toMatchObject({ ok: false, included: true, spent_usd: 70, limit_usd: 75 })
    expect((await meter.teamUsage(team, "per_seat", true)).month_spent_usd).toBe(70)
  })

  it("machine time counts against its creator's monthly limit", async () => {
    const team = stackTeamIdFor(testEnv.STACK_PROJECT_ID, "c1a0d0e0-0000-4000-8000-000000000003")
    const creator = userIdFor(testEnv.STACK_PROJECT_ID, "cloud-limit-creator")
    const other = userIdFor(testEnv.STACK_PROJECT_ID, "cloud-limit-other")
    const meter = stub(team)
    await meter.record(team, [machineFact("cloud:machine_lim:1:2026-11:9500000", 9.5, creator)])
    // A 10 USD member limit: the creator has 0.5 left, a teammate all of it.
    expect(await meter.reserveUser(team, creator, "lim-call-1", 1_000_000, 10_000_000)).toMatchObject({ ok: false, spent_usd: 9.5, limit_usd: 10 })
    expect(await meter.reserveUser(team, other, "lim-call-2", 1_000_000, 10_000_000)).toEqual({ ok: true })
    // record() with `limit` answers for the member the same way.
    const r = await meter.record(team, [machineFact("cloud:machine_lim:1:2026-11:10000000", 0.5, creator)], { user: creator, limitMicros: 10_000_000 })
    expect(r).toMatchObject({ recorded: 1, user_allowed: false })
  })

  it("a machine-time fact is kept as a billable fact past the 35-day dedupe window", async () => {
    const team = stackTeamIdFor(testEnv.STACK_PROJECT_ID, "c1a0d0e0-0000-4000-8000-000000000004")
    const user = userIdFor(testEnv.STACK_PROJECT_ID, "cloud-kept-creator")
    const meter = stub(team)
    await meter.record(team, [machineFact("cloud:machine_kept:1:2026-11:2000000", 2, user), { key: "step:run_kept:s1", meter: "automation.steps", quantity: 1, source: "step", observed_at: Date.now() }])
    await inDO(meter, async (m) => m.onWake(Date.now() + 40 * 86_400_000))
    expect(await ledger(team, "automation.steps")).toEqual([])
    expect(await ledger(team, "cloud.machine_usd")).toHaveLength(1)
    // The alarm's next wake for the fact is its 400-day billable retention, not the dedupe window.
    let wake = 0
    await inDO(meter, async (m) => {
      wake = m.nextWakeAt()
    })
    expect(wake).toBeGreaterThan(Date.now() + 399 * 86_400_000)
    await inDO(meter, async (m) => m.onWake(Date.now() + 401 * 86_400_000))
    expect(await ledger(team, "cloud.machine_usd")).toEqual([])
  })

  it("refuses a record with an unknown source or meter as before", async () => {
    const team = stackTeamIdFor(testEnv.STACK_PROJECT_ID, "c1a0d0e0-0000-4000-8000-000000000005")
    const user = userIdFor(testEnv.STACK_PROJECT_ID, "cloud-bad-creator")
    const meter = stub(team)
    const r = await meter.record(team, [
      { ...machineFact("cloud:machine_bad:1:2026-11:1", 1, user), source: "cloud-vm" },
      { ...machineFact("cloud:machine_bad:1:2026-11:2", 1, user), meter: "cloud.machine_minutes" },
      { ...machineFact("cloud:machine_bad:1:2026-11:3", 1, user), key: `cloud:${"x".repeat(200)}` }
    ])
    expect(r).toMatchObject({ recorded: 0, invalid: 3 })
    expect(await meter.level(team, 0, Date.now() + 1)).toMatchObject({ micros: 0, facts: 0 })
  })

  it("production's price set v1 bills model spend only: machine time stays out of the level, the spend view and the included stop", async () => {
    const team = stackTeamIdFor(testEnv.STACK_PROJECT_ID, "c1a0d0e0-0000-4000-8000-000000000006")
    const creator = userIdFor(testEnv.STACK_PROJECT_ID, "cloud-v1-creator")
    const caller = userIdFor(testEnv.STACK_PROJECT_ID, "cloud-v1-caller")
    const meter = stub(team)
    const from = Date.now()
    await meter.record(team, [modelFact(40), machineFact("cloud:machine_v1:1:2026-11:30000000", 30, creator)])
    expect(await meter.level(team, from, Date.now() + 1)).toMatchObject({ micros: 40_000_000, facts: 1 })
    expect((await meter.teamUsage(team, "per_seat")).month_spent_usd).toBe(40)
    await inDO(meter, async (m) => {
      m.ctx.storage.sql.exec(`INSERT INTO usage_billable (subscription, period_end, seen_at, period_start, mode, seats, included_usd) VALUES ('sub_cloud_v1', ?, ?, ?, 'per_seat', 3, 25)`, Math.floor((Date.now() - 3 * 3600_000) / 1000), Date.now() - 3 * 3600_000, Math.floor((Date.now() - 30 * 86_400_000) / 1000))
    })
    // 40 + 6 <= 75 passes when machine time is not pooled.
    expect(await meter.reserveUser(team, caller, "v1-call-1", 6_000_000, 200_000_000, 25_000_000, "per_seat")).toEqual({ ok: true })
    // The member limit still counts the creator's machine time.
    expect((await meter.userSpends(team, [creator]))[creator]).toBe(30)
  })
})
