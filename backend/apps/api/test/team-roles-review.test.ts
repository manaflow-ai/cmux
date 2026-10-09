import { describe, expect, it } from "vitest"
import { stackServer } from "../src/stack-server.ts"
import type { Env } from "../src/env.ts"
import { deliver, memberRow, teamStub } from "./team-stack-support.ts"
import { inDO, worker } from "./team-ssh-support.ts"
import { codeOf, op, read, rolesTeam, STACK_ADMIN, STACK_MEMBER } from "./team-roles-support.ts"

/** cx-3bi.4 security review (lead, 2026-10-09): P2-1..3 and P3-1..5. */
describe("team roles review (cx-3bi.4)", { timeout: 60_000 }, () => {
  it("P2-1: a removal decides with Stack's live roles, never a stale cached one", async () => {
    const t = await rolesTeam()
    const admin = await t.join("Admin", [...STACK_MEMBER, "cmux:admin"])
    const target = await t.join("Target", STACK_MEMBER)
    // Stack made the target an owner; the webhook has not arrived (late or dead-lettered).
    t.w.perms.set(`${t.stackTeam}:${target.stackUser}`, STACK_ADMIN)
    expect(codeOf(await op(admin.token, "team.members.remove", { user: target.user }, t.team))).toBe("auth.forbidden")
    expect(t.w.removedInStack).toEqual([])
    expect(await memberRow(t.team, target.user)).not.toBeNull()
    // Stack took the actor's admin away, no event yet: the cached admin role removes nobody.
    const other = await t.join("Other", STACK_MEMBER)
    t.w.perms.set(`${t.stackTeam}:${admin.stackUser}`, STACK_MEMBER)
    expect(codeOf(await op(admin.token, "team.members.remove", { user: other.user }, t.team))).toBe("auth.forbidden")
    expect(t.w.removedInStack).toEqual([])
  })

  it("P3-1: team.member.remove with `by` re-checks the person's grant in the reducer", async () => {
    const t = await rolesTeam()
    const a1 = await t.join("Admin One", [...STACK_MEMBER, "cmux:admin"])
    const a2 = await t.join("Admin Two", [...STACK_MEMBER, "cmux:admin"])
    const r = await inDO(teamStub(t.team), async (instance) => instance.submitSystem("team.member.remove", { user: a2.user, by: a1.user }, `remove:${crypto.randomUUID()}`))
    expect(r.frames.find((f: any) => f.t === "reject")).toMatchObject({ code: "auth.forbidden" })
    expect(await memberRow(t.team, a2.user)).toMatchObject({ role: "admin" })
  })

  it("P2-2: a guest naming the team opens no wire scope but user", async () => {
    const t = await rolesTeam()
    const guest = await t.join("Guest", ["cmux:guest"])
    const member = await t.join("Member", STACK_MEMBER)
    const wire = (token: string, path: string) =>
      worker.fetch(`https://api.test/v1/wire/${path}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}, team.${t.team}` } })
    for (const path of ["team", "cloud", "feed", "conv/conv_00000000000000000001", "mux/agent_00000000000000000001"]) {
      expect((await wire(guest.token, path)).status, path).toBe(403)
    }
    for (const [token, path] of [[guest.token, "user"], [member.token, "feed"]] as const) {
      const res = await wire(token, path)
      expect(res.status, path).toBe(101)
      res.webSocket?.accept()
      res.webSocket?.close()
    }
  })

  it("P2-3: a Stack demotion of the last owner applies, is audited and shows no_owner until an owner is back", async () => {
    const t = await rolesTeam()
    t.w.perms.set(`${t.stackTeam}:${t.creator.stackUser}`, STACK_MEMBER)
    expect((await deliver("team_permission.deleted", { id: "team_admin", team_id: t.stackTeam, user_id: t.creator.stackUser })).status).toBe(200)
    expect(await memberRow(t.team, t.creator.user)).toMatchObject({ role: "member" })
    expect((await read(t.creator.token, "team.members.list", {}, t.team)).body.value).toMatchObject({ no_owner: true })
    expect((await read(t.creator.token, "team_vm.status", {}, t.team)).body.value).toMatchObject({ no_owner: true })
    const audit = await inDO(teamStub(t.team), async (_i, st) =>
      st.storage.sql.exec<{ payload: string }>(`SELECT payload FROM own_outbox WHERE kind = 'audit.append' ORDER BY id`).toArray().map((r) => JSON.parse(r.payload) as { op: string })
    )
    expect(audit.some((a) => a.op === "team.no_owner")).toBe(true)
    t.w.perms.set(`${t.stackTeam}:${t.creator.stackUser}`, STACK_ADMIN)
    expect((await deliver("team_permission.created", { id: "team_admin", team_id: t.stackTeam, user_id: t.creator.stackUser })).status).toBe(200)
    expect((await read(t.creator.token, "team.members.list", {}, t.team)).body.value).toMatchObject({ no_owner: false })
  })

  it("P3-2: only cmux:admin gives admin; Stack's $remove_members alone gives member", async () => {
    const t = await rolesTeam()
    const r = await t.join("Remover", [...STACK_MEMBER, "$remove_members"])
    expect(await memberRow(t.team, r.user)).toMatchObject({ role: "member" })
  })

  it("P3-3: a malformed or partial permission answer fails the read instead of giving member", async () => {
    const answer = (perms: unknown) => async (req: Request) => {
      const path = new URL(req.url).pathname
      if (path.includes("/team-member-profiles/")) return Response.json({ display_name: "A" })
      if (path.endsWith("/team-permissions")) return Response.json(perms)
      return new Response("{}", { status: 404 })
    }
    const env = { STACK_SECRET_SERVER_KEY: "k", STACK_PROJECT_ID: "p" } as unknown as Env
    const u = "11111111-1111-4111-8111-111111111111"
    await expect(stackServer(env, answer({ items: [{ user_id: u }] }))!.getTeamMember("t", u)).rejects.toThrow()
    await expect(stackServer(env, answer({}))!.getTeamMember("t", u)).rejects.toThrow()
    await expect(stackServer(env, answer({ items: [{ id: "cmux:admin", user_id: "22222222-2222-4222-8222-222222222222", team_id: "t" }] }))!.getTeamMember("t", u)).rejects.toThrow()
    // A complete empty answer is a member with no permissions.
    await expect(stackServer(env, answer({ items: [], is_paginated: false }))!.getTeamMember("t", u)).resolves.toMatchObject({ permissions: [] })
  })

  it("P3-5: guests and billing read neither the current policy nor the device policy", async () => {
    const t = await rolesTeam()
    const guest = await t.join("Guest", ["cmux:guest"])
    const billing = await t.join("Billing", ["cmux:billing"])
    for (const who of [guest, billing]) {
      expect(codeOf(await read(who.token, "team.policy.get", {}, t.team))).toBe("auth.forbidden")
      expect(codeOf(await read(who.token, "team.device.policy", {}, t.team))).toBe("auth.forbidden")
    }
  })
})
