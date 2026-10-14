import type { Env } from "../env.ts"

/**
 * Sign-in for the metered Claude route (`/api/claude-david/v1/messages` on the Chatmux service,
 * Claude on Bedrock metered by its spend ledger). The route takes an `X-Stack-Auth` header
 * {accessToken, refreshToken} of a signed-in person. The Worker secret CHIEF_BRAIN_CLAUDE_STACK_AUTH
 * holds that value (staging only, a person's session for now); one holder object (ChiefBrainDO
 * name HOLDER) refreshes the access token before it expires and keeps it in its own storage.
 *
 * Token bytes never go to a log, an error message, a run step or a response: failures surface only
 * as the fixed text AUTH_FAILED.
 */
export const HOLDER = "claude-david-auth"
export const AUTH_FAILED = "claude-david auth failed"
const DEFAULT_REFRESH_URL = "https://api.stack-auth.com/api/v1/auth/sessions/current/refresh"
/** The sign-in project of the Chatmux service (public id). */
const DEFAULT_PROJECT = "9790718f-14cd-4f7e-824d-eaf527a82b82"
/** Refresh when the access token has less than this left (a turn runs at most 10 minutes). */
const MARGIN_MS = 15 * 60_000

export class ClaudeAuthError extends Error {
  constructor() {
    super(AUTH_FAILED)
  }
}

const expiryOf = (jwt: string): number => {
  try {
    const part = jwt.split(".")[1] ?? ""
    const json = JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (part.length % 4)) % 4))) as { exp?: unknown }
    return typeof json.exp === "number" ? json.exp * 1000 : 0
  } catch {
    return 0
  }
}

const secretOf = (env: Env): { accessToken: string; refreshToken: string } | null => {
  try {
    const v = JSON.parse(env.CHIEF_BRAIN_CLAUDE_STACK_AUTH ?? "") as { accessToken?: unknown; refreshToken?: unknown }
    return typeof v.refreshToken === "string" && v.refreshToken ? { accessToken: typeof v.accessToken === "string" ? v.accessToken : "", refreshToken: v.refreshToken } : null
  } catch {
    return null
  }
}

/** Whether this deployment can reach the metered Claude route at all (the secret is set). */
export const claudeConfigured = (env: Env): boolean => secretOf(env) !== null

/**
 * The `X-Stack-Auth` header value, refreshed when needed (in the holder object). Throws
 * ClaudeAuthError (fixed text) when there is no secret or the refresh fails.
 */
export const holderAuth = async (env: Env, sql: SqlStorage, now = Date.now()): Promise<string> => {
  const secret = secretOf(env)
  if (!secret) throw new ClaudeAuthError()
  const row = (k: string) => sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, k).toArray()[0]?.value
  let access = row("claude.access") ?? secret.accessToken
  if (expiryOf(access) - now < MARGIN_MS) {
    const res = await fetch(env.CHIEF_BRAIN_CLAUDE_REFRESH_URL || DEFAULT_REFRESH_URL, {
      method: "POST",
      headers: { "content-type": "application/json", "x-hexclave-project-id": env.CHIEF_BRAIN_CLAUDE_PROJECT || DEFAULT_PROJECT, "x-hexclave-access-type": "client", "x-hexclave-refresh-token": secret.refreshToken },
      body: "{}"
    }).catch(() => null)
    const body = res?.ok ? ((await res.json().catch(() => null)) as { access_token?: unknown } | null) : null
    if (typeof body?.access_token !== "string" || expiryOf(body.access_token) <= now) throw new ClaudeAuthError()
    access = body.access_token
    sql.exec(`INSERT INTO cb_config (name, value) VALUES ('claude.access', ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value`, access)
  }
  return JSON.stringify({ accessToken: access, refreshToken: secret.refreshToken })
}

/**
 * A fetch for the Anthropic client that signs requests for the metered route: the placeholder API
 * key is removed and `X-Stack-Auth` set. `auth` throws ClaudeAuthError on failure.
 */
export const signedFetch = (auth: () => Promise<string>): typeof fetch =>
  (async (input: RequestInfo | URL, init?: RequestInit) => {
    const headers = new Headers(init?.headers)
    headers.delete("x-api-key")
    headers.delete("authorization")
    headers.set("X-Stack-Auth", await auth())
    headers.set("x-coderouter-client", "cmux-cloud-chief")
    return fetch(input, { ...init, headers })
  }) as typeof fetch
