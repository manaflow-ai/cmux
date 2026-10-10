import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { teamVmDomain } from "../src/domains/team-vm.ts"
import { userIdFor } from "../src/domains/user.ts"
import { deliver, memberRow, mirroredTeam, PROJECT, stackWorld, teamIdOf, teamState, useStack } from "./team-stack-support.ts"

/**
 * cx-3bi.43 live staging finding: Stack sends no team_membership.created for a team's creator
 * (creator_user_id) or for the sign-up personal team, so a mirrored team started with no members.
 * A team event now reads Stack's member list and mirrors it (adds and removals). And a removed
 * member's team VM wake lease ends with the removal notice.
 */
describe("Stack team member list sync (cx-3bi.43)", { timeout: 60_000 }, () => {
  it("a team.created whose creator never gets a membership event ends with the creator as a member", async () => {
    const w = stackWorld()
    const stackTeam = crypto.randomUUID()
    const creator = crypto.randomUUID()
    await useStack(stackTeam, w)
    w.teams.set(stackTeam, "Creator's team")
    w.members.set(`${stackTeam}:${creator}`, "Creator")
    const r = await deliver("team.created", { id: stackTeam, display_name: "Creator's team", profile_image_url: null, created_at_millis: Date.now() })
    expect(r.status).toBe(200)
    expect(await memberRow(teamIdOf(stackTeam), userIdFor(PROJECT, creator))).toMatchObject({ role: "member", display_name: "Creator" })
    expect((await teamState(teamIdOf(stackTeam))).member_count).toBe(1)
  })

  it("a team.updated mirrors Stack's member list: a member Stack no longer lists is removed, a new one is added", async () => {
    const t = await mirroredTeam()
    const newcomer = crypto.randomUUID()
    t.w.members.delete(`${t.stackTeam}:${t.stackUser}`)
    t.w.members.set(`${t.stackTeam}:${newcomer}`, "Newcomer")
    expect((await deliver("team.updated", { id: t.stackTeam, display_name: "Acme", profile_image_url: null, created_at_millis: 0 })).status).toBe(200)
    expect(await memberRow(t.team, t.user)).toBeNull()
    expect(await memberRow(t.team, userIdFor(PROJECT, newcomer))).toMatchObject({ display_name: "Newcomer" })
  })

})
