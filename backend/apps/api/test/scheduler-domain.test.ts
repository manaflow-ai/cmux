import { idFactory, type Principal, type ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { checkCron, nextFire } from "../src/cron.ts"
import { dispatchable, dueFires, matchingEventTriggers, MAX_FINISHED_RUNS, schedulerDomain, type SchedulerState } from "../src/domains/scheduler.ts"

const user: Principal = { identity: "session:user_aaaaaaaaaaaaaaaaaaaa", kind: "session", user: "user_aaaaaaaaaaaaaaaaaaaa", team: "team_aaaaaaaaaaaaaaaaaaaa" }
const system: Principal = { identity: "system:scheduler", kind: "system" }
const other: Principal = { identity: "session:user_bbbbbbbbbbbbbbbbbbbb", kind: "session", user: "user_bbbbbbbbbbbbbbbbbbbb", team: "team_bbbbbbbbbbbbbbbbbbbb" }

let txn = 0
const ctx = (principal: Principal, now: number): ReduceContext => {
  const tx = `tx${txn++}`
  return { principal, now, tx, newId: idFactory(tx) }
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
  it("accepts five fields in an IANA zone and computes the next instant", () => {
    expect(checkCron("*/5 * * * *", "UTC")).toEqual({ ok: true })
    expect(nextFire("*/5 * * * *", "UTC", T0)).toBe(Date.UTC(2026, 9, 2, 12, 5, 0))
    // 09:00 in Los Angeles is 16:00 UTC in October (PDT).
    expect(nextFire("0 9 * * *", "America/Los_Angeles", T0)).toBe(Date.UTC(2026, 9, 2, 16, 0, 0))
  })
  it("refuses seconds fields, unknown zones and expressions that never fire", () => {
    expect(checkCron("* * * * * *", "UTC").ok).toBe(false)
    expect(checkCron("* * * * *", "Mars/Olympus").ok).toBe(false)
    expect(checkCron("0 0 30 2 *", "UTC").ok).toBe(false)
  })
})

