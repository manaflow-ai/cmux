import { stackTeamIdFor, userIdFor } from "./domains/user.ts"
import type { Env } from "./env.ts"

/**
 * POST /v1/dev/fixtures: test identities for the Cloud self-test (plans/cmux-next/cloud-selftest-DESIGN.md §3,
 * scripts/cmux-next/cloud-selftest.ts). Several signed-in people (owner, admin, member, guest, outsider) are what
 * multiplayer needs to be checked end to end without the GUI; this makes them on a dev or preview backend.
 *
 * Only where ENVIRONMENT is development (previews deploy as development), local or test, and never on a Worker named
 * cmux-api or cmux-api-staging: anywhere else the path is a 404, as if it did not exist. It also needs the secret
 * DEV_FIXTURES_TOKEN (header x-cmux-dev-fixtures, compared in constant time) and STACK_SECRET_SERVER_KEY, else 503
 * fixtures.not_configured.
 *
 * Body {op, run, ...}; run is the self-test's run tag (a-z0-9, 4 to 24). Ops:
 *   user {actor}                                  a sign-in user selftest-<run>-<actor>@selftest.cmux.invalid, marked
 *                                                 with server metadata {cmuxSelftest: run}, and a 2 h session:
 *                                                 {email, stack_user, user, access_token, refresh_token}
 *   team {owner, display_name}                    a sign-in team made by that user (who owns it), marked: {stack_team, team}
 *   member.set {stack_team, stack_user, role}     membership with role member | admin | billing | guest (the cmux:<role>
 *                                                 team permission; the others are taken away): {role, synced}
 *   member.remove {stack_team, stack_user}        the membership ends: {removed, synced}
 *   sessions.revoke {stack_user}                  every session of the user ends: {revoked}
 *   cleanup                                       deletes this run's teams, then its users: {users, teams}
 * Every user and team an op names must carry this run's mark (and a user the self-test domain), else 403
 * fixtures.refused: the route can never act on a real account or on another run's. A team change is synced into its
 * TeamDO before the answer (the same sync a sign-in service webhook runs, team-stack-sync.ts), so the next request
 * already sees it: `synced: true`.
 */
export const DEV_FIXTURES_PATH = "/v1/dev/fixtures"
export const DEV_FIXTURES_HEADER = "x-cmux-dev-fixtures"
export const SELFTEST_DOMAIN = "selftest.cmux.invalid"
const ENVIRONMENTS = new Set(["development", "local", "test"])
const SHARED_WORKERS = new Set(["cmux-api", "cmux-api-staging"])
const RUN = /^[a-z0-9]{4,24}$/
const ACTOR = /^[a-z0-9-]{1,24}$/
const STACK_ID = /^[A-Za-z0-9._:-]{1,128}$/
const ROLE_PERMISSION = { admin: "cmux:admin", billing: "cmux:billing", guest: "cmux:guest" } as const
type Role = "member" | keyof typeof ROLE_PERMISSION
const ROLES: ReadonlyArray<Role> = ["member", "admin", "billing", "guest"]
const SESSION_MS = 2 * 3600_000

/** The sign-in service's server calls this route makes (tests pass a fake). */
export interface FixtureStack {
  createUser(email: string, displayName: string, run: string): Promise<{ id: string }>
  createSession(userId: string, expiresInMillis: number): Promise<{ access_token: string; refresh_token: string }>
  getUser(id: string): Promise<{ primary_email: string; server_metadata: Record<string, unknown> } | null>
  createTeam(displayName: string, creatorUserId: string, run: string): Promise<{ id: string }>
  getTeam(id: string): Promise<{ server_metadata: Record<string, unknown> } | null>
  addMember(team: string, user: string): Promise<void>
  grant(team: string, user: string, permission: string): Promise<void>
  revoke(team: string, user: string, permission: string): Promise<void>
  removeMember(team: string, user: string): Promise<void>
  listSessions(user: string): Promise<ReadonlyArray<string>>
  deleteSession(user: string, session: string): Promise<void>
  /** User ids whose primary email starts with `prefix`. */
  findUsers(prefix: string): Promise<ReadonlyArray<string>>
  userTeams(user: string): Promise<ReadonlyArray<string>>
  deleteUser(id: string): Promise<void>
  deleteTeam(id: string): Promise<void>
}

