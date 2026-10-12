import { describe, expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import { userIdFor } from "../src/domains/user.ts"
import { stackServer } from "../src/stack-server.ts"
import { codeOf, op, read, STACK_ADMIN, STACK_MEMBER } from "./team-roles-support.ts"
import { call, deliver, memberRow, PROJECT, teamIdOf, teamState, teamStub } from "./team-stack-support.ts"
import { inDO, sessionToken } from "./team-ssh-support.ts"

/**
 * cx-6wc8: a member that Stack's team-wide permission list leaves out (a project whose default member
 * permission set is empty, or a truncated list) must not make every team sync answer 503, and must
 * not get privilege. The real webhook route and the real Stack client run here; only Stack's HTTP
 * API is fake. A member missing from the team-wide list is read directly once: zero permissions is
 * role member, the member's own permissions keep their role, and a failed direct read answers 503.
 */
const fakeStackHttp = (stackTeam: string) => {
  const members = new Map<string, string>()
  const perms = new Map<string, Array<string>>()
  /** Users the team-wide permission list leaves out (their direct read still answers). */
  const omitTeamWide = new Set<string>()
  /** Users whose direct permission read fails (Stack 500). */
  const failDirect = new Set<string>()
  const removedInStack: Array<string> = []
  const notFound = (code: string) => new Response(JSON.stringify({ code }), { status: 404, headers: { "x-stack-known-error": code } })
  const http = async (req: Request) => {
    const url = new URL(req.url)
    const path = url.pathname.replace(/^\/api\/v1/, "")
    const q = url.searchParams
    if (path === `/teams/${stackTeam}`) return Response.json({ id: stackTeam, display_name: "Empty" })
    if (path.startsWith("/teams/")) return notFound("TEAM_NOT_FOUND")
    if (path === "/team-member-profiles" && q.get("team_id") === stackTeam)
      return Response.json({ is_paginated: false, items: [...members].map(([user_id, display_name]) => ({ team_id: stackTeam, user_id, display_name })) })
    const one = path.match(/^\/team-member-profiles\/([^/]+)\/([^/]+)$/)
    if (one && one[1] === stackTeam) return members.has(one[2]!) ? Response.json({ team_id: stackTeam, user_id: one[2], display_name: members.get(one[2]!) }) : notFound("TEAM_MEMBERSHIP_NOT_FOUND")
    if (path === "/team-permissions" && q.get("team_id") === stackTeam && q.get("recursive") === "true") {
      const user = q.get("user_id")
      if (user && failDirect.has(user)) return new Response("{}", { status: 500 })
      const users = user ? [user] : [...members.keys()].filter((u) => !omitTeamWide.has(u))
      return Response.json({ is_paginated: false, items: users.flatMap((u) => (perms.get(u) ?? []).map((id) => ({ id, user_id: u, team_id: stackTeam }))) })
    }
    const del = path.match(/^\/team-memberships\/([^/]+)\/([^/]+)$/)
    if (del && req.method === "DELETE" && del[1] === stackTeam) {
      if (!members.delete(del[2]!)) return notFound("TEAM_MEMBERSHIP_NOT_FOUND")
      perms.delete(del[2]!)
      removedInStack.push(del[2]!)
      return Response.json({ success: true })
    }
    return new Response("{}", { status: 404 })
  }
  return { members, perms, omitTeamWide, failDirect, removedInStack, http }
}

/** A Stack team mirrored through the real webhook route, with the real Stack client over the fake HTTP API. */
const emptyDefaultTeam = async () => {
  const stackTeam = crypto.randomUUID()
  const team = teamIdOf(stackTeam)
  const s = fakeStackHttp(stackTeam)
  await inDO(teamStub(team), async (instance) => {
    instance.stack = stackServer({ STACK_SECRET_SERVER_KEY: "k", STACK_PROJECT_ID: PROJECT } as unknown as Env, s.http)
  })
  const person = async (name: string, permissions: Array<string>) => {
    const stackUser = crypto.randomUUID()
    s.members.set(stackUser, name)
    if (permissions.length > 0) s.perms.set(stackUser, permissions)
    const token = await sessionToken(stackUser, name)
    expect((await call(token, "/v1/ops", { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })).body.ok).toBe(true)
    return { stackUser, user: userIdFor(PROJECT, stackUser), token }
  }
  const creator = await person("Creator", STACK_ADMIN)
  expect((await deliver("team.created", { id: stackTeam, display_name: "Empty", profile_image_url: null, created_at_millis: Date.now() })).status).toBe(200)
  return { s, stackTeam, team, creator, person }
}

const teamUpdated = (stackTeam: string) => deliver("team.updated", { id: stackTeam, display_name: "Empty", profile_image_url: null, created_at_millis: 0 })
const rolesOf = async (token: string, team: string) => {
  const r = await read(token, "team.members.list", {}, team)
  // A read answers {op, value} (no ok field); a refusal carries an error code.
  expect(r.status, JSON.stringify(r.body)).toBe(200)
  expect(codeOf(r), JSON.stringify(r.body)).toBeUndefined()
  return Object.fromEntries((r.body.value.members as Array<{ user: string; role: string }>).map((m) => [m.user, m.role]))
}

describe("Stack members with no permission entries (cx-6wc8)", { timeout: 60_000 }, () => {
  it("a member with zero permissions in Stack joins as member and every team sync answers 200", async () => {
    const t = await emptyDefaultTeam()
    // Stack's project gives new members no default permission: Stack lists none for them anywhere.
    const plain = await t.person("Plain", [])
    expect((await deliver("team_membership.created", { team_id: t.stackTeam, user_id: plain.stackUser })).status).toBe(200)
    expect((await teamUpdated(t.stackTeam)).status).toBe(200)
    expect(await rolesOf(t.creator.token, t.team)).toEqual({ [t.creator.user]: "owner", [plain.user]: "member" })
    // Role member: team resources yes, team management no.
    expect(Object.keys(await rolesOf(plain.token, t.team))).toHaveLength(2)
    expect(codeOf(await op(plain.token, "team.members.remove", { user: t.creator.user }, t.team))).toBe("auth.forbidden")
    expect(t.s.removedInStack).toEqual([])
  })

  it("an owner the team-wide list leaves out keeps owner rights: the sync keeps them owner and they remove an admin", async () => {
    const t = await emptyDefaultTeam()
    const admin = await t.person("Admin", [...STACK_MEMBER, "cmux:admin"])
    expect((await deliver("team_membership.created", { team_id: t.stackTeam, user_id: admin.stackUser })).status).toBe(200)
    // A truncated team-wide answer: the owner's entries are missing, their own read still has $delete_team.
    t.s.omitTeamWide.add(t.creator.stackUser)
    expect((await teamUpdated(t.stackTeam)).status).toBe(200)
    expect(await rolesOf(t.creator.token, t.team)).toEqual({ [t.creator.user]: "owner", [admin.user]: "admin" })
    // Removing an admin needs owner rights from Stack's live list (review P2-1).
    const r = await op(t.creator.token, "team.members.remove", { user: admin.user }, t.team)
    expect(r.body.ok, JSON.stringify(r.body)).toBe(true)
    expect(t.s.removedInStack).toEqual([admin.stackUser])
    expect(await memberRow(t.team, admin.user)).toBeNull()
  })

  it("a failed direct read of a left-out member answers 503 and changes nothing", async () => {
    const t = await emptyDefaultTeam()
    const admin = await t.person("Admin", [...STACK_MEMBER, "cmux:admin"])
    expect((await deliver("team_membership.created", { team_id: t.stackTeam, user_id: admin.stackUser })).status).toBe(200)
    const before = await teamState(t.team)
    t.s.omitTeamWide.add(admin.stackUser)
    t.s.failDirect.add(admin.stackUser)
    expect((await teamUpdated(t.stackTeam)).status).toBe(503)
    expect(await rolesOf(t.creator.token, t.team)).toEqual({ [t.creator.user]: "owner", [admin.user]: "admin" })
    expect((await teamState(t.team)).member_count).toBe(before.member_count)
  })
})
