import { describe, expect, it } from "vitest"
import { rolesTeam, STACK_ADMIN, STACK_MEMBER } from "./team-roles-support.ts"
import { deliver, memberRow } from "./team-stack-support.ts"
import { closeTeamSocket, listenToOwnerWire, provisionRole } from "./team-role-socket-support.ts"
import { deliverRoleNotices, openCloudSockets, redeliverRoleNotice } from "./cloud-role-socket-support.ts"

describe("Cloud wire membership authority", { timeout: 60_000 }, () => {
  it.each(["owner", "member", "guest"] as const)("a committed admin-to-%s change retires idle Cloud sockets through the outbox", async (role) => {
    const team = await rolesTeam(), member = await team.join("Member", [...STACK_MEMBER, "cmux:admin"])
    await deliverRoleNotices(team.team)
    const socket = await listenToOwnerWire(member.token, team.team, "cloud")
    const owner = await listenToOwnerWire(team.creator.token, team.team, "cloud")
    try {
      expect(await openCloudSockets(team.team, member.user)).toBe(1)
      team.w.perms.set(`${team.stackTeam}:${member.stackUser}`, role === "owner" ? STACK_ADMIN : role === "guest" ? ["cmux:guest"] : STACK_MEMBER)
      expect((await deliver(role === "member" ? "team_permission.deleted" : "team_permission.created", {
        id: role === "owner" ? "$delete_team" : role === "guest" ? "cmux:guest" : "cmux:admin", team_id: team.stackTeam, user_id: member.stackUser
      })).status).toBe(200)
      expect(await memberRow(team.team, member.user)).toMatchObject({ role })
      await deliverRoleNotices(team.team)
      expect(await openCloudSockets(team.team, member.user)).toBe(0)
      expect(await openCloudSockets(team.team, team.creator.user)).toBe(1)
    } finally { closeTeamSocket(socket); closeTeamSocket(owner) }
  })

  it("a delayed or replayed notice preserves a newly admitted connection and retires the older one", async () => {
    const team = await rolesTeam(), member = await team.join("Member", [...STACK_MEMBER, "cmux:admin"])
    await deliverRoleNotices(team.team)
    const old = await listenToOwnerWire(member.token, team.team, "cloud")
    team.w.perms.set(`${team.stackTeam}:${member.stackUser}`, STACK_MEMBER)
    const key = crypto.randomUUID()
    expect((await provisionRole(team.team, member.user, "member", key)).frames.some((f) => f.t === "reject")).toBe(false)
    const fresh = await listenToOwnerWire(member.token, team.team, "cloud")
    try {
      await deliverRoleNotices(team.team)
      expect(await openCloudSockets(team.team, member.user)).toBe(1)
      expect((await provisionRole(team.team, member.user, "member", key)).frames.find((f) => f.t === "result")?.replayed).toBe(true)
      await redeliverRoleNotice(team.team, member.user)
      await redeliverRoleNotice(team.team, member.user)
      expect(await openCloudSockets(team.team, member.user)).toBe(1)
    } finally { closeTeamSocket(old); closeTeamSocket(fresh) }
  })

  it("returning to the original role still retires the original connection", async () => {
    const team = await rolesTeam(), member = await team.join("Member", [...STACK_MEMBER, "cmux:admin"])
    await deliverRoleNotices(team.team)
    const old = await listenToOwnerWire(member.token, team.team, "cloud")
    try {
      for (const role of ["member", "admin"]) {
        expect((await provisionRole(team.team, member.user, role, crypto.randomUUID())).frames.some((f) => f.t === "reject")).toBe(false)
      }
      expect(await memberRow(team.team, member.user)).toMatchObject({ role: "admin" })
      await deliverRoleNotices(team.team)
      expect(await openCloudSockets(team.team, member.user)).toBe(0)
    } finally { closeTeamSocket(old) }
  })

  it("another team's socket and a fresh connection ignore untrusted or mismatched notices", async () => {
    const team = await rolesTeam(), other = await rolesTeam(), member = await team.join("Member", [...STACK_MEMBER, "cmux:admin"])
    other.w.members.set(`${other.stackTeam}:${member.stackUser}`, "Member")
    other.w.perms.set(`${other.stackTeam}:${member.stackUser}`, STACK_MEMBER)
    expect((await deliver("team_membership.created", { team_id: other.stackTeam, user_id: member.stackUser })).status).toBe(200)
    await deliverRoleNotices(team.team); await deliverRoleNotices(other.team)
    const first = await listenToOwnerWire(member.token, team.team, "cloud"), second = await listenToOwnerWire(member.token, other.team, "cloud")
    try {
      await redeliverRoleNotice(team.team, member.user, `team:${other.team}`)
      await redeliverRoleNotice(team.team, member.user, `team:${team.team}`, other.team)
      expect(await openCloudSockets(team.team, member.user)).toBe(1)
      expect((await provisionRole(team.team, member.user, "member", crypto.randomUUID())).frames.some((f) => f.t === "reject")).toBe(false)
      await deliverRoleNotices(team.team)
      expect(await openCloudSockets(team.team, member.user)).toBe(0)
      expect(await openCloudSockets(other.team, member.user)).toBe(1)
    } finally { closeTeamSocket(first); closeTeamSocket(second) }
  })

  it("same-role syncs, refused writes and untrusted notices preserve current connections", async () => {
    const team = await rolesTeam(), member = await team.join("Member", STACK_MEMBER)
    await deliverRoleNotices(team.team)
    const socket = await listenToOwnerWire(member.token, team.team, "cloud")
    try {
      expect((await provisionRole(team.team, member.user, "member", crypto.randomUUID())).frames.some((f) => f.t === "reject")).toBe(false)
      expect((await provisionRole(team.team, member.user, "guest", crypto.randomUUID(),
        { kind: "session", identity: `session:${member.user}`, user: member.user, team: team.team })).frames.find((f) => f.t === "reject")?.code).toBe("auth.forbidden")
      await deliverRoleNotices(team.team)
      await redeliverRoleNotice(team.team, member.user, "team:untrusted")
      await redeliverRoleNotice(team.team, member.user, `team:${team.team}`, "team:mismatched")
      expect(await openCloudSockets(team.team, member.user)).toBe(1)
    } finally { closeTeamSocket(socket) }
  })
})
