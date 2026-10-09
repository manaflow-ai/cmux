import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"
import { call, deliver, memberRow, PROJECT, stackWorld, teamIdOf, useStack } from "./team-stack-support.ts"
import { sessionToken } from "./team-ssh-support.ts"

/**
 * cx-3bi.4 (spec H5, H12): team roles guest/member/admin/owner/billing are bundles of default
 * grants that TeamDO checks. A Stack team's roles come from Stack's team permissions, read again on
 * every sync: the Stack team creator (Stack's default `team_admin`, which contains `$delete_team`)
 * is the owner, and a change in Stack changes the cmux role.
 */

/** What Stack lists (recursive) for its default team_admin and team_member permissions. */
const STACK_ADMIN = ["team_admin", "$update_team", "$delete_team", "$read_members", "$remove_members", "$invite_members", "$manage_api_keys"]
const STACK_MEMBER = ["team_member", "$read_members", "$invite_members"]

const codeOf = (r: { body: any }) => r.body?.error?.code ?? r.body?.code
const op = (token: string, name: string, params: unknown, team: string) => call(token, "/v1/ops", { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" }, team)
const read = (token: string, name: string, params: unknown, team: string) => call(token, "/v1/read", { op: name, params }, team)

/** A Stack team whose creator holds Stack's team_admin; Stack sends no membership event for the creator, the team event lists them. */
const rolesTeam = async () => {
  const w = stackWorld()
  const stackTeam = crypto.randomUUID()
  const team = teamIdOf(stackTeam)
  await useStack(stackTeam, w)
  w.teams.set(stackTeam, "Roles")
  const join = async (name: string, permissions: Array<string>, event = true) => {
    const stackUser = crypto.randomUUID()
    w.members.set(`${stackTeam}:${stackUser}`, name)
    w.perms.set(`${stackTeam}:${stackUser}`, permissions)
    const token = await sessionToken(stackUser, name)
    expect((await call(token, "/v1/ops", { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })).body.ok).toBe(true)
    if (event) expect((await deliver("team_membership.created", { team_id: stackTeam, user_id: stackUser })).status).toBe(200)
    return { stackUser, user: userIdFor(PROJECT, stackUser), token }
  }
  const creator = await join("Creator", STACK_ADMIN, false)
  expect((await deliver("team.created", { id: stackTeam, display_name: "Roles", profile_image_url: null, created_at_millis: Date.now() })).status).toBe(200)
  return { w, stackTeam, team, creator, join }
}

describe("team roles (cx-3bi.4)", { timeout: 60_000 }, () => {
  it("the Stack team creator becomes owner and may accept a team VM taint; a member may not", async () => {
    const t = await rolesTeam()
    expect(await memberRow(t.team, t.creator.user)).toMatchObject({ role: "owner" })
    const member = await t.join("Member", STACK_MEMBER)
    expect(await memberRow(t.team, member.user)).toMatchObject({ role: "member" })
    // The owner passes the role check (the VM record answers: nothing is tainted); the member is refused before it.
    const owner = await op(t.creator.token, "team_vm.taint.accept", { epoch: 1, users: [] }, t.team)
    expect(codeOf(owner)).not.toBe("auth.forbidden")
    expect(codeOf(owner)).toBeTruthy()
    expect(codeOf(await op(member.token, "team_vm.taint.accept", { epoch: 1, users: [] }, t.team))).toBe("auth.forbidden")
  })

  it("a demotion in Stack removes owner rights at the next sync; a promotion gives admin", async () => {
    const t = await rolesTeam()
    const member = await t.join("Member", STACK_MEMBER)
    // Stack takes team_admin away from the creator: the permission event re-reads that member.
    t.w.perms.set(`${t.stackTeam}:${t.creator.stackUser}`, STACK_MEMBER)
    expect((await deliver("team_permission.deleted", { id: "team_admin", team_id: t.stackTeam, user_id: t.creator.stackUser })).status).toBe(200)
    expect(await memberRow(t.team, t.creator.user)).toMatchObject({ role: "member" })
    expect(codeOf(await op(t.creator.token, "team_vm.taint.accept", { epoch: 1, users: [] }, t.team))).toBe("auth.forbidden")
    // A team event re-reads every member: a custom cmux:admin permission makes an admin.
    t.w.perms.set(`${t.stackTeam}:${member.stackUser}`, [...STACK_MEMBER, "cmux:admin"])
    expect((await deliver("team.updated", { id: t.stackTeam, display_name: "Roles", profile_image_url: null, created_at_millis: 0 })).status).toBe(200)
    expect(await memberRow(t.team, member.user)).toMatchObject({ role: "admin" })
    expect(codeOf(await op(member.token, "team_vm.taint.accept", { epoch: 1, users: [] }, t.team))).not.toBe("auth.forbidden")
  })

  it("only an owner removes an admin; an admin removes a member; nobody removes an owner here", async () => {
    const t = await rolesTeam()
    const a1 = await t.join("Admin One", [...STACK_MEMBER, "cmux:admin"])
    const a2 = await t.join("Admin Two", [...STACK_MEMBER, "cmux:admin"])
    const m = await t.join("Member", STACK_MEMBER)
    expect(await memberRow(t.team, a2.user)).toMatchObject({ role: "admin" })
    expect(codeOf(await op(a1.token, "team.members.remove", { user: a2.user }, t.team))).toBe("auth.forbidden")
    expect(await memberRow(t.team, a2.user)).toMatchObject({ role: "admin" })
    expect(t.w.removedInStack).toEqual([])
    const byAdmin = await op(a1.token, "team.members.remove", { user: m.user }, t.team)
    expect(byAdmin.body, JSON.stringify(byAdmin.body)).toMatchObject({ ok: true, value: { user: m.user, removed: true } })
    expect(await memberRow(t.team, m.user)).toBeNull()
    expect(t.w.removedInStack).toEqual([`${t.stackTeam}:${m.stackUser}`])
    const byOwner = await op(t.creator.token, "team.members.remove", { user: a2.user }, t.team)
    expect(byOwner.body, JSON.stringify(byOwner.body)).toMatchObject({ ok: true, value: { removed: true } })
    expect(await memberRow(t.team, a2.user)).toBeNull()
    // An owner is demoted in Stack first; a member removes nobody.
    expect(codeOf(await op(a1.token, "team.members.remove", { user: t.creator.user }, t.team))).toBe("auth.forbidden")
    const m2 = await t.join("Member Two", STACK_MEMBER)
    expect(codeOf(await op(m2.token, "team.members.remove", { user: a1.user }, t.team))).toBe("auth.forbidden")
  })

  it("a guest uses no seat and reaches no team resource", async () => {
    const t = await rolesTeam()
    const seats = async () => (await read(t.creator.token, "team.members.list", {}, t.team)).body.value
    expect(await seats()).toMatchObject({ member_count: 1, seat_count: 1 })
    const guest = await t.join("Guest", [...STACK_MEMBER, "cmux:guest"])
    expect(await memberRow(t.team, guest.user)).toMatchObject({ role: "guest" })
    expect(await seats()).toMatchObject({ member_count: 2, seat_count: 1 })
    await t.join("Member", STACK_MEMBER)
    expect(await seats()).toMatchObject({ member_count: 3, seat_count: 2 })
    // No default grants: neither the directory (TeamDO) nor the team VM (TeamVmDO).
    expect(codeOf(await read(guest.token, "team.directory", {}, t.team))).toBe("auth.forbidden")
    expect(codeOf(await read(guest.token, "team_vm.status", {}, t.team))).toBe("auth.forbidden")
    // Demoted to guest in Stack: the seat goes at the next sync.
    const later = await t.join("Later", STACK_MEMBER)
    expect(await seats()).toMatchObject({ member_count: 4, seat_count: 3 })
    t.w.perms.set(`${t.stackTeam}:${later.stackUser}`, ["cmux:guest"])
    expect((await deliver("team_permission.created", { id: "cmux:guest", team_id: t.stackTeam, user_id: later.stackUser })).status).toBe(200)
    expect(await seats()).toMatchObject({ member_count: 4, seat_count: 2 })
  })

  it("the billing role reads only billing audit records; owners read every record; members read none", async () => {
    const t = await rolesTeam()
    const billing = await t.join("Billing", ["cmux:billing"])
    const guest = await t.join("Guest", ["cmux:guest"])
    const member = await t.join("Member", STACK_MEMBER)
    const all = (await read(t.creator.token, "team.audit.list", {}, t.team)).body.value.entries as Array<{ category: string; detail: any }>
    // A guest's join changes no seat (an admin record); every seat change is a billing record.
    expect(all.some((e) => e.category === "admin" && e.detail?.user === guest.user)).toBe(true)
    expect(all.some((e) => e.category === "billing" && e.detail?.user === member.user)).toBe(true)
    const billed = await read(billing.token, "team.audit.list", {}, t.team)
    expect(billed.status, JSON.stringify(billed.body)).toBe(200)
    const entries = billed.body.value.entries as Array<{ category: string; detail: any }>
    expect(entries.length).toBeGreaterThan(0)
    expect(entries.every((e) => e.category === "billing")).toBe(true)
    expect(entries.some((e) => e.detail?.user === guest.user)).toBe(false)
    // Billing has no resource grant; members and guests have no audit grant.
    expect(codeOf(await read(billing.token, "team.directory", {}, t.team))).toBe("auth.forbidden")
    expect(codeOf(await read(member.token, "team.audit.list", {}, t.team))).toBe("auth.forbidden")
    expect(codeOf(await read(guest.token, "team.audit.list", {}, t.team))).toBe("auth.forbidden")
  })

  it("a personal team keeps its single owner", async () => {
    const stackUser = crypto.randomUUID()
    const token = await sessionToken(stackUser, "Solo")
    expect((await call(token, "/v1/ops", { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })).body.ok).toBe(true)
    const dir = await call(token, "/v1/read", { op: "team.members.list", params: {} })
    expect(dir.body.value).toMatchObject({ member_count: 1, seat_count: 1, members: [{ user: userIdFor(PROJECT, stackUser), role: "owner" }] })
  })
})
