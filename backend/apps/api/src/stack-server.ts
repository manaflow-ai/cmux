import type { Env } from "./env.ts"

/**
 * Stack (Hexclave) server API: enterprise SSO sign-in finds or creates the user
 * an IdP vouched for and opens a Stack session for them (decision D4: Stack
 * stays the identity source); the team webhook reads the current team and
 * membership (cx-3bi.43). The key is the Worker
 * secret STACK_SECRET_SERVER_KEY for STACK_PROJECT_ID. Endpoint shapes follow
 * Stack's server REST API (users, auth/sessions); the team permission list and the
 * membership removal follow the Stack SDK's server interface (@hexclave/shared 1.0.121
 * listServerTeamPermissions: GET /team-permissions?team_id&user_id&recursive, items
 * {id, user_id, team_id}; removeServerUserFromTeam: DELETE /team-memberships/{team}/{user}).
 * Tests use a fake.
 */
export interface StackServer {
  findUserByEmail(email: string): Promise<{ id: string; email_verified: boolean } | undefined>
  createUser(email: string, displayName: string | undefined): Promise<{ id: string }>
  createSession(userId: string, expiresInMillis: number | undefined): Promise<{ access_token: string; refresh_token: string }>
  /** The Stack team now, or null when Stack answers TEAM_NOT_FOUND (team webhooks, cx-3bi.43). */
  getTeam(teamId: string): Promise<{ display_name: string } | null>
  /**
   * Every member Stack lists for the team now ("team_gone" for TEAM_NOT_FOUND), with each member's
   * team permission ids (GET /team-permissions?team_id&recursive=true, so contained permissions
   * count; cx-3bi.4). Stack does not page these lists today.
   */
  listTeamMembers(teamId: string): Promise<ReadonlyArray<StackMember & { user_id: string }> | "team_gone">
  /**
   * The membership now: the member's profile and permissions, null when not a member
   * (TEAM_MEMBERSHIP_NOT_FOUND, or USER_NOT_FOUND for a deleted user; both checked live
   * 2026-10-08), "team_gone" for TEAM_NOT_FOUND.
   */
  getTeamMember(teamId: string, userId: string): Promise<StackMember | null | "team_gone">
  /** Removes the membership in Stack (DELETE /team-memberships/{team}/{user}); "absent" when it was not there. */
  removeTeamMember(teamId: string, userId: string): Promise<"removed" | "absent" | "team_gone">
}

export interface StackMember {
  readonly display_name: string | null
  /** Team permission ids, `$` system ones included (team-roles.ts stackRole maps them to a role). */
  readonly permissions: ReadonlyArray<string>
}

const API = "https://api.stack-auth.com/api/v1"

