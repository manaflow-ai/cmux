import { describe, expect, it } from "vitest"
import { codeOf, op, read, rolesTeam, STACK_MEMBER } from "./team-roles-support.ts"

/**
 * Team-visible Cloud sessions (cloud multiplayer lane D): every member lists the team's Cloud workspaces
 * and chats, follows them, and the assignee or an admin reassigns them. A guest sees nothing; a member
 * removed from the team is refused on the next call. Group membership writes (owner/edit/view).
 */
const VM = "vm_0123456789abcdef0123"
const chat = (session: string, extra: Record<string, unknown> = {}) => ({
  vm: VM,
  session,
  kind: "chat",
  title: `Chat ${session}`,
  workspace: "ws_aaaaaaaa",
  harness: "claude",
  machine_state: "running",
  activity: "working",
  last_activity_at: 1_000,
  ...extra
})
// An op answers `{ok: true, value}`; a read answers `{op, value, stream, revision}`. Either way a
// success has a value and no error code.
const ok = (r: { body: any }) => {
  expect(codeOf(r), JSON.stringify(r.body)).toBeUndefined()
  expect(r.body?.value, JSON.stringify(r.body)).toBeDefined()
  return r.body.value
}

describe("team Cloud sessions", { timeout: 120_000 }, () => {
  it("a publish makes the publisher owner and assignee; every member lists it with its link; a guest is refused", async () => {
    const t = await rolesTeam()
    const member = await t.join("Member", STACK_MEMBER)
    const guest = await t.join("Guest", [...STACK_MEMBER, "cmux:guest"])
    const v = ok(await op(t.creator.token, "team.cloud.session.publish", chat("s1"), t.team))
    expect(v).toMatchObject({ key: `cloud:${t.team}/${VM}/s1`, owner: t.creator.user, assignee: t.creator.user, assigned_to_you: true, following: false, archived: false })
    expect(v.link).toBe(`cmux://cloud/session/${t.team}/${VM}/s1`)
    ok(await op(t.creator.token, "team.cloud.session.publish", { ...chat("ws_bbbbbbbb"), kind: "workspace", last_activity_at: 2_000 }, t.team))
    const listed = ok(await read(member.token, "team.cloud.session.list", { scope: "team" }, t.team))
    // Newest activity first; the workspace form of the link for a workspace.
    expect(listed.sessions.map((s: any) => [s.session, s.link])).toEqual([
      ["ws_bbbbbbbb", `cmux://cloud/workspace/${t.team}/${VM}/ws_bbbbbbbb`],
      ["s1", `cmux://cloud/session/${t.team}/${VM}/s1`]
    ])
    expect(listed.sessions[1]).toMatchObject({ owner_name: "Creator", assignee_name: "Creator", assigned_to_you: false, can_reassign: false })
    expect(ok(await read(member.token, "team.cloud.session.list", { scope: "mine" }, t.team)).sessions).toEqual([])
    expect(ok(await read(t.creator.token, "team.cloud.session.list", { scope: "mine" }, t.team)).sessions).toHaveLength(2)
    expect(codeOf(await read(guest.token, "team.cloud.session.list", {}, t.team))).toBe("auth.forbidden")
    expect(codeOf(await read(guest.token, "team.cloud.session.get", { vm: VM, session: "s1" }, t.team))).toBe("auth.forbidden")
    // A member cannot publish over someone else's session; a missing one is cloud_session.not_found.
    expect(codeOf(await op(member.token, "team.cloud.session.publish", chat("s1", { title: "hijack" }), t.team))).toBe("cloud_session.not_yours")
    expect(codeOf(await read(member.token, "team.cloud.session.get", { vm: VM, session: "nope" }, t.team))).toBe("selector.not_found")
  })

  it("a publish never moves last activity back, never touches the assignee, and a same publish changes nothing", async () => {
    const t = await rolesTeam()
    const member = await t.join("Member", STACK_MEMBER)
    ok(await op(t.creator.token, "team.cloud.session.publish", chat("s1", { last_activity_at: 5_000 }), t.team))
    ok(await op(t.creator.token, "team.cloud.session.reassign", { vm: VM, session: "s1", to: member.user }, t.team))
    const stale = ok(await op(t.creator.token, "team.cloud.session.publish", chat("s1", { last_activity_at: 4_000, activity: "idle" }), t.team))
    expect(stale).toMatchObject({ last_activity_at: 5_000, activity: "idle", assignee: member.user, owner: t.creator.user })
    // The new assignee may publish too (their app may run it later).
    ok(await op(member.token, "team.cloud.session.publish", chat("s1", { last_activity_at: 6_000 }), t.team))
    const listed = ok(await read(member.token, "team.cloud.session.list", {}, t.team)).sessions
    expect(listed.map((s: any) => s.last_activity_at)).toEqual([6_000])
  })

  it("follow shows under following; following a session assigned to you is refused; repeats are no-ops", async () => {
    const t = await rolesTeam()
    const member = await t.join("Member", STACK_MEMBER)
    ok(await op(t.creator.token, "team.cloud.session.publish", chat("s1"), t.team))
    expect(codeOf(await op(t.creator.token, "team.cloud.session.follow", { vm: VM, session: "s1", follow: true }, t.team))).toBe("cloud_session.assigned_to_you")
    const f = ok(await op(member.token, "team.cloud.session.follow", { vm: VM, session: "s1", follow: true }, t.team))
    expect(f).toMatchObject({ following: true, follower_count: 1, followers: [member.user] })
    expect(ok(await op(member.token, "team.cloud.session.follow", { vm: VM, session: "s1", follow: true }, t.team)).follower_count).toBe(1)
    expect(ok(await read(member.token, "team.cloud.session.list", { scope: "following" }, t.team)).sessions.map((s: any) => s.session)).toEqual(["s1"])
    expect(ok(await read(t.creator.token, "team.cloud.session.list", { scope: "following" }, t.team)).sessions).toEqual([])
    ok(await op(member.token, "team.cloud.session.follow", { vm: VM, session: "s1", follow: false }, t.team))
    expect(ok(await read(member.token, "team.cloud.session.list", { scope: "following" }, t.team)).sessions).toEqual([])
    expect(codeOf(await op(member.token, "team.cloud.session.follow", { vm: VM, session: "gone", follow: true }, t.team))).toBe("cloud_session.not_found")
  })

  it("reassign: only the assignee, owner or an admin; to a member, never a guest; followers keep following and the previous assignee follows", async () => {
    const t = await rolesTeam()
    const a = await t.join("Alice", STACK_MEMBER)
    const b = await t.join("Bob", STACK_MEMBER)
    const c = await t.join("Carol", STACK_MEMBER)
    const admin = await t.join("Admin", [...STACK_MEMBER, "cmux:admin"])
    const guest = await t.join("Guest", [...STACK_MEMBER, "cmux:guest"])
    ok(await op(a.token, "team.cloud.session.publish", chat("s1"), t.team))
    ok(await op(c.token, "team.cloud.session.follow", { vm: VM, session: "s1", follow: true }, t.team))
    ok(await op(b.token, "team.cloud.session.follow", { vm: VM, session: "s1", follow: true }, t.team))
    expect(codeOf(await op(c.token, "team.cloud.session.reassign", { vm: VM, session: "s1", to: c.user }, t.team))).toBe("auth.forbidden")
    expect(codeOf(await op(a.token, "team.cloud.session.reassign", { vm: VM, session: "s1", to: guest.user }, t.team))).toBe("cloud_session.assignee_not_member")
    const moved = ok(await op(a.token, "team.cloud.session.reassign", { vm: VM, session: "s1", to: b.user }, t.team))
    expect(moved).toMatchObject({ assignee: b.user, owner: a.user, assigned_to_you: false, following: true })
    // Bob's follow went (it is his now); Carol keeps hers; Alice follows it.
    const asBob = ok(await read(b.token, "team.cloud.session.get", { vm: VM, session: "s1" }, t.team)).session
    expect(asBob).toMatchObject({ assigned_to_you: true, following: false, can_reassign: true })
    expect(new Set(asBob.followers)).toEqual(new Set([a.user, c.user]))
    expect(ok(await read(b.token, "team.cloud.session.list", { scope: "mine" }, t.team)).sessions.map((s: any) => s.session)).toEqual(["s1"])
    expect(ok(await read(t.creator.token, "team.cloud.session.list", { by: b.user }, t.team)).sessions).toHaveLength(1)
    // An admin may reassign someone else's session; a repeat is a no-op.
    ok(await op(admin.token, "team.cloud.session.reassign", { vm: VM, session: "s1", to: c.user }, t.team))
    expect(ok(await op(admin.token, "team.cloud.session.reassign", { vm: VM, session: "s1", to: c.user }, t.team)).assignee).toBe(c.user)
  })

  it("a member removed from the team mid-session loses the list, the link and their follow at once", async () => {
    const t = await rolesTeam()
    const m = await t.join("Member", STACK_MEMBER)
    ok(await op(t.creator.token, "team.cloud.session.publish", chat("s1"), t.team))
    ok(await op(m.token, "team.cloud.session.follow", { vm: VM, session: "s1", follow: true }, t.team))
    ok(await op(m.token, "team.cloud.session.viewing", { vm: VM, session: "s1", viewing: true }, t.team))
    expect(ok(await read(t.creator.token, "team.cloud.session.get", { vm: VM, session: "s1" }, t.team)).session).toMatchObject({ viewers: [m.user], follower_count: 1 })
    ok(await op(t.creator.token, "team.members.remove", { user: m.user }, t.team))
    // Someone no longer in the team: the Worker's membership gate (team.not_member) or TeamDO's (auth.forbidden).
    expect(["auth.forbidden", "team.not_member"]).toContain(codeOf(await read(m.token, "team.cloud.session.list", {}, t.team)))
    expect(["auth.forbidden", "team.not_member"]).toContain(codeOf(await read(m.token, "team.cloud.session.get", { vm: VM, session: "s1" }, t.team)))
    // A write from someone no longer in the team is refused by TeamDO's membership check.
    expect(["auth.forbidden", "team.not_member"]).toContain(codeOf(await op(m.token, "team.cloud.session.follow", { vm: VM, session: "s1", follow: false }, t.team)))
    // Their follow and presence no longer show to the team.
    expect(ok(await read(t.creator.token, "team.cloud.session.get", { vm: VM, session: "s1" }, t.team)).session).toMatchObject({ viewers: [], follower_count: 0, followers: [] })
  })

  it("archive hides a session from the default list and shows it under archived; remove drops it and its follows", async () => {
    const t = await rolesTeam()
    const m = await t.join("Member", STACK_MEMBER)
    ok(await op(t.creator.token, "team.cloud.session.publish", chat("s1"), t.team))
    ok(await op(m.token, "team.cloud.session.follow", { vm: VM, session: "s1", follow: true }, t.team))
    expect(codeOf(await op(m.token, "team.cloud.session.archive", { vm: VM, session: "s1", archived: true }, t.team))).toBe("auth.forbidden")
    ok(await op(t.creator.token, "team.cloud.session.archive", { vm: VM, session: "s1", archived: true }, t.team))
    expect(ok(await read(m.token, "team.cloud.session.list", {}, t.team)).sessions).toEqual([])
    expect(ok(await read(m.token, "team.cloud.session.list", { archived: true }, t.team)).sessions.map((s: any) => s.session)).toEqual(["s1"])
    // A publish keeps it archived.
    expect(ok(await op(t.creator.token, "team.cloud.session.publish", chat("s1", { last_activity_at: 9_000 }), t.team)).archived).toBe(true)
    expect(codeOf(await op(m.token, "team.cloud.session.remove", { vm: VM, session: "s1" }, t.team))).toBe("cloud_session.not_yours")
    expect(ok(await op(t.creator.token, "team.cloud.session.remove", { vm: VM, session: "s1" }, t.team))).toEqual({ removed: true })
    expect(ok(await read(m.token, "team.cloud.session.list", { scope: "following", archived: true }, t.team)).sessions).toEqual([])
    expect(codeOf(await read(m.token, "team.cloud.session.get", { vm: VM, session: "s1" }, t.team))).toBe("selector.not_found")
  })

  it("pages the team list newest first with a cursor and no duplicates", async () => {
    const t = await rolesTeam()
    for (let i = 0; i < 5; i++) ok(await op(t.creator.token, "team.cloud.session.publish", chat(`s${i}`, { last_activity_at: 100 + i }), t.team))
    const first = ok(await read(t.creator.token, "team.cloud.session.list", { limit: 2 }, t.team))
    expect(first.sessions.map((s: any) => s.session)).toEqual(["s4", "s3"])
    const second = ok(await read(t.creator.token, "team.cloud.session.list", { limit: 2, cursor: first.next_cursor }, t.team))
    expect(second.sessions.map((s: any) => s.session)).toEqual(["s2", "s1"])
    const third = ok(await read(t.creator.token, "team.cloud.session.list", { limit: 2, cursor: second.next_cursor }, t.team))
    expect(third.sessions.map((s: any) => s.session)).toEqual(["s0"])
    expect(third.next_cursor).toBeNull()
  })

  it("group members: owner adds and changes roles; guests and outsiders are refused; the last owner stays; a member may leave", async () => {
    const t = await rolesTeam()
    const m = await t.join("Member", STACK_MEMBER)
    const v = await t.join("Viewer", STACK_MEMBER)
    const guest = await t.join("Guest", [...STACK_MEMBER, "cmux:guest"])
    const g = ok(await op(t.creator.token, "group.create", { name: "Fix login" }, t.team))
    expect(codeOf(await read(m.token, "group.get", { group: g.id }, t.team))).toBe("selector.not_found")
    const added = ok(await op(t.creator.token, "group.members.set", { group: g.id, user: m.user, role: "edit" }, t.team))
    expect(added.members[0]).toMatchObject({ user: t.creator.user, role: "owner", display_name: "Creator", active: true })
    expect(added.members).toContainEqual({ user: m.user, role: "edit", display_name: "Member", active: true })
    ok(await op(t.creator.token, "group.members.set", { group: g.id, user: v.user, role: "view" }, t.team))
    expect(ok(await read(m.token, "group.get", { group: g.id }, t.team)).group.role).toBe("edit")
    expect(ok(await read(v.token, "group.list", {}, t.team)).groups.map((x: any) => x.id)).toEqual([g.id])
    expect(ok(await read(v.token, "group.members.list", { group: g.id }, t.team)).members).toHaveLength(3)
    // Only the owner manages members; never a guest; the last owner cannot be demoted or leave.
    expect(codeOf(await op(m.token, "group.members.set", { group: g.id, user: v.user, role: "edit" }, t.team))).toBe("auth.forbidden")
    expect(codeOf(await op(t.creator.token, "group.members.set", { group: g.id, user: guest.user, role: "view" }, t.team))).toBe("group.member_not_in_team")
    expect(codeOf(await op(t.creator.token, "group.members.set", { group: g.id, user: t.creator.user, role: "edit" }, t.team))).toBe("group.last_owner")
    expect(codeOf(await op(t.creator.token, "group.members.remove", { group: g.id, user: t.creator.user }, t.team))).toBe("group.last_owner")
    // A member leaves; the owner removes another; access ends at once.
    ok(await op(v.token, "group.members.remove", { group: g.id, user: v.user }, t.team))
    expect(codeOf(await read(v.token, "group.get", { group: g.id }, t.team))).toBe("selector.not_found")
    ok(await op(t.creator.token, "group.members.remove", { group: g.id, user: m.user }, t.team))
    expect(codeOf(await read(m.token, "group.get", { group: g.id }, t.team))).toBe("selector.not_found")
    expect(ok(await read(m.token, "group.list", {}, t.team)).groups).toEqual([])
  })
})
