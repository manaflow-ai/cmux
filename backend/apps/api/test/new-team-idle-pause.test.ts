import type { ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { teamDomain, type TeamState } from "../src/domains/team.ts"
import { cloudPolicyOf, currentPolicy } from "../src/domains/team-policy.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"

// A team made from now on starts with cloud.idlePause on; a team made before keeps what it stored (Leo, 2026-11-23:
// "well, if this is the whole point of the product, then obviously, yes.").

const USER = "user_00000000000000000001"
const PERSONAL = personalTeamIdFor(USER)
const STACK_TEAM = "team_00000000000000000009"

let txn = 0
const session = (): ReduceContext => ({
  principal: { identity: `user:${USER}`, user: USER, team: PERSONAL, kind: "session", display_name: "New Person" },
  now: 1_000 + txn,
  tx: `tx${++txn}`,
  newId: (p) => `${p}_${String(txn).padStart(20, "0")}`
})
const system = (): ReduceContext => ({
  principal: { identity: "system:team", kind: "system" },
  now: 1_000 + txn,
  tx: `tx${++txn}`,
  newId: (p) => `${p}_${String(txn).padStart(20, "0")}`
})
const okState = (r: ReturnType<typeof teamDomain.reduce>): TeamState => {
  if (!r.ok) throw new Error(`refused: ${JSON.stringify(r)}`)
  return r.state
}

describe("a new team's idle pause", () => {
  it("a fresh personal team reads idle pause on, in mode default", () => {
    const s = okState(teamDomain.reduce(teamDomain.initial(), "team.ensure_personal", {}, session()))
    expect(cloudPolicyOf(s).idle_pause).toBe(true)
    expect(currentPolicy(s).values["cloud.idlePause"]).toEqual({ value: true, mode: "default" })
    expect(currentPolicy(s).version).toBe(0)
  })

  it("a fresh Stack team reads idle pause on", () => {
    const s = okState(teamDomain.reduce(teamDomain.initial(), "team.stack_mirror", { team: STACK_TEAM, stack_team: "stack-uuid-1", display_name: "Acme" }, system()))
    expect(cloudPolicyOf(s).idle_pause).toBe(true)
  })

  it("the per-team switch still turns it off, and the next sign-in does not turn it back on", () => {
    const made = okState(teamDomain.reduce(teamDomain.initial(), "team.ensure_personal", {}, session()))
    const off = okState(
      teamDomain.reduce(made, "team.policy.update", { changes: [{ key: "cloud.idlePause", value: { value: false, mode: "default" } }], expected_version: 0 }, session())
    )
    expect(cloudPolicyOf(off).idle_pause).toBe(false)
    const again = teamDomain.reduce(off, "team.ensure_personal", {}, session())
    expect(again.ok && cloudPolicyOf(again.state).idle_pause).toBe(false)
  })

  it("a team made before keeps its stored setting: no key stays off, through a sign-in and a Stack mirror", () => {
    const personal: TeamState = { team: { id: PERSONAL, kind: "personal", display_name: "Old" }, member_count: 1, host_count: 0 }
    const renamed = teamDomain.reduce(personal, "team.ensure_personal", {}, session())
    expect(renamed.ok && cloudPolicyOf(renamed.state).idle_pause).toBe(false)
    const stack: TeamState = { team: { id: STACK_TEAM, kind: "stack", display_name: "Old", stack_team: "stack-uuid-1" }, member_count: 0, host_count: 0 }
    const mirrored = teamDomain.reduce(stack, "team.stack_mirror", { team: STACK_TEAM, stack_team: "stack-uuid-1", display_name: "Renamed" }, system())
    expect(mirrored.ok && cloudPolicyOf(mirrored.state).idle_pause).toBe(false)
  })
})
