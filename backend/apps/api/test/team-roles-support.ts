import { expect } from "vitest"
import { userIdFor } from "../src/domains/user.ts"
import { call, deliver, PROJECT, stackWorld, teamIdOf, useStack } from "./team-stack-support.ts"
import { sessionToken } from "./team-ssh-support.ts"

/** Shared helpers for the team role tests (cx-3bi.4): a Stack team with permission-driven roles. */
/** What Stack lists (recursive) for its default team_admin and team_member permissions. */
export const STACK_ADMIN = ["team_admin", "$update_team", "$delete_team", "$read_members", "$remove_members", "$invite_members", "$manage_api_keys"]
export const STACK_MEMBER = ["team_member", "$read_members", "$invite_members"]

export const codeOf = (r: { body: any }) => r.body?.error?.code ?? r.body?.code
export const op = (token: string, name: string, params: unknown, team: string) => call(token, "/v1/ops", { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" }, team)
export const read = (token: string, name: string, params: unknown, team: string) => call(token, "/v1/read", { op: name, params }, team)

/** A Stack team whose creator holds Stack's team_admin; Stack sends no membership event for the creator, the team event lists them. */
export const rolesTeam = async () => {
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
