import { describe, expect, it } from "vitest"
import { userDomain, type UserState } from "../src/domains/user.ts"

/** (f) follow-up: the user-state team index is bounded and typed. */
const TEAM = (i: number) => `team_${String(i).padStart(20, "0")}`
const sys = (team: string) => ({ principal: { identity: `system:team:${team}`, kind: "system" as const }, now: 1, tx: `t${team}`, newId: (p: string) => `${p}_1` })
const run = (s: UserState, team: string, role: string | null, kind = "stack") => userDomain.reduce(s, "user.team_index", { team, role, kind }, sys(team))

describe("user team index", () => {
  it("refuses unknown roles and kinds, and keeps at most 1,000 teams", () => {
    let s: UserState = { user: null, installs: {}, grants: {} }
    expect(run(s, TEAM(1), "superuser")).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(run(s, TEAM(1), "member", "galaxy")).toMatchObject({ ok: false, code: "validation.invalid" })
    for (let i = 0; i < 1000; i++) {
      const r = run(s, TEAM(i), "member")
      if (!r.ok) throw new Error(r.code)
      s = r.state
    }
    expect(run(s, TEAM(1000), "member")).toMatchObject({ ok: false, code: "user.team_index_full" })
    // A change to a team already indexed still applies; a removal frees a slot.
    expect(run(s, TEAM(5), "admin")).toMatchObject({ ok: true })
    const r = run(s, TEAM(5), null)
    if (!r.ok) throw new Error(r.code)
    expect(run(r.state, TEAM(1000), "member")).toMatchObject({ ok: true })
  })
})
