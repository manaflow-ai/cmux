import { describe, expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import { stackServer } from "../src/stack-server.ts"
import { deliver, memberRow, mirroredTeam, PROJECT, teamState, teamStub } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"

/**
 * A team event mirrors Stack's member list and removes every member Stack no longer lists
 * (cx-3bi.43). So a member list we cannot read must fail the delivery (503, Svix retries) and
 * change nothing: a 200 without an items array, or with a malformed item, never empties the team.
 */
describe("Stack member list answers are read strictly", { timeout: 60_000 }, () => {
  const realStack = (stackTeam: string, members: unknown, permissions: unknown = { is_paginated: false, items: [] }) =>
    stackServer({ STACK_SECRET_SERVER_KEY: "k", STACK_PROJECT_ID: PROJECT } as unknown as Env, async (req) => {
      const path = new URL(req.url).pathname
      if (path.endsWith(`/teams/${stackTeam}`)) return Response.json({ id: stackTeam, display_name: "Acme" })
      if (path.endsWith("/team-member-profiles")) return Response.json(members)
      // The member list is read with each member's team permissions (cx-3bi.4).
      if (path.endsWith("/team-permissions")) return Response.json(permissions)
      return new Response("{}", { status: 404 })
    })!

  for (const [name, body] of [
    ["no items array", { is_paginated: false }],
    ["items not an array", { items: "nope" }],
    ["an item without user_id", { items: [{ display_name: "Ghost" }] }]
  ] as const) {
    it(`a 200 with ${name} answers 503 and leaves every member`, async () => {
      const t = await mirroredTeam()
      const before = await teamState(t.team)
      await inDO(teamStub(t.team), async (instance) => {
        instance.stack = realStack(t.stackTeam, body)
      })
      const r = await deliver("team.updated", { id: t.stackTeam, display_name: "Acme", profile_image_url: null, created_at_millis: 0 })
      expect(r.status).toBe(503)
      expect(await memberRow(t.team, t.user)).toMatchObject({ user: t.user, role: "member" })
      expect((await teamState(t.team)).member_count).toBe(before.member_count)
    })
  }

  it("a well-formed list still mirrors (control)", async () => {
    const t = await mirroredTeam()
    await inDO(teamStub(t.team), async (instance) => {
      instance.stack = realStack(t.stackTeam, { is_paginated: false, items: [{ team_id: t.stackTeam, user_id: t.stackUser, display_name: "Aziz" }] }, { is_paginated: false, items: [{ id: "team_member", user_id: t.stackUser, team_id: t.stackTeam }] })
    })
    expect((await deliver("team.updated", { id: t.stackTeam, display_name: "Acme", profile_image_url: null, created_at_millis: 0 })).status).toBe(200)
    expect(await memberRow(t.team, t.user)).toMatchObject({ user: t.user })
  })
})
