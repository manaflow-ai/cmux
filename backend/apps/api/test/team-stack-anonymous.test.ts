import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"
import { deliver, memberRow, mirroredTeam, PROJECT, stackWorld, teamIdOf, teamState, useStack } from "./team-stack-support.ts"

/**
 * The Hexclave browser SDK signs every cmux.com visitor up as a Stack anonymous user, and Stack gives
 * each one a sign-up personal team (about 3,000 a day in production, 2026-10-15). The webhook must
 * not mirror those teams: a team whose Stack members are all anonymous is never created here, and
 * an anonymous user is never provisioned into a mirrored team.
 */
describe("Stack anonymous users are not mirrored", { timeout: 60_000 }, () => {
  it("an anonymous visitor's sign-up personal team is never created", async () => {
    const w = stackWorld()
    const stackTeam = crypto.randomUUID()
    const visitor = crypto.randomUUID()
    await useStack(stackTeam, w)
    w.teams.set(stackTeam, "Personal Team")
    w.members.set(`${stackTeam}:${visitor}`, "")
    w.perms.set(`${stackTeam}:${visitor}`, ["$update_team", "team_admin"])
    w.anonymous.add(visitor)
    const created = await deliver("team.created", { id: stackTeam, display_name: "Personal Team", profile_image_url: null, created_at_millis: Date.now() })
    expect(created.status).toBe(200)
    expect(created.body).toMatchObject({ ok: true, outcome: "anonymous_team_ignored" })
    const joined = await deliver("team_membership.created", { team_id: stackTeam, user_id: visitor })
    expect(joined.body).toMatchObject({ ok: true, outcome: "member_anonymous" })
    expect((await teamState(teamIdOf(stackTeam))).team).toBeNull()
    expect(await memberRow(teamIdOf(stackTeam), userIdFor(PROJECT, visitor))).toBeNull()
  })

  it("a team with a signed-in member is mirrored without its anonymous members", async () => {
    const w = stackWorld()
    const stackTeam = crypto.randomUUID()
    const person = crypto.randomUUID()
    const visitor = crypto.randomUUID()
    await useStack(stackTeam, w)
    w.teams.set(stackTeam, "Acme")
    w.members.set(`${stackTeam}:${person}`, "Person")
    w.members.set(`${stackTeam}:${visitor}`, "")
    w.anonymous.add(visitor)
    expect((await deliver("team.created", { id: stackTeam, display_name: "Acme", profile_image_url: null, created_at_millis: Date.now() })).body).toMatchObject({ ok: true })
    expect((await teamState(teamIdOf(stackTeam))).team).toMatchObject({ kind: "stack", display_name: "Acme" })
    expect(await memberRow(teamIdOf(stackTeam), userIdFor(PROJECT, person))).toMatchObject({ display_name: "Person" })
    expect(await memberRow(teamIdOf(stackTeam), userIdFor(PROJECT, visitor))).toBeNull()
    expect((await teamState(teamIdOf(stackTeam))).member_count).toBe(1)
  })

  it("an anonymous user who joins a mirrored team is not provisioned", async () => {
    const t = await mirroredTeam()
    const visitor = crypto.randomUUID()
    t.w.members.set(`${t.stackTeam}:${visitor}`, "")
    t.w.anonymous.add(visitor)
    const r = await deliver("team_membership.created", { team_id: t.stackTeam, user_id: visitor })
    expect(r.body).toMatchObject({ ok: true, outcome: "member_anonymous" })
    expect(await memberRow(t.team, userIdFor(PROJECT, visitor))).toBeNull()
    expect(await memberRow(t.team, t.user)).not.toBeNull()
  })
})
