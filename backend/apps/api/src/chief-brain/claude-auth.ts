import type { Env } from "../env.ts"
import { bedrockBody, eventStreamToSse } from "./bedrock-stream.ts"
import { claudeRoute, claudeRouteReady, meteredOwner, offers, OPUS } from "./model-routes.ts"

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
/** Refresh when the access token has less than this left: one streamed request is signed at a time. */
const MAX_MARGIN_MS = 3 * 60_000
/** Claude turns of all Chiefs per UTC day on this deployment (default): the whole spend bound beside each Chief's cap. */
const DEFAULT_DAILY_CLAUDE_TURNS = 500

export class ClaudeAuthError extends Error {
  constructor() {
    super(AUTH_FAILED)
  }
}

/** `exp` and `iat` of a JWT in ms (0 when unreadable). */
const timesOf = (jwt: string): { exp: number; iat: number } => {
  try {
    const part = jwt.split(".")[1] ?? ""
    const json = JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (part.length % 4)) % 4))) as { exp?: unknown; iat?: unknown }
    const exp = typeof json.exp === "number" ? json.exp * 1000 : 0
    return { exp, iat: typeof json.iat === "number" ? json.iat * 1000 : exp }
  } catch {
    return { exp: 0, iat: 0 }
  }
}
/** Time left before a refresh is due: the margin is at most half the token's life. */
const fresh = (jwt: string, now: number) => {
  const t = timesOf(jwt)
  return t.exp - now > Math.min(MAX_MARGIN_MS, (t.exp - t.iat) / 2)
}

const secretOf = (env: Env): { accessToken: string; refreshToken: string } | null => {
  try {
    const v = JSON.parse(env.CHIEF_BRAIN_CLAUDE_STACK_AUTH ?? "") as { accessToken?: unknown; refreshToken?: unknown }
    return typeof v.refreshToken === "string" && v.refreshToken ? { accessToken: typeof v.accessToken === "string" ? v.accessToken : "", refreshToken: v.refreshToken } : null
  } catch {
    return null
  }
}

/** Whether this deployment can reach the Claude route at all (its credential is set; model-routes.ts). */
export const claudeConfigured = (env: Env): boolean => claudeRouteReady(env)

/**
 * Owners whose Chiefs may run on Claude: CHIEF_BRAIN_CLAUDE_OWNERS (a var, in wrangler.jsonc) plus
 * CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA (a secret, set with `wrangler secret put` and no deploy, for owners
 * that change often, such as a demo's test user), comma separated user ids. The route bills one person's account.
 */
export const claudeAllowed = (env: Env, owner: string | null): boolean => claudeConfigured(env) && meteredOwner(env, owner)

const row = (sql: SqlStorage, k: string) => sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, k).toArray()[0]?.value
const put = (sql: SqlStorage, k: string, v: string) => sql.exec(`INSERT INTO cb_config (name, value) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value`, k, v)

/** The holder counts one metered turn (a Claude or OpenRouter model) of `owner`: allow-list, the model offered here, the deployment's daily cap. */
export const holderTurn = (env: Env, sql: SqlStorage, owner: string, model: string = OPUS, now = Date.now()): boolean => {
  if (!meteredOwner(env, owner) || !offers(env, model)) return false
  const key = `claude.turns:${new Date(now).toISOString().slice(0, 10)}`
  const used = Number(row(sql, key) ?? 0)
  if (used >= (Number(env.CHIEF_BRAIN_CLAUDE_DAILY_TURNS) || DEFAULT_DAILY_CLAUDE_TURNS)) return false
  put(sql, key, String(used + 1))
  return true
}

/** The route refused the stored access token: drop it, so the next request refreshes. */
export const holderInvalidate = (sql: SqlStorage): void => void sql.exec(`DELETE FROM cb_config WHERE name = 'claude.access'`)

/**
 * The `X-Stack-Auth` header value, refreshed when needed (in the holder object). Throws
 * ClaudeAuthError (fixed text) when there is no secret or the refresh fails.
 */
export const holderAuth = async (env: Env, sql: SqlStorage, now = Date.now()): Promise<string> => {
  // An enterprise route with a static bearer token (CHIEF_BRAIN_CLAUDE_AUTH=bearer): nothing to refresh.
  if (claudeRoute(env).auth === "bearer") {
    if (!env.CHIEF_BRAIN_CLAUDE_TOKEN) throw new ClaudeAuthError()
    return `Bearer ${env.CHIEF_BRAIN_CLAUDE_TOKEN}`
  }
  const secret = secretOf(env)
  if (!secret) throw new ClaudeAuthError()
  // A refresh token the sign-in service rotated replaces the configured one.
  const refresh = row(sql, "claude.refresh") ?? secret.refreshToken
  let access = row(sql, "claude.access") ?? secret.accessToken
  if (!fresh(access, now)) {
    const res = await fetch(env.CHIEF_BRAIN_CLAUDE_REFRESH_URL || DEFAULT_REFRESH_URL, {
      method: "POST",
      headers: { "content-type": "application/json", "x-hexclave-project-id": env.CHIEF_BRAIN_CLAUDE_PROJECT || DEFAULT_PROJECT, "x-hexclave-access-type": "client", "x-hexclave-refresh-token": refresh },
      body: "{}"
    }).catch(() => null)
    const body = res?.ok ? ((await res.json().catch(() => null)) as { access_token?: unknown; refresh_token?: unknown } | null) : null
    if (typeof body?.access_token !== "string" || timesOf(body.access_token).exp <= now) throw new ClaudeAuthError()
    access = body.access_token
    put(sql, "claude.access", access)
    if (typeof body.refresh_token === "string" && body.refresh_token) put(sql, "claude.refresh", body.refresh_token)
  }
  return JSON.stringify({ accessToken: access, refreshToken: row(sql, "claude.refresh") ?? refresh })
}

/**
 * A fetch for the Anthropic client that signs requests for the metered route: the placeholder API
 * key is removed and `X-Stack-Auth` set; the body and the answer are converted for Bedrock
 * (bedrock-stream.ts). `auth` throws ClaudeAuthError on failure.
 */
export const signedFetch = (auth: () => Promise<string>, refused: () => Promise<void>, route: { readonly auth: "stack" | "bearer"; readonly models: ReadonlyArray<string>; readonly effortBody?: boolean; readonly ttl?: string } = { auth: "stack", models: [] }): typeof fetch =>
  (async (input: RequestInfo | URL, init?: RequestInit) => {
    const headers = new Headers(init?.headers)
    for (const h of ["x-api-key", "authorization", "anthropic-beta", "anthropic-version", "content-length"]) headers.delete(h)
    headers.set(route.auth === "bearer" ? "authorization" : "X-Stack-Auth", await auth())
    headers.set("x-coderouter-client", "cmux-cloud-chief")
    // A route that serves one model names it in its own Bedrock URL; a multi-model route reads `model`.
    const body = typeof init?.body === "string" ? bedrockBody(init.body, { keepModel: route.models.length > 1, effort: route.effortBody === true, ...(route.ttl ? { ttl: route.ttl } : {}) }) : init?.body
    const res = await fetch(input, { ...init, headers, ...(body === undefined ? {} : { body }) })
    if (res.status === 401) await refused().catch(() => undefined)
    // The route answers Bedrock's event stream; the Anthropic client reads Messages events.
    if (!res.ok || !res.body || !(res.headers.get("content-type") ?? "").includes("amazon.eventstream")) return res
    return new Response(eventStreamToSse(res.body), { status: res.status, headers: { "content-type": "text/event-stream" } })
  }) as typeof fetch