export const stackServer = (env: Env, http: (r: Request) => Promise<Response> = (r) => fetch(r)): StackServer | undefined => {
  const key = env.STACK_SECRET_SERVER_KEY
  if (!key) return undefined
  const headers = {
    "content-type": "application/json",
    "x-stack-access-type": "server",
    "x-stack-project-id": env.STACK_PROJECT_ID,
    "x-stack-secret-server-key": key
  }
  const call = async <T>(method: string, path: string, body?: unknown): Promise<T> => {
    const res = await http(new Request(`${API}${path}`, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(10_000) }))
    // Never echo Stack's response body (it may carry user data) into our errors.
    if (!res.ok) throw new Error(`stack ${method} ${path.split("?")[0]} returned ${res.status}`)
    return (await res.json()) as T
  }
  /** A GET whose 404 with one of Stack's known errors `gone` is an answer, not a failure; any other error throws. */
  const lookup = async <T>(path: string, label: string, gone: ReadonlyArray<string>): Promise<T | { gone: string }> => {
    const res = await http(new Request(`${API}${path}`, { method: "GET", headers, signal: AbortSignal.timeout(10_000) }))
    const known = res.headers.get("x-stack-known-error") ?? ""
    if (res.status === 404 && gone.includes(known)) return { gone: known }
    if (!res.ok) throw new Error(`stack GET ${label} returned ${res.status}`)
    return (await res.json()) as T
  }
  const isGone = (r: unknown): r is { gone: string } => typeof r === "object" && r !== null && "gone" in r
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  const normal = (id: string) => (UUID.test(id) ? id.toLowerCase() : id)
  /** user id -> permission ids; one user or the whole team. Cursors are followed if Stack ever pages. */
  const permissions = async (teamId: string, userId?: string): Promise<Map<string, Array<string>> | "team_gone"> => {
    const out = new Map<string, Array<string>>()
    let cursor: string | undefined
    for (let page = 0; page < 1000; page++) {
      const q = `team_id=${encodeURIComponent(teamId)}${userId ? `&user_id=${encodeURIComponent(userId)}` : ""}&recursive=true${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`
      const r = await lookup<{ items?: Array<{ id?: unknown; user_id?: unknown }>; pagination?: { next_cursor?: unknown } | null }>(`/team-permissions?${q}`, "team permissions", ["TEAM_NOT_FOUND"])
      if (isGone(r)) return "team_gone"
      // A role is decided from this list, so an answer we cannot read fails (the delivery retries) instead of
      // giving member (review P3-3): no items array, an item without its ids, or an item for another user.
      if (!Array.isArray(r.items)) throw new Error("stack GET team permissions: no items")
      for (const p of r.items) {
        if (typeof p.id !== "string" || typeof p.user_id !== "string") throw new Error("stack GET team permissions: malformed item")
        if (userId && normal(p.user_id) !== normal(userId)) throw new Error("stack GET team permissions: item for another user")
        out.set(normal(p.user_id), [...(out.get(normal(p.user_id)) ?? []), p.id])
      }
      const next = r.pagination?.next_cursor
      if (typeof next !== "string" || !next) return out
      cursor = next
    }
    throw new Error("stack GET team permissions: too many pages")
  }
  return {
    getTeam: async (teamId) => {
      const r = await lookup<{ display_name?: unknown }>(`/teams/${encodeURIComponent(teamId)}`, "team", ["TEAM_NOT_FOUND"])
      return isGone(r) ? null : { display_name: typeof r.display_name === "string" ? r.display_name : "" }
    },
    listTeamMembers: async (teamId) => {
      const out: Array<{ user_id: string; display_name: string | null; permissions: ReadonlyArray<string> }> = []
      let cursor: string | undefined
      // Stack answers {is_paginated: false, items}; a cursor is followed if it ever pages (checked live 2026-10-09).
      for (let page = 0; page < 1000; page++) {
        const r = await lookup<{ items?: Array<{ user_id?: unknown; display_name?: unknown; user?: { display_name?: unknown } }>; pagination?: { next_cursor?: unknown } | null }>(`/team-member-profiles?team_id=${encodeURIComponent(teamId)}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`, "team members", ["TEAM_NOT_FOUND"])
        if (isGone(r)) return "team_gone"
        for (const m of r.items ?? []) {
          if (typeof m.user_id !== "string") continue
          const name = typeof m.display_name === "string" && m.display_name ? m.display_name : typeof m.user?.display_name === "string" ? m.user.display_name : null
          out.push({ user_id: m.user_id, display_name: name, permissions: [] })
        }
        const next = r.pagination?.next_cursor
        if (typeof next !== "string" || !next) {
          const perms = await permissions(teamId)
          if (perms === "team_gone") return "team_gone"
          return out.map((m) => ({ ...m, permissions: perms.get(normal(m.user_id)) ?? [] }))
        }
        cursor = next
      }
      throw new Error("stack GET team members: too many pages")
    },
    getTeamMember: async (teamId, userId) => {
      const r = await lookup<{ display_name?: unknown; user?: { display_name?: unknown } }>(`/team-member-profiles/${encodeURIComponent(teamId)}/${encodeURIComponent(userId)}`, "team member", ["TEAM_NOT_FOUND", "TEAM_MEMBERSHIP_NOT_FOUND", "USER_NOT_FOUND"])
      if (isGone(r)) return r.gone === "TEAM_NOT_FOUND" ? "team_gone" : null
      const name = typeof r.display_name === "string" && r.display_name ? r.display_name : typeof r.user?.display_name === "string" ? r.user.display_name : null
      const perms = await permissions(teamId, userId)
      if (perms === "team_gone") return "team_gone"
      return { display_name: name, permissions: perms.get(normal(userId)) ?? [] }
    },
    removeTeamMember: async (teamId, userId) => {
      const res = await http(new Request(`${API}/team-memberships/${encodeURIComponent(teamId)}/${encodeURIComponent(userId)}`, { method: "DELETE", headers, body: "{}", signal: AbortSignal.timeout(10_000) }))
      const known = res.headers.get("x-stack-known-error") ?? ""
      if (res.status === 404 && known === "TEAM_NOT_FOUND") return "team_gone"
      if (res.status === 404 && (known === "TEAM_MEMBERSHIP_NOT_FOUND" || known === "USER_NOT_FOUND")) return "absent"
      if (!res.ok) throw new Error(`stack DELETE team membership returned ${res.status}`)
      return "removed"
    },
    findUserByEmail: async (email) => {
      const r = await call<{ items?: Array<{ id: string; primary_email?: string | null; primary_email_verified?: boolean }> }>("GET", `/users?query=${encodeURIComponent(email)}&limit=100`)
      // The query is a search: keep only an exact primary email match.
      const hit = (r.items ?? []).find((u) => (u.primary_email ?? "").toLowerCase() === email.toLowerCase())
      return hit ? { id: hit.id, email_verified: hit.primary_email_verified === true } : undefined
    },
    createUser: async (email, displayName) =>
      call<{ id: string }>("POST", "/users", { primary_email: email, primary_email_verified: true, ...(displayName ? { display_name: displayName } : {}) }),
    createSession: async (userId, expiresInMillis) =>
      call<{ access_token: string; refresh_token: string }>("POST", "/auth/sessions", { user_id: userId, ...(expiresInMillis ? { expires_in_millis: expiresInMillis } : {}) })
  }
}
