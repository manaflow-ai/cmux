import { idFactory, type Principal, type ReduceContext, MemoryRows } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { checkCron, nextFire } from "../src/cron.ts"
import { dispatchable, dueFires, matchingEventTriggers, MAX_FINISHED_RUNS, schedulerDomain, type SchedulerState } from "../src/domains/scheduler.ts"

const user: Principal = { identity: "session:user_aaaaaaaaaaaaaaaaaaaa", kind: "session", user: "user_aaaaaaaaaaaaaaaaaaaa", team: "team_aaaaaaaaaaaaaaaaaaaa" }
const system: Principal = { identity: "system:scheduler", kind: "system" }
const other: Principal = { identity: "session:user_bbbbbbbbbbbbbbbbbbbb", kind: "session", user: "user_bbbbbbbbbbbbbbbbbbbb", team: "team_bbbbbbbbbbbbbbbbbbbb" }

let txn = 0
const ctx = (principal: Principal, now: number): ReduceContext => {
  const tx = `tx${txn++}`
  return { principal, now, tx, newId: idFactory(tx), rows: new MemoryRows() }
}

/** Applies one op like the engine: authorize, then reduce. Throws on reject. */
const apply = (s: SchedulerState, p: Principal, op: string, params: unknown, now: number) => {
  const denied = schedulerDomain.authorize!(s, op, params, p)
  if (denied) throw Object.assign(new Error(denied.message), { code: denied.code })
  const r = schedulerDomain.reduce(s, op, params, ctx(p, now))
  if (!r.ok) throw Object.assign(new Error(r.message), { code: r.code })
  return r
}

const T0 = Date.UTC(2026, 9, 2, 12, 0, 30) // 12:00:30 UTC
const steps = { type: "steps", steps: [{ type: "note", text: "hi" }] }

describe("cron", () => {
  it("refuses seconds fields, unknown zones and expressions that never fire", () => {
    expect(checkCron("* * * * * *", "UTC").ok).toBe(false)
    expect(checkCron("* * * * *", "Mars/Olympus").ok).toBe(false)
    expect(checkCron("0 0 30 2 *", "UTC").ok).toBe(false)
  })
})

describe("SchedulerDO reducer", () => {
  const created = () => {
    const r = apply(({ ...schedulerDomain.initial(), run_policy: { version: 0, runs_allowed: true } }), user, "automation.create", { name: "hourly", triggers: [{ type: "cron", expr: "0 * * * *", tz: "UTC" }, { type: "manual" }, { type: "presence", when: "user_active" }], body: steps }, T0)
    return { state: r.state, a: r.value as any }
  }

  it("refuses bad cron, another team, and public calls to internal ops", () => {
    expect(() => apply(({ ...schedulerDomain.initial(), run_policy: { version: 0, runs_allowed: true } }), user, "automation.create", { name: "x", triggers: [{ type: "cron", expr: "nope", tz: "UTC" }], body: steps }, T0)).toThrow(/cron|field/)
    const { state } = created()
    expect(() => apply(state, other, "automation.list", {}, T0)).toThrow(/not this team/)
    expect(() => apply(state, user, "automation.fire", {}, T0)).toThrow(/not allowed for session/)
    expect(() => apply(state, system, "automation.create", { name: "x", triggers: [{ type: "manual" }], body: steps }, T0)).toThrow(/not an internal op/)
  })

})