const API = "https://api.stack-auth.com/api/v1"

/** The server REST calls (users, auth/sessions, teams, team-memberships, team-permissions), with the Worker's key. */
export const fixtureStack = (env: Env, http: (r: Request) => Promise<Response> = (r) => fetch(r)): FixtureStack => {
  const headers = { "content-type": "application/json", "x-stack-access-type": "server", "x-stack-project-id": env.STACK_PROJECT_ID, "x-stack-secret-server-key": env.STACK_SECRET_SERVER_KEY ?? "" }
  /** One call; a status in `ok` is an answer (404 for an absent membership, 409 for one that exists). Never echoes the body. */
  const call = async <T>(method: string, path: string, body?: unknown, ok: ReadonlyArray<number> = [200, 201], okKnown: ReadonlyArray<string> = []): Promise<T | null> => {
    const res = await http(new Request(`${API}${path}`, { method, headers, ...(method === "GET" ? {} : { body: JSON.stringify(body ?? {}) }), signal: AbortSignal.timeout(10_000) }))
    const known = res.headers.get("x-stack-known-error") ?? (res.ok ? "" : await res.clone().json().then((b) => String((b as { code?: unknown } | null)?.code ?? ""), () => ""))
    if (okKnown.includes(known)) return null
    if (known === "PERMISSION_NOT_FOUND") throw new Error("fixtures.role_unavailable: the sign-in project defines no such team permission")
    if (!ok.includes(res.status)) throw new Error(`stack ${method} ${path.split("?")[0]!.replace(/\/[^/]{20,}/g, "/…")} returned ${res.status}`)
    if (res.status === 404 || res.status === 409) return null
    return (await res.json()) as T
  }
  const enc = encodeURIComponent
  return {
    createUser: async (email, displayName, run) => (await call<{ id: string }>("POST", "/users", { primary_email: email, primary_email_verified: true, display_name: displayName, server_metadata: { cmuxSelftest: run } }))!,
    createSession: async (userId, expiresInMillis) => (await call<{ access_token: string; refresh_token: string }>("POST", "/auth/sessions", { user_id: userId, expires_in_millis: expiresInMillis }))!,
    getUser: async (id) => {
      const r = await call<{ primary_email?: string | null; server_metadata?: Record<string, unknown> | null }>("GET", `/users/${enc(id)}`, undefined, [200, 404])
      return r ? { primary_email: r.primary_email ?? "", server_metadata: r.server_metadata ?? {} } : null
    },
    createTeam: async (displayName, creatorUserId, run) => (await call<{ id: string }>("POST", "/teams", { display_name: displayName, creator_user_id: creatorUserId, server_metadata: { cmuxSelftest: run } }))!,
    getTeam: async (id) => {
      const r = await call<{ server_metadata?: Record<string, unknown> | null }>("GET", `/teams/${enc(id)}`, undefined, [200, 404])
      return r ? { server_metadata: r.server_metadata ?? {} } : null
    },
    addMember: async (t, u) => void (await call("POST", `/team-memberships/${enc(t)}/${enc(u)}`, {}, [200, 201, 409])),
    grant: async (t, u, p) => void (await call("POST", `/team-permissions/${enc(t)}/${enc(u)}/${enc(p)}`, {}, [200, 201, 409])),
    // Not held (the service answers 401 TEAM_PERMISSION_NOT_FOUND) or not defined in the project: nothing to take away.
    revoke: async (t, u, p) => void (await call("DELETE", `/team-permissions/${enc(t)}/${enc(u)}/${enc(p)}`, {}, [200, 404], ["TEAM_PERMISSION_NOT_FOUND", "PERMISSION_NOT_FOUND"])),
    removeMember: async (t, u) => void (await call("DELETE", `/team-memberships/${enc(t)}/${enc(u)}`, {}, [200, 404])),
    listSessions: async (u) => ((await call<{ items?: Array<{ id?: unknown }> }>("GET", `/auth/sessions?user_id=${enc(u)}`))?.items ?? []).flatMap((s) => (typeof s.id === "string" ? [s.id] : [])),
    deleteSession: async (u, s) => void (await call("DELETE", `/auth/sessions/${enc(s)}?user_id=${enc(u)}`, {}, [200, 404])),
    findUsers: async (prefix) => ((await call<{ items?: Array<{ id: string; primary_email?: string | null }> }>("GET", `/users?query=${enc(prefix)}&limit=100`))?.items ?? []).filter((u) => (u.primary_email ?? "").startsWith(prefix)).map((u) => u.id),
    userTeams: async (u) => ((await call<{ items?: Array<{ id?: unknown }> }>("GET", `/teams?user_id=${enc(u)}`))?.items ?? []).flatMap((t) => (typeof t.id === "string" ? [t.id] : [])),
    deleteUser: async (id) => void (await call("DELETE", `/users/${enc(id)}`, {}, [200, 404])),
    deleteTeam: async (id) => void (await call("DELETE", `/teams/${enc(id)}`, {}, [200, 404]))
  }
}

