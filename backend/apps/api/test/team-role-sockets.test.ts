import { describe, expect, it } from "vitest"
import { rolesTeam, STACK_ADMIN, STACK_MEMBER } from "./team-roles-support.ts"
import { deliver, memberRow } from "./team-stack-support.ts"
import { closeTeamSocket, listenToTeam, openTeamSockets, provisionRole } from "./team-role-socket-support.ts"

describe("team role changes retire their old wire authority", { timeout: 60_000 }, () => {
  it.each(["owner", "member", "guest"] as const)("an idle admin socket closes after its role becomes %s", async (role) => {
    const team = await rolesTeam()
    const member = await team.join("Member", [...STACK_MEMBER, "cmux:admin"])
    const memberSocket = await listenToTeam(member.token, team.team)
    const ownerSocket = await listenToTeam(team.creator.token, team.team)
    try {
      expect(await openTeamSockets(team.team, member.user)).toBe(1)
      team.w.perms.set(`${team.stackTeam}:${member.stackUser}`, role === "owner" ? STACK_ADMIN : role === "guest" ? ["cmux:guest"] : STACK_MEMBER)
      const event = role === "member" ? "team_permission.deleted" : "team_permission.created"
      expect((await deliver(event, { id: role === "owner" ? "$delete_team" : role === "guest" ? "cmux:guest" : "cmux:admin", team_id: team.stackTeam, user_id: member.stackUser })).status).toBe(200)
      expect(await memberRow(team.team, member.user)).toMatchObject({ role })
      expect(await openTeamSockets(team.team, member.user)).toBe(0)
      expect(await openTeamSockets(team.team, team.creator.user)).toBe(1)
    } finally { closeTeamSocket(memberSocket); closeTeamSocket(ownerSocket) }
  })

  it("the same member's socket in another team stays open", async () => {
    const team = await rolesTeam(), other = await rolesTeam()
    const member = await team.join("Member", [...STACK_MEMBER, "cmux:admin"])
    other.w.members.set(`${other.stackTeam}:${member.stackUser}`, "Member")
    other.w.perms.set(`${other.stackTeam}:${member.stackUser}`, STACK_MEMBER)
    expect((await deliver("team_membership.created", { team_id: other.stackTeam, user_id: member.stackUser })).status).toBe(200)
    const first = await listenToTeam(member.token, team.team), second = await listenToTeam(member.token, other.team)
    try {
      team.w.perms.set(`${team.stackTeam}:${member.stackUser}`, STACK_MEMBER)
      expect((await deliver("team_permission.deleted", { id: "cmux:admin", team_id: team.stackTeam, user_id: member.stackUser })).status).toBe(200)
      expect(await memberRow(team.team, member.user)).toMatchObject({ role: "member" })
      expect(await openTeamSockets(team.team, member.user)).toBe(0)
      expect(await openTeamSockets(other.team, member.user)).toBe(1)
    } finally { closeTeamSocket(first); closeTeamSocket(second) }
  })

  it("a replayed role change and a same-role sync preserve a newly admitted socket", async () => {
    const team = await rolesTeam()
    const member = await team.join("Member", [...STACK_MEMBER, "cmux:admin"])
    team.w.perms.set(`${team.stackTeam}:${member.stackUser}`, STACK_MEMBER)
    const key = crypto.randomUUID()
    const changed = await provisionRole(team.team, member.user, "member", key)
    expect(changed.frames.find((f) => f.t === "result")?.replayed).toBe(false)
    expect(await memberRow(team.team, member.user)).toMatchObject({ role: "member" })
    const socket = await listenToTeam(member.token, team.team)
    try {
      const replay = await provisionRole(team.team, member.user, "member", key)
      expect(replay.frames.find((f) => f.t === "result")?.replayed).toBe(true)
      expect(await openTeamSockets(team.team, member.user)).toBe(1)
      const same = await provisionRole(team.team, member.user, "member", crypto.randomUUID())
      expect(same.frames.some((f) => f.t === "reject")).toBe(false)
      expect(await openTeamSockets(team.team, member.user)).toBe(1)
    } finally { closeTeamSocket(socket) }
  })

  it("an untrusted membership op cannot close another member's socket", async () => {
    const team = await rolesTeam()
    const member = await team.join("Member", STACK_MEMBER)
    const ownerSocket = await listenToTeam(team.creator.token, team.team)
    try {
      const rejected = await provisionRole(team.team, team.creator.user, "guest", crypto.randomUUID(),
        { kind: "session", identity: `session:${member.user}`, user: member.user, team: team.team })
      expect(rejected.frames.find((f) => f.t === "reject")?.code).toBe("auth.forbidden")
      expect(await openTeamSockets(team.team, team.creator.user)).toBe(1)
    } finally { closeTeamSocket(ownerSocket) }
  })
})
