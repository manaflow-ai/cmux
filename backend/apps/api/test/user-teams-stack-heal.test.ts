import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"
import type { Env } from "../src/env.ts"
import { listUserTeams } from "../src/user-teams.ts"
import { call, PROJECT, stackWorld, teamIdOf, teamStub, useStack } from "./team-stack-support.ts"
import { inDO as runIn } from "./team-ssh-support.ts"
import { sessionToken } from "./team-ssh-support.ts"

const workerEnv = env as unknown as Env

/**
 * A Stack team whose webhook deliveries never reached cmux (a team made before the mirror existed, or
 * events Stack never sent) left every member out of its TeamDO: user.teams.list named only the personal
 * team and Home listed no teammates (prod, 2026-10-29: the "cmux" team, 5 members, none mirrored).
 * user.teams.list now asks Stack which teams the person is in and runs a full team sync for each one
 * TeamDO does not confirm, then lists it.
 */
describe("user.teams.list mirrors a Stack team the webhook never synced", { timeout: 60_000 }, () => {
  const setup = async (name: string) => {
    const w = stackWorld()
    const stackTeam = crypto.randomUUID()
    const me = crypto.randomUUID()
    const mate = crypto.randomUUID()
    await useStack(stackTeam, w)
    w.teams.set(stackTeam, name)
    w.members.set(`${stackTeam}:${me}`, "Lawrence")
    w.members.set(`${stackTeam}:${mate}`, "Aziz")
    const token = await sessionToken(me, "Lawrence")
    expect((await call(token, "/v1/ops", { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })).body.ok).toBe(true)
    const principal = { identity: `test:${me}`, kind: "session" as const, user: userIdFor(PROJECT, me), stack_user_id: me }
    return { w, stackTeam, me, mate, token, principal, team: teamIdOf(stackTeam) }
  }
  const members = (token: string, team: string) => call(token, "/v1/read", { op: "team.members.list", params: { limit: 200 } }, team)

  it("syncs the team from Stack and lists it, with every teammate", async () => {
    const s = await setup("cmux")
    // Before: no delivery ever came, so the team does not know its members.
    expect((await members(s.token, s.team)).status).toBe(403)
    const r = await listUserTeams(workerEnv, s.principal, { stack: s.w.fake, pace: async () => true, now: () => Date.now() })
    expect(r.ok, JSON.stringify(r)).toBe(true)
    const teams = (r as { value: { teams: Array<{ id: string; display_name: string; kind: string }> } }).value.teams
    expect(teams).toContainEqual(expect.objectContaining({ id: s.team, display_name: "cmux", kind: "stack" }))
    const after = await members(s.token, s.team)
    expect(after.status, JSON.stringify(after.body)).toBe(200)
    expect((after.body.value.members as Array<{ display_name: string }>).map((m) => m.display_name).sort()).toEqual(["Aziz", "Lawrence"])
  })

  it("a person's own list is never put in the low lane of the Stack pace (that lane may be full of visitors' teams)", async () => {
    const s = await setup("Busy")
    await runIn(teamStub(s.team), async (instance) => void (instance.stackLowPace = async () => false))
    const r = await listUserTeams(workerEnv, s.principal, { stack: s.w.fake, pace: async () => true, now: () => Date.now() })
    expect((r as { value: { teams: Array<{ id: string }> } }).value.teams.map((t) => t.id)).toContain(s.team)
  })

  it("asks Stack once per person per window, and not at all without a pace token", async () => {
    const s = await setup("Paced")
    const before = s.w.calls()
    const r = await listUserTeams(workerEnv, s.principal, { stack: s.w.fake, pace: async () => false, now: () => 1_000 })
    expect((r as { value: { teams: Array<unknown> } }).value.teams).toHaveLength(1)
    expect(s.w.calls()).toBe(before)
    await listUserTeams(workerEnv, s.principal, { stack: s.w.fake, pace: async () => true, now: () => 2_000 })
    const once = s.w.calls()
    expect(once).toBeGreaterThan(before)
    await listUserTeams(workerEnv, s.principal, { stack: s.w.fake, pace: async () => true, now: () => 3_000 })
    expect(s.w.calls()).toBe(once)
  })
})
