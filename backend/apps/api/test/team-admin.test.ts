import { idFactory, MemoryRows, type Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { connectionsDomain } from "../src/domains/connections.ts"
import { runLimitMs, schedulerDomain, type SchedulerState } from "../src/domains/scheduler.ts"
import { runOf } from "../src/domains/scheduler-rows.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"

const userId = "user_cccccccccccccccccccc"
const personal: Principal = { identity: `session:${userId}`, kind: "session", user: userId, team: personalTeamIdFor(userId) }
/** A member of a shared (non-personal) team: no roles exist yet. */
const sharedMember: Principal = { identity: `session:${userId}`, kind: "session", user: userId, team: "team_dddddddddddddddddddd" }
let n = 0
/** The scheduler's rows ((g1)); the reducer reads them, `apply` commits its writes. */
const rows = new MemoryRows()
const ctx = (principal: Principal) => {
  const tx = `t${n++}`
  return { principal, now: 1_800_000_000_000, tx, newId: idFactory(tx), rows }
}

describe("team admin ops are personal-team only until roles exist", () => {
  // If this fails, someone let a shared team change team-wide settings without a role check.
  it("a shared-team member cannot change the integration policy or automation settings", () => {
    const pol = connectionsDomain.reduce(connectionsDomain.initial(), "integration.policy.set", { github: { scope: "installation" } }, ctx(sharedMember))
    expect(pol).toMatchObject({ ok: false, code: "team.roles_required" })
    const set = schedulerDomain.reduce(({ ...schedulerDomain.initial(), run_policy: { version: 0, runs_allowed: true } }), "automation.settings.set", { agent_run_default_seconds: 600 }, ctx(sharedMember))
    expect(set).toMatchObject({ ok: false, code: "team.roles_required" })
    expect(connectionsDomain.reduce(connectionsDomain.initial(), "integration.policy.set", { github: { scope: "installation" } }, ctx(personal)).ok).toBe(true)
  })
})

describe("agent run limit: built-in 24 h, team default, automation override", () => {
  it("applies the team default to agent runs and lets an automation budget override it", () => {
    let s: SchedulerState = ({ ...schedulerDomain.initial(), run_policy: { version: 0, runs_allowed: true } })
    const apply = (op: string, params: unknown) => {
      const r = schedulerDomain.reduce(s, op, params, ctx(personal))
      if (!r.ok) throw new Error(r.message)
      rows.apply(r.writes ?? [])
      s = r.state
      return r.value as any
    }
    const agent = { type: "agent_prompt", instructions: "do it", workspace: { mode: "fresh_worktree" }, conversation: "fresh" }
    const a = apply("automation.create", { name: "a", triggers: [{ type: "manual" }], body: agent })
    const r1 = apply("automation.run", { automation: a.id })
    expect(runLimitMs(runOf(rows, r1.id)!.body, runOf(rows, r1.id)!.wall_clock_seconds)).toBe(24 * 3600_000)
    apply("automation.settings.set", { agent_run_default_seconds: 2 * 3600 })
    const r2 = apply("automation.run", { automation: a.id })
    expect(runOf(rows, r2.id)!.wall_clock_seconds).toBe(7200)
    apply("automation.update", { automation: a.id, budget: { wall_clock_seconds: 600 } })
    const r3 = apply("automation.run", { automation: a.id })
    expect(runOf(rows, r3.id)!.wall_clock_seconds).toBe(600)
  })
})
