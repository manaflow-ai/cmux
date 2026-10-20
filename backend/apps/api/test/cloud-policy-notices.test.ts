import type { ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { teamDomain, type TeamState } from "../src/domains/team.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"

describe("Cloud policy notice production", () => {
  it.each(["copied", "unchanged", "managed"])("integration seed publishes only a changed authority version: %s", (mode) => {
    const user = "user_" + "1".repeat(20), team = personalTeamIdFor(user)
    const state: TeamState = { team: { id: team, kind: "personal", display_name: "Personal" },
      members: { [user]: { user, role: "owner", display_name: "Owner" } }, hosts: {} }
    const context: ReduceContext = { principal: { identity: "system:connection", kind: "system", user, team },
      tx: "a".repeat(22), now: 1000, newId: (prefix) => `${prefix}_${"1".repeat(20)}` }
    const result = teamDomain.reduce(state, "team.policy.integration_seed", {
      policy: { allowed_providers: null, github: { scope: mode === "copied" ? "installation" : "linking_user_repos",
        require_org_admin: false, repo_allowlist: null } }, ...(mode === "managed" ? { managed_by: "sso" } : {})
    }, context)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    const notices = (result.outbox ?? []).filter((item) => item.kind === "team.authority.changed")
    if (mode === "copied") {
      expect(notices).toEqual([{ kind: "team.authority.changed", entity: `team-authority:${team}:${context.tx}`,
        payload: { team }, target: { class: "CloudDO", name: team, coalesce: "team-authority" } }])
      expect((result.outbox ?? []).length).toBeGreaterThan(1) // The policy audit remains in the same commit.
      const replay = teamDomain.reduce(result.state, "team.policy.integration_seed", {
        policy: { allowed_providers: null, github: { scope: "installation", require_org_admin: false, repo_allowlist: null } }
      }, context)
      expect(replay.ok && (replay.outbox ?? []).some((item) => item.kind === "team.authority.changed")).toBe(false)
    } else { expect(notices).toEqual([]) }
  })
})