describe("SchedulerDO reducer", () => {
  const created = () => {
    const r = apply(schedulerDomain.initial(), user, "automation.create", { name: "hourly", triggers: [{ type: "cron", expr: "0 * * * *", tz: "UTC" }, { type: "manual" }, { type: "presence", when: "user_active" }], body: steps }, T0)
    return { state: r.state, a: r.value as any }
  }

  it("creates with owner, ids, schedule and trigger status", () => {
    const { state, a } = created()
    expect(state.owner).toBe(user.team)
    expect(a.id).toMatch(/^auto_[a-z0-9]{20}$/)
    expect(a.triggers.map((t: any) => [t.spec.type, t.status])).toEqual([["cron", "active"], ["manual", "active"], ["presence", "not_yet_supported"]])
    expect(a.next_run_at).toBe(Date.UTC(2026, 9, 2, 13, 0, 0))
    expect(a.concurrency).toEqual({ max: 1, on_limit: "queue" })
  })

  it("refuses bad cron, another team, and public calls to internal ops", () => {
    expect(() => apply(schedulerDomain.initial(), user, "automation.create", { name: "x", triggers: [{ type: "cron", expr: "nope", tz: "UTC" }], body: steps }, T0)).toThrow(/cron|field/)
    const { state } = created()
    expect(() => apply(state, other, "automation.list", {}, T0)).toThrow(/not this team/)
    expect(() => apply(state, user, "automation.fire", {}, T0)).toThrow(/not allowed for session/)
    expect(() => apply(state, system, "automation.create", { name: "x", triggers: [{ type: "manual" }], body: steps }, T0)).toThrow(/not an internal op/)
  })

  it("a fire creates one run and advances the schedule; the same slot again is stale", () => {
    const { state, a } = created()
    const slot = a.next_run_at as number
    expect(dueFires(state, slot)).toEqual([{ automation: a.id, trigger: a.triggers[0].id, scheduled_at: slot }])
    const r1 = apply(state, system, "automation.fire", { automation: a.id, trigger: a.triggers[0].id, scheduled_at: slot }, slot + 5)
    expect((r1.value as any).state).toBe("queued")
    expect(Object.keys(r1.state.runs)).toHaveLength(1)
    expect(r1.state.automations[a.id]!.next_run_at).toBe(slot + 3600_000)
    const r2 = apply(r1.state, system, "automation.fire", { automation: a.id, trigger: a.triggers[0].id, scheduled_at: slot }, slot + 6)
    expect(r2.changed).toBe(false)
    expect(r2.value).toEqual({ stale: true })
  })

  it("a late alarm fires a missed slot once, then resumes after now", () => {
    const { state, a } = created()
    const slot = a.next_run_at as number
    const late = slot + 5 * 3600_000 + 10
    const r = apply(state, system, "automation.fire", { automation: a.id, trigger: a.triggers[0].id, scheduled_at: slot }, late)
    expect(Object.keys(r.state.runs)).toHaveLength(1)
    expect(r.state.automations[a.id]!.next_run_at).toBe(slot + 6 * 3600_000)
  })

  it("concurrency queues by default and dispatches one at a time; skip records a visible skipped run", () => {
    let { state, a } = created()
    state = apply(state, user, "automation.run", { automation: a.id }, T0 + 1).state
    state = apply(state, user, "automation.run", { automation: a.id }, T0 + 2).state
    expect(dispatchable(state)).toHaveLength(1)
    const first = dispatchable(state)[0]!
    state = apply(state, system, "run.dispatched", { run: first.id }, T0 + 3).state
    expect(dispatchable(state)).toHaveLength(0)
    state = apply(state, system, "run.report", { run: first.id, state: "succeeded", step: 0 }, T0 + 4).state
    expect(dispatchable(state).map((r) => r.id)).not.toContain(first.id)
    expect(dispatchable(state)).toHaveLength(1)

    state = apply(state, user, "automation.update", { automation: a.id, concurrency: { max: 1, on_limit: "skip" } }, T0 + 5).state
    const skipped = apply(state, user, "automation.run", { automation: a.id }, T0 + 6)
    expect((skipped.value as any).state).toBe("skipped")
    expect((skipped.value as any).error.code).toBe("concurrency.limit")
  })

  it("terminal states are final and late reports change nothing", () => {
    let { state, a } = created()
    const run = apply(state, user, "automation.run", { automation: a.id }, T0 + 1)
    state = run.state
    const id = (run.value as any).id
    state = apply(state, system, "run.report", { run: id, state: "failed", step: -1, error: { code: "x", message: "y" } }, T0 + 2).state
    const late = apply(state, system, "run.report", { run: id, state: "running", step: 3 }, T0 + 3)
    expect(late.changed).toBe(false)
    expect(late.state.runs[id]!.state).toBe("failed")
  })

  it("update keeps unchanged trigger ids, bumps version, and a no-op update changes nothing", () => {
    const { state, a } = created()
    const same = apply(state, user, "automation.update", { automation: a.id, name: "hourly" }, T0 + 1)
    expect(same.changed).toBe(false)
    const r = apply(state, user, "automation.update", { automation: a.id, triggers: [{ type: "manual" }, { type: "webhook" }] }, T0 + 1)
    const next = r.value as any
    expect(next.version).toBe(2)
    expect(next.triggers[0].id).toBe(a.triggers[1].id)
    expect(next.next_run_at).toBeNull()
    expect(() => apply(r.state, user, "automation.update", { automation: a.id, expected_version: 1, name: "z" }, T0 + 2)).toThrow(/expected_version/)
  })

  it("disable stops fires; enable reschedules from now instead of firing missed slots", () => {
    const { state, a } = created()
    const off = apply(state, user, "automation.update", { automation: a.id, enabled: false }, T0 + 1).state
    expect(dueFires(off, T0 + 10 * 3600_000)).toEqual([])
    const later = T0 + 10 * 3600_000
    const on = apply(off, user, "automation.update", { automation: a.id, enabled: true }, later).state
    expect(on.automations[a.id]!.next_run_at).toBe(Date.UTC(2026, 9, 2, 23, 0, 0))
  })

  it("continue schedules the next run after the cooldown until the goal is met or max_runs", () => {
    let state = schedulerDomain.initial()
    const c = apply(state, user, "automation.create", { name: "loop", triggers: [{ type: "manual" }, { type: "continue", until: ["goal_met"], cooldown_seconds: 60, max_runs: 3 }], body: steps }, T0)
    state = c.state
    const a = c.value as any
    const cont = a.triggers[1].id
    let run = apply(state, user, "automation.run", { automation: a.id }, T0 + 1)
    state = apply(run.state, system, "run.report", { run: (run.value as any).id, state: "succeeded", step: 0 }, T0 + 2).state
    expect(state.automations[a.id]!.next_run_at).toBe(T0 + 2 + 60_000)
    // Continue fires until max_runs (3 chained runs after the manual one).
    for (let i = 1; i <= 3; i++) {
      const slot = state.automations[a.id]!.next_run_at!
      run = apply(state, system, "automation.fire", { automation: a.id, trigger: cont, scheduled_at: slot }, slot)
      expect(state.automations[a.id]!.triggers[1]!.next_at).toBe(slot)
      state = apply(run.state, system, "run.report", { run: (run.value as any).id, state: "succeeded", step: 0 }, slot + 10).state
    }
    expect(state.chains[cont]).toBe(3)
    expect(state.automations[a.id]!.next_run_at).toBeNull()

    // A new manual run starts a new chain; goal_met stops it.
    run = apply(state, user, "automation.run", { automation: a.id }, T0 + 9_000_000)
    state = apply(run.state, system, "run.report", { run: (run.value as any).id, state: "succeeded", step: 0, outcome: { goal_met: true } }, T0 + 9_000_001).state
    expect(state.automations[a.id]!.next_run_at).toBeNull()
  })

  it("disabling or deleting cancels queued runs that have no Workflow yet", () => {
    let { state, a } = created()
    state = apply(state, user, "automation.update", { automation: a.id, concurrency: { max: 1, on_limit: "queue" } }, T0).state
    const r1 = apply(state, user, "automation.run", { automation: a.id }, T0 + 1)
    state = apply(r1.state, system, "run.dispatched", { run: (r1.value as any).id }, T0 + 2).state
    const r2 = apply(state, user, "automation.run", { automation: a.id }, T0 + 3)
    state = apply(r2.state, user, "automation.update", { automation: a.id, enabled: false }, T0 + 4).state
    expect(state.runs[(r2.value as any).id]!.state).toBe("cancelled")
    expect(state.runs[(r1.value as any).id]!.state).toBe("queued")
    const r3 = apply(state, user, "automation.run", { automation: a.id }, T0 + 5)
    state = apply(r3.state, user, "automation.delete", { automation: a.id }, T0 + 6).state
    expect(state.runs[(r3.value as any).id]!).toMatchObject({ state: "cancelled", error: { code: "automation.stopped" } })
  })

  it("integration events match connection, pattern and filters, and private connections only start their creator's automations", () => {
    const conn = "conn_aaaaaaaaaaaaaaaaaaaa"
    const r = apply(schedulerDomain.initial(), user, "automation.create", {
      name: "on pr",
      triggers: [{ type: "event", source: "integration", connection: conn, event: "pull_request.*", filter: { "repository.full_name": "manaflow-ai/cmux" } }],
      body: steps
    }, T0)
    const ev = (event: string, repo: string, sharing: "private" | "team", created_by: string) => ({ connection: conn, event, payload: { repository: { full_name: repo } }, sharing, created_by })
    expect(matchingEventTriggers(r.state, ev("pull_request.opened", "manaflow-ai/cmux", "private", user.user!))).toHaveLength(1)
    expect(matchingEventTriggers(r.state, ev("push", "manaflow-ai/cmux", "private", user.user!))).toHaveLength(0)
    expect(matchingEventTriggers(r.state, ev("pull_request.opened", "other/repo", "private", user.user!))).toHaveLength(0)
    expect(matchingEventTriggers(r.state, ev("pull_request.opened", "manaflow-ai/cmux", "private", "user_bbbbbbbbbbbbbbbbbbbb"))).toHaveLength(0)
    expect(matchingEventTriggers(r.state, ev("pull_request.opened", "manaflow-ai/cmux", "team", "user_bbbbbbbbbbbbbbbbbbbb"))).toHaveLength(1)
    // Without a connection an integration event trigger is stored but not fired.
    const loose = apply(r.state, user, "automation.create", { name: "x", triggers: [{ type: "event", source: "integration", event: "push" }], body: steps }, T0)
    expect((loose.value as any).triggers[0].status).toBe("not_yet_supported")
  })

  it("a run gets its deadline even when a report arrives before run.dispatched", () => {
    let { state, a } = created()
    const r = apply(state, user, "automation.run", { automation: a.id }, T0)
    const id = (r.value as any).id
    state = apply(r.state, system, "run.report", { run: id, state: "running", step: -1 }, T0 + 10).state
    expect(state.runs[id]!.deadline_at).toBe(T0 + 10 + 60 * 60_000)
    const late = apply(state, system, "run.dispatched", { run: id }, T0 + 20)
    expect(late.changed).toBe(false)
    expect(late.state.runs[id]!.deadline_at).toBe(T0 + 10 + 60 * 60_000)
  })

  it("keeps every active run and only the newest finished runs", () => {
    let { state, a } = created()
    state = apply(state, user, "automation.update", { automation: a.id, concurrency: { max: 10, on_limit: "queue" } }, T0).state
    const active = apply(state, user, "automation.run", { automation: a.id }, T0)
    state = active.state
    for (let i = 0; i < MAX_FINISHED_RUNS + 5; i++) {
      const r = apply(state, user, "automation.run", { automation: a.id }, T0 + 1 + i)
      state = apply(r.state, system, "run.report", { run: (r.value as any).id, state: "succeeded", step: 0 }, T0 + 1 + i).state
    }
    const runs = Object.values(state.runs)
    expect(runs.filter((r) => r.state === "succeeded")).toHaveLength(MAX_FINISHED_RUNS)
    expect(state.runs[(active.value as any).id]).toBeDefined()
  })
})
