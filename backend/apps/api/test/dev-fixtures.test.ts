import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"
import { DEV_FIXTURES_HEADER, DEV_FIXTURES_PATH, fixtureStack as realFixtureStack, handleDevFixtures, type FixtureStack } from "../src/dev-fixtures.ts"
import type { Env } from "../src/env.ts"
import { memberRow, PROJECT, stackWorld, teamIdOf, useStack, type World } from "./team-stack-support.ts"
import { worker } from "./team-ssh-support.ts"

/**
 * The Cloud self-test's dev-only fixtures route (plans/cmux-next/cloud-selftest-DESIGN.md §3): test users, a team,
 * roles and live removal, each synced into TeamDO before the answer. It exists only in development, local and test
 * Workers, needs DEV_FIXTURES_TOKEN, and changes only users and teams it made for the same run.
 */
const TOKEN = "dev-fixtures-test-token-0123456789"
const testEnv = (over: Partial<Record<string, string>> = {}) => ({ ...(env as unknown as Env), ENVIRONMENT: "test", WORKER_NAME: "cmux-api-test", DEV_FIXTURES_TOKEN: TOKEN, STACK_SECRET_SERVER_KEY: "server-key", ...over }) as unknown as Env

/** A sign-in service that writes into the TeamDO tests' fake world, so the sync reads what the fixtures made. */
const fixtureStack = (w: World, onTeam: (stackTeam: string) => Promise<void>) => {
  const users = new Map<string, { primary_email: string; server_metadata: Record<string, unknown> }>()
  const teamMeta = new Map<string, Record<string, unknown>>()
  const sessions = new Map<string, Array<string>>()
  const deleted: Array<string> = []
  const stack: FixtureStack = {
    createUser: async (email, displayName, run) => {
      const id = crypto.randomUUID()
      users.set(id, { primary_email: email, server_metadata: { cmuxSelftest: run } })
      void displayName
      return { id }
    },
    createSession: async (userId) => {
      const s = `session-${crypto.randomUUID()}`
      sessions.set(userId, [...(sessions.get(userId) ?? []), s])
      return { access_token: `at-${s}`, refresh_token: `rt-${s}` }
    },
    getUser: async (id) => users.get(id) ?? null,
    createTeam: async (name, creator, run) => {
      const id = crypto.randomUUID()
      teamMeta.set(id, { cmuxSelftest: run })
      await onTeam(id)
      w.teams.set(id, name)
      w.members.set(`${id}:${creator}`, "Owner")
      w.perms.set(`${id}:${creator}`, ["$delete_team"])
      return { id }
    },
    getTeam: async (id) => (teamMeta.has(id) ? { server_metadata: teamMeta.get(id)! } : null),
    addMember: async (t, u) => void w.members.set(`${t}:${u}`, "Member"),
    grant: async (t, u, perm) => void w.perms.set(`${t}:${u}`, [...(w.perms.get(`${t}:${u}`) ?? []).filter((p) => p !== perm), perm]),
    revoke: async (t, u, perm) => void w.perms.set(`${t}:${u}`, (w.perms.get(`${t}:${u}`) ?? []).filter((p) => p !== perm)),
    removeMember: async (t, u) => {
      w.members.delete(`${t}:${u}`)
      w.perms.delete(`${t}:${u}`)
    },
    listSessions: async (u) => sessions.get(u) ?? [],
    deleteSession: async (u, s) => void sessions.set(u, (sessions.get(u) ?? []).filter((x) => x !== s)),
    findUsers: async (prefix) => [...users].filter(([, v]) => v.primary_email.startsWith(prefix)).map(([id]) => id),
    userTeams: async (u) => [...w.members.keys()].filter((k) => k.endsWith(`:${u}`)).map((k) => k.slice(0, k.length - u.length - 1)),
    deleteUser: async (id) => {
      users.delete(id)
      deleted.push(`user:${id}`)
    },
    deleteTeam: async (id) => {
      teamMeta.delete(id)
      w.teams.delete(id)
      deleted.push(`team:${id}`)
    }
  }
  return { stack, users, deleted }
}

