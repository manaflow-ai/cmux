import type { Env } from "./env.ts"

/**
 * Stack (Hexclave) server API, used only by enterprise SSO sign-in to find or
 * create the user an IdP vouched for and to open a Stack session for them
 * (decision D4: Stack stays the identity source). The key is the Worker
 * secret STACK_SECRET_SERVER_KEY for STACK_PROJECT_ID. Endpoint shapes follow
 * Stack's server REST API (users, auth/sessions); tests use a fake.
 */
export interface StackServer {
  findUserByEmail(email: string): Promise<{ id: string } | undefined>
  createUser(email: string, displayName: string | undefined): Promise<{ id: string }>
  createSession(userId: string, expiresInMillis: number | undefined): Promise<{ access_token: string; refresh_token: string }>
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
  return {
    findUserByEmail: async (email) => {
      const r = await call<{ items?: Array<{ id: string; primary_email?: string | null }> }>("GET", `/users?query=${encodeURIComponent(email)}&limit=20`)
      // The query is a search: keep only an exact primary email match.
      const hit = (r.items ?? []).find((u) => (u.primary_email ?? "").toLowerCase() === email.toLowerCase())
      return hit ? { id: hit.id } : undefined
    },
    createUser: async (email, displayName) =>
      call<{ id: string }>("POST", "/users", { primary_email: email, primary_email_verified: true, ...(displayName ? { display_name: displayName } : {}) }),
    createSession: async (userId, expiresInMillis) =>
      call<{ access_token: string; refresh_token: string }>("POST", "/auth/sessions", { user_id: userId, ...(expiresInMillis ? { expires_in_millis: expiresInMillis } : {}) })
  }
}