const answer = (status: number, body: unknown) => Response.json(body, { status, headers: { "cache-control": "no-store" } })
const refuse = (status: number, code: string, message: string) => answer(status, { ok: false, error: { code, message, retryable: status >= 500 } })
const done = (value: unknown) => answer(200, { ok: true, value })

/** Constant-time comparison of the header with the secret (both as UTF-8 bytes). */
const sameSecret = (given: string, secret: string): boolean => {
  const a = new TextEncoder().encode(given)
  const b = new TextEncoder().encode(secret)
  let diff = a.length ^ b.length
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0)
  return diff === 0
}

export const fixturesEnabled = (env: Env): boolean => ENVIRONMENTS.has(env.ENVIRONMENT) && !SHARED_WORKERS.has(env.WORKER_NAME ?? "")

class Refused extends Error {}
class Invalid extends Error {}

export const handleDevFixtures = async (request: Request, env: Env, deps: { stack?: FixtureStack } = {}): Promise<Response> => {
  if (!fixturesEnabled(env)) return refuse(404, "not.found", "not found")
  const secret = env.DEV_FIXTURES_TOKEN ?? ""
  if (secret.length < 16 || !env.STACK_SECRET_SERVER_KEY) return refuse(503, "fixtures.not_configured", "the fixtures route needs DEV_FIXTURES_TOKEN and STACK_SECRET_SERVER_KEY on this Worker")
  if (request.method !== "POST") return refuse(405, "validation.invalid", "use POST")
  if (!sameSecret(request.headers.get(DEV_FIXTURES_HEADER) ?? "", secret)) return refuse(401, "auth.unauthenticated", "bad fixtures token")
  const body = (await request.json().catch(() => null)) as Record<string, unknown> | null
  const op = typeof body?.op === "string" ? body.op : ""
  const run = typeof body?.run === "string" ? body.run : ""
  if (!RUN.test(run)) return refuse(400, "validation.invalid", "run is 4 to 24 of a-z0-9")
  const stack = deps.stack ?? fixtureStack(env)
  const id = (k: string) => {
    const v = body?.[k]
    if (typeof v !== "string" || !STACK_ID.test(v)) throw new Invalid(`${k} is a sign-in service id`)
    return v
  }
  /** A user this run made: its mark and the self-test domain. */
  const ownUser = async (u: string) => {
    const got = await stack.getUser(u)
    if (!got || got.server_metadata.cmuxSelftest !== run || !got.primary_email.endsWith(`@${SELFTEST_DOMAIN}`)) throw new Refused("not a user of this run")
  }
  const ownTeam = async (t: string) => {
    const got = await stack.getTeam(t)
    if (!got || got.server_metadata.cmuxSelftest !== run) throw new Refused("not a team of this run")
  }
  /** The TeamDO sync a webhook delivery runs, now; its own delivery id so it is never taken for a duplicate. */
  const sync = async (stackTeam: string, type: string, stackUser?: string) => {
    const team = stackTeamIdFor(env.STACK_PROJECT_ID, stackTeam)
    const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team))
    const reply = await stub.stackWebhook(team, { svix_id: `dev-fixtures:${run}:${crypto.randomUUID()}`, type, stack_team: stackTeam, ...(stackUser ? { stack_user: stackUser } : {}), urgent: true })
    if (!reply.ok) throw new Error(`fixtures.sync_failed: ${reply.reason}`)
    return team
  }
  try {
    switch (op) {
      case "user": {
        const actor = typeof body?.actor === "string" ? body.actor : ""
        if (!ACTOR.test(actor)) return refuse(400, "validation.invalid", "actor is 1 to 24 of a-z0-9-")
        const email = `selftest-${run}-${actor}@${SELFTEST_DOMAIN}`
        const u = await stack.createUser(email, `Self-test ${actor}`, run)
        const s = await stack.createSession(u.id, SESSION_MS)
        return done({ email, stack_user: u.id, user: userIdFor(env.STACK_PROJECT_ID, u.id), access_token: s.access_token, refresh_token: s.refresh_token })
      }
      case "team": {
        const owner = id("owner")
        await ownUser(owner)
        const name = typeof body?.display_name === "string" && body.display_name.length <= 64 ? body.display_name : `Self-test ${run}`
        const t = await stack.createTeam(name, owner, run)
        return done({ stack_team: t.id, team: await sync(t.id, "team.created") })
      }
      case "member.set": {
        const [t, u] = [id("stack_team"), id("stack_user")]
        const role = ROLES.find((r) => r === body?.role)
        if (!role) return refuse(400, "validation.invalid", "role is member, admin, billing or guest")
        await ownTeam(t)
        await ownUser(u)
        await stack.addMember(t, u)
        for (const [r, perm] of Object.entries(ROLE_PERMISSION)) {
          if (r === role) await stack.grant(t, u, perm)
          else await stack.revoke(t, u, perm)
        }
        await sync(t, "team_permission.created", u)
        return done({ role, synced: true })
      }
      case "member.remove": {
        const [t, u] = [id("stack_team"), id("stack_user")]
        await ownTeam(t)
        await ownUser(u)
        await stack.removeMember(t, u)
        await sync(t, "team_membership.deleted", u)
        return done({ removed: true, synced: true })
      }
      case "sessions.revoke": {
        const u = id("stack_user")
        await ownUser(u)
        const sessions = await stack.listSessions(u)
        for (const s of sessions) await stack.deleteSession(u, s)
        return done({ revoked: sessions.length })
      }
      case "cleanup": {
        const prefix = `selftest-${run}-`
        const users: Array<string> = []
        for (const u of await stack.findUsers(prefix)) {
          const got = await stack.getUser(u)
          if (got && got.server_metadata.cmuxSelftest === run && got.primary_email.startsWith(prefix) && got.primary_email.endsWith(`@${SELFTEST_DOMAIN}`)) users.push(u)
        }
        const teams = new Set<string>()
        for (const u of users) for (const t of await stack.userTeams(u)) teams.add(t)
        let teamCount = 0
        for (const t of teams) {
          const got = await stack.getTeam(t)
          if (got?.server_metadata.cmuxSelftest !== run) continue
          await stack.deleteTeam(t)
          await sync(t, "team.deleted").catch(() => undefined)
          teamCount++
        }
        for (const u of users) await stack.deleteUser(u)
        return done({ users: users.length, teams: teamCount })
      }
      default:
        return refuse(400, "validation.invalid", "op is user, team, member.set, member.remove, sessions.revoke or cleanup")
    }
  } catch (e) {
    if (e instanceof Refused) return refuse(403, "fixtures.refused", e.message)
    if (e instanceof Invalid) return refuse(400, "validation.invalid", e.message)
    const m = String((e as Error).message ?? e).slice(0, 200)
    const code = m.startsWith("fixtures.sync_failed") ? "fixtures.sync_failed" : m.startsWith("fixtures.role_unavailable") ? "fixtures.role_unavailable" : "fixtures.upstream"
    return refuse(code === "fixtures.role_unavailable" ? 409 : 502, code, m)
  }
}
