import type { Env } from "./env.ts"

/**
 * Stack (Hexclave) server API: enterprise SSO sign-in finds or creates the user
 * an IdP vouched for and opens a Stack session for them (decision D4: Stack
 * stays the identity source); the team webhook reads the current team and
 * membership (cx-3bi.43). The key is the Worker
 * secret STACK_SECRET_SERVER_KEY for STACK_PROJECT_ID. Endpoint shapes follow
 * Stack's server REST API (users, auth/sessions); tests use a fake.
 */
export interface StackServer {
  findUserByEmail(email: string): Promise<{ id: string; email_verified: boolean } | undefined>
  createUser(email: string, displayName: string | undefined): Promise<{ id: string }>
  createSession(userId: string, expiresInMillis: number | undefined): Promise<{ access_token: string; refresh_token: string }>
  /** The Stack team now, or null when Stack answers TEAM_NOT_FOUND (team webhooks, cx-3bi.43). */
  getTeam(teamId: string): Promise<{ display_name: string } | null>
  /** Every member Stack lists for the team now ("team_gone" for TEAM_NOT_FOUND); Stack does not page this list today. */
  listTeamMembers(teamId: string): Promise<ReadonlyArray<{ user_id: string; display_name: string | null }> | "team_gone">
  /**
   * The membership now: the member's profile, null when not a member (TEAM_MEMBERSHIP_NOT_FOUND, or
   * USER_NOT_FOUND for a deleted user; both checked live 2026-10-08), "team_gone" for TEAM_NOT_FOUND.
   */
  getTeamMember(teamId: string, userId: string): Promise<{ display_name: string | null } | null | "team_gone">
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
  return {
    getTeam: async (teamId) => {
      const r = await lookup<{ display_name?: unknown }>(`/teams/${encodeURIComponent(teamId)}`, "team", ["TEAM_NOT_FOUND"])
      return isGone(r) ? null : { display_name: typeof r.display_name === "string" ? r.display_name : "" }
    },
    listTeamMembers: async (teamId) => {
      const out: Array<{ user_id: string; display_name: string | null }> = []
      let cursor: string | undefined
      // Stack answers {is_paginated: false, items}; a cursor is followed if it ever pages (checked live 2026-10-09).
      for (let page = 0; page < 1000; page++) {
        const r = await lookup<{ items?: Array<{ user_id?: unknown; display_name?: unknown; user?: { display_name?: unknown } }>; pagination?: { next_cursor?: unknown } | null }>(`/team-member-profiles?team_id=${encodeURIComponent(teamId)}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`, "team members", ["TEAM_NOT_FOUND"])
        if (isGone(r)) return "team_gone"
        for (const m of r.items ?? []) {
          if (typeof m.user_id !== "string") continue
          const name = typeof m.display_name === "string" && m.display_name ? m.display_name : typeof m.user?.display_name === "string" ? m.user.display_name : null
          out.push({ user_id: m.user_id, display_name: name })
        }
        const next = r.pagination?.next_cursor
        if (typeof next !== "string" || !next) return out
        cursor = next
      }
      throw new Error("stack GET team members: too many pages")
    },
    getTeamMember: async (teamId, userId) => {
      const r = await lookup<{ display_name?: unknown; user?: { display_name?: unknown } }>(`/team-member-profiles/${encodeURIComponent(teamId)}/${encodeURIComponent(userId)}`, "team member", ["TEAM_NOT_FOUND", "TEAM_MEMBERSHIP_NOT_FOUND", "USER_NOT_FOUND"])
      if (isGone(r)) return r.gone === "TEAM_NOT_FOUND" ? "team_gone" : null
      const name = typeof r.display_name === "string" && r.display_name ? r.display_name : typeof r.user?.display_name === "string" ? r.user.display_name : null
      return { display_name: name }
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