const post = (body: unknown, token: string | null = TOKEN, method = "POST") =>
  new Request(`https://api.test${DEV_FIXTURES_PATH}`, { method, headers: { "content-type": "application/json", ...(token === null ? {} : { [DEV_FIXTURES_HEADER]: token }) }, ...(method === "POST" ? { body: JSON.stringify(body) } : {}) })

const call = async (body: unknown, e: Env, stack: FixtureStack, token: string | null = TOKEN) => {
  const res = await handleDevFixtures(post(body, token), e, { stack })
  return { status: res.status, body: (await res.json()) as any }
}

describe("dev fixtures route (Cloud self-test)", { timeout: 60_000 }, () => {
  it("is absent in production and staging, unconfigured without its token or the server key, and refuses a wrong token", async () => {
    const w = stackWorld()
    const { stack } = fixtureStack(w, async () => undefined)
    expect((await call({ op: "user", run: "run1", actor: "owner" }, testEnv({ ENVIRONMENT: "production" }), stack)).status).toBe(404)
    expect((await call({ op: "user", run: "run1", actor: "owner" }, testEnv({ ENVIRONMENT: "staging" }), stack)).status).toBe(404)
    // A development-environment Worker that is a shared one by name is refused too.
    expect((await call({ op: "user", run: "run1", actor: "owner" }, testEnv({ ENVIRONMENT: "development", WORKER_NAME: "cmux-api" }), stack)).status).toBe(404)
    const missing = await call({ op: "user", run: "run1", actor: "owner" }, testEnv({ DEV_FIXTURES_TOKEN: "" }), stack)
    expect(missing).toMatchObject({ status: 503, body: { ok: false, error: { code: "fixtures.not_configured" } } })
    expect((await call({ op: "user", run: "run1", actor: "owner" }, testEnv(), stack, "wrong-token-0123456789")).status).toBe(401)
    expect((await call({ op: "user", run: "run1", actor: "owner" }, testEnv(), stack, null)).status).toBe(401)
    expect((await handleDevFixtures(post(null, TOKEN, "GET"), testEnv(), { stack })).status).toBe(405)
    expect((await call({ op: "drop_tables", run: "run1" }, testEnv(), stack)).body.error.code).toBe("validation.invalid")
    expect((await call({ op: "user", run: "RUN 1!", actor: "owner" }, testEnv(), stack)).body.error.code).toBe("validation.invalid")
  })

  it("the deployed Worker without the token answers not configured (never a session)", async () => {
    const res = await worker.fetch(`https://api.test${DEV_FIXTURES_PATH}`, { method: "POST", headers: { "content-type": "application/json", [DEV_FIXTURES_HEADER]: "anything-at-all-0123" }, body: JSON.stringify({ op: "user", run: "run1", actor: "owner" }) })
    expect([404, 503]).toContain(res.status)
    expect(JSON.stringify(await res.json())).not.toContain("access_token")
  })

  it("makes marked users with sessions, a team its owner owns, sets roles and removes a member, each synced into TeamDO", async () => {
    const w = stackWorld()
    const { stack, deleted } = fixtureStack(w, (stackTeam) => useStack(stackTeam, w))
    const e = testEnv()
    const owner = await call({ op: "user", run: "run1", actor: "owner" }, e, stack)
    expect(owner.status).toBe(200)
    expect(owner.body.value).toMatchObject({ email: "selftest-run1-owner@selftest.cmux.invalid", user: userIdFor(PROJECT, owner.body.value.stack_user) })
    expect(owner.body.value.access_token).toMatch(/^at-/)
    const member = (await call({ op: "user", run: "run1", actor: "member" }, e, stack)).body.value
    const team = await call({ op: "team", run: "run1", owner: owner.body.value.stack_user, display_name: "Self-test run1" }, e, stack)
    expect(team.status).toBe(200)
    const teamId = teamIdOf(team.body.value.stack_team)
    expect(team.body.value.team).toBe(teamId)
    expect(await memberRow(teamId, userIdFor(PROJECT, owner.body.value.stack_user))).toMatchObject({ role: "owner" })

    const set = await call({ op: "member.set", run: "run1", stack_team: team.body.value.stack_team, stack_user: member.stack_user, role: "admin" }, e, stack)
    expect(set).toMatchObject({ status: 200, body: { ok: true, value: { role: "admin", synced: true } } })
    expect(await memberRow(teamId, userIdFor(PROJECT, member.stack_user))).toMatchObject({ role: "admin" })
    // Demoted: the admin permission goes, the member stays.
    await call({ op: "member.set", run: "run1", stack_team: team.body.value.stack_team, stack_user: member.stack_user, role: "member" }, e, stack)
    expect(await memberRow(teamId, userIdFor(PROJECT, member.stack_user))).toMatchObject({ role: "member" })
    // Removed live: TeamDO drops the row before the route answers.
    const removed = await call({ op: "member.remove", run: "run1", stack_team: team.body.value.stack_team, stack_user: member.stack_user }, e, stack)
    expect(removed).toMatchObject({ status: 200, body: { ok: true, value: { removed: true, synced: true } } })
    expect(await memberRow(teamId, userIdFor(PROJECT, member.stack_user))).toBeNull()

    expect((await call({ op: "sessions.revoke", run: "run1", stack_user: member.stack_user }, e, stack)).body.value).toEqual({ revoked: 1 })
    const cleaned = await call({ op: "cleanup", run: "run1" }, e, stack)
    expect(cleaned.body.value).toEqual({ users: 2, teams: 1 })
    expect(deleted.filter((d) => d.startsWith("team:"))).toHaveLength(1)
  })

  it("never touches a user or a team another run (or a real person) owns", async () => {
    const w = stackWorld()
    const { stack, users } = fixtureStack(w, (stackTeam) => useStack(stackTeam, w))
    const e = testEnv()
    const mine = (await call({ op: "user", run: "run2", actor: "owner" }, e, stack)).body.value
    const other = (await call({ op: "user", run: "run3", actor: "member" }, e, stack)).body.value
    const real = crypto.randomUUID()
    users.set(real, { primary_email: "person@example.com", server_metadata: {} })
    const team = (await call({ op: "team", run: "run2", owner: mine.stack_user, display_name: "T" }, e, stack)).body.value
    for (const target of [other.stack_user, real]) {
      const r = await call({ op: "member.set", run: "run2", stack_team: team.stack_team, stack_user: target, role: "admin" }, e, stack)
      expect(r).toMatchObject({ status: 403, body: { error: { code: "fixtures.refused" } } })
      expect((await call({ op: "sessions.revoke", run: "run2", stack_user: target }, e, stack)).status).toBe(403)
    }
    expect((await call({ op: "team", run: "run2", owner: real, display_name: "T" }, e, stack)).status).toBe(403)
    // A team of another run is refused even with this run's user.
    const theirs = (await call({ op: "team", run: "run3", owner: other.stack_user, display_name: "T3" }, e, stack)).body.value
    expect((await call({ op: "member.remove", run: "run2", stack_team: theirs.stack_team, stack_user: mine.stack_user }, e, stack)).status).toBe(403)
    // Cleanup of run2 leaves run3's user and the person alone.
    expect((await call({ op: "cleanup", run: "run2" }, e, stack)).body.value).toEqual({ users: 1, teams: 1 })
    expect(users.has(other.stack_user)).toBe(true)
    expect(users.has(real)).toBe(true)
  })

  it("takes away a permission the user does not hold, and names a role the sign-in project cannot express", async () => {
    // As the live service answers: a DELETE of a permission not held is 401 TEAM_PERMISSION_NOT_FOUND, and a grant
    // of a permission the project never defined is 404 PERMISSION_NOT_FOUND.
    const known = (status: number, code: string) => new Response(JSON.stringify({ code, error: "x" }), { status, headers: { "x-stack-known-error": code } })
    const stack = realFixtureStack(testEnv(), async (r) => (r.method === "DELETE" ? known(401, "TEAM_PERMISSION_NOT_FOUND") : known(404, "PERMISSION_NOT_FOUND")))
    await expect(stack.revoke("team", "user", "cmux:admin")).resolves.toBeUndefined()
    await expect(stack.grant("team", "user", "cmux:admin")).rejects.toThrow("fixtures.role_unavailable")
    const noHeader = realFixtureStack(testEnv(), async () => new Response(JSON.stringify({ code: "TEAM_PERMISSION_NOT_FOUND" }), { status: 401 }))
    await expect(noHeader.revoke("team", "user", "cmux:guest")).resolves.toBeUndefined()
  })
})
