import type { Env } from "../env.ts"
import { bedrockBody, eventStreamToSse } from "../model-gateway/bedrock-stream.ts"
import { BEDROCK_IDS, claudeRoute, claudeRouteReady, meteredOwner, offers, OPUS, type RouteAuth } from "../model-gateway/routes.ts"

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
/** Paid-model turns per owner per UTC day (default; CHIEF_BRAIN_CLAUDE_DAILY_TURNS). */
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

/**
 * Metered-turn counting, sharded (no global object on a turn's path): each owner's daily count lives
 * in that owner's own object (ChiefBrainDO name `claude-turns/<owner>`, ownerTurn). The optional
 * deployment bound CHIEF_BRAIN_CLAUDE_DAILY_TURNS_TOTAL (unset in production) is the only shared
 * counter: the HOLDER object grants an owner object a lease of LEASE turns at a time (leaseTotal), so
 * it sees one call per LEASE turns of an owner, not one per turn. An unused lease is never returned
 * (the bound can be undershot by at most LEASE per owner per day, never overshot).
 */
export type TurnVerdict = "ok" | "owner_not_allowed" | "model_not_offered" | "daily_cap"
export const turnsObject = (owner: string) => `claude-turns/${owner}`
const LEASE = 20
const dayOf = (now: number) => new Date(now).toISOString().slice(0, 10)
/** Keeps only today's rows of a counter family (one row per day otherwise stays forever). */
const dropOldDays = (sql: SqlStorage, prefix: string, day: string) => sql.exec(`DELETE FROM cb_config WHERE name LIKE ? AND name NOT LIKE ?`, `${prefix}%`, `%:${day}`)

/** In the owner's object: one metered turn (a Claude or OpenRouter model) of `owner`: allow-list, the model offered here, the per-owner and deployment daily caps. */
export const ownerTurn = async (env: Env, sql: SqlStorage, owner: string, model: string, lease: (day: string, n: number) => Promise<number>, now = Date.now()): Promise<TurnVerdict> => {
  if (!meteredOwner(env, owner)) return "owner_not_allowed"
  if (!offers(env, model)) return "model_not_offered"
  // Per owner (CHIEF_BRAIN_CLAUDE_DAILY_TURNS, default 500): one person's busy Chiefs never use up another person's turns.
  const day = dayOf(now)
  const mine = `claude.turns:${owner}:${day}`
  const usedMine = Number(row(sql, mine) ?? 0)
  if (usedMine >= (Number(env.CHIEF_BRAIN_CLAUDE_DAILY_TURNS) || DEFAULT_DAILY_CLAUDE_TURNS)) return "daily_cap"
  const total = Number(env.CHIEF_BRAIN_CLAUDE_DAILY_TURNS_TOTAL)
  if (Number.isFinite(total) && total > 0) {
    const key = `claude.lease:${day}`
    if (Number(row(sql, key) ?? 0) <= 0) {
      // `lease` is single-flight in the owner's object: the first waiter gets the grant (added, never overwritten), the others 0 and read the row again.
      const got = await lease(day, LEASE).catch(() => 0)
      if (got > 0) put(sql, key, String(Number(row(sql, key) ?? 0) + got))
      if (Number(row(sql, key) ?? 0) <= 0) return "daily_cap"
      // The per-owner cap again: other turns may have counted during the lease.
      if (Number(row(sql, mine) ?? 0) >= (Number(env.CHIEF_BRAIN_CLAUDE_DAILY_TURNS) || DEFAULT_DAILY_CLAUDE_TURNS)) return "daily_cap"
    }
    put(sql, key, String(Number(row(sql, key) ?? 0) - 1))
  }
  if (usedMine === 0) [dropOldDays(sql, "claude.turns:", day), dropOldDays(sql, "claude.lease:", day)]
  put(sql, mine, String(Number(row(sql, mine) ?? 0) + 1))
  return "ok"
}

/** In the HOLDER object: up to `want` turns of today's deployment bound for one owner object. */
export const leaseTotal = (env: Env, sql: SqlStorage, day: string, want: number): number => {
  const total = Number(env.CHIEF_BRAIN_CLAUDE_DAILY_TURNS_TOTAL)
  if (!(Number.isFinite(total) && total > 0)) return want
  const all = `claude.turns:${day}`
  const used = Number(row(sql, all) ?? 0)
  const grant = Math.max(0, Math.min(Math.floor(want), total - used))
  if (used === 0) dropOldDays(sql, "claude.turns:", day)
  if (grant > 0) put(sql, all, String(used + grant))
  return grant
}

/**
 * The route's auth header for a caller in any object, with no global call in the steady state:
 * service-key and bearer routes are computed here (static Worker secrets); the session route's
 * header is cached in this isolate until its access token is due for refresh (the same margin as
 * the holder's), and only then read from the HOLDER object, which alone refreshes (one at a time).
 */
let cached: { header: string; access: string } | null = null
let reading: Promise<string> | null = null
export const claudeAuthFor = (env: Env, holder: () => { claudeAuth(): Promise<string> }, now = Date.now()): Promise<string> => {
  if (claudeRoute(env).auth !== "stack-session") return holderAuth(env, null as unknown as SqlStorage, now)
  if (cached && fresh(cached.access, now)) return Promise.resolve(cached.header)
  reading ??= holder()
    .claudeAuth()
    .then((header) => {
      let access = ""
      try {
        access = (JSON.parse(header) as { accessToken?: string }).accessToken ?? ""
      } catch {
        // Never a parse error that quotes the header (token bytes).
        throw new ClaudeAuthError()
      }
      cached = { header, access }
      return header
    })
    .finally(() => (reading = null))
  reading.catch(() => undefined)
  return reading
}
/** The route answered 401: this isolate's copy goes too. */
export const forgetClaudeAuth = (): void => void (cached = null)

/** The route refused the stored access token: drop it, so the next request refreshes. */
export const holderInvalidate = (sql: SqlStorage): void => void sql.exec(`DELETE FROM cb_config WHERE name = 'claude.access'`)

/**
 * The `X-Stack-Auth` header value, refreshed when needed (in the holder object). Throws
 * ClaudeAuthError (fixed text) when there is no secret or the refresh fails.
 */
export const holderAuth = async (env: Env, sql: SqlStorage, now = Date.now()): Promise<string> => {
  // A route with a static key: nothing to refresh (service-key: the signed fetch sends the key itself).
  if (claudeRoute(env).auth === "service-key") {
    if (!env.CHIEF_BRAIN_CLAUDE_SERVICE_KEY) throw new ClaudeAuthError()
    return "service-key"
  }
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
export interface SignedRoute {
  /** Gets each field or beta the Bedrock conversion dropped, and an upstream refusal's text (logged, no secrets). */
  readonly log?: (what: string) => void
  /** Map the caller's anthropic-beta header into the Bedrock body (the HTTP gateway: Claude Code). The brain's own calls send none, as proven. */
  readonly forwardBetas?: boolean
  readonly auth: RouteAuth
  readonly models: ReadonlyArray<string>
  readonly effortBody?: boolean
  readonly ttl?: string
  /** service-key: the route's key (never logged). */
  readonly key?: string
}
export const signedFetch = (auth: () => Promise<string>, refused: () => Promise<void>, route: SignedRoute = { auth: "stack-session", models: [] }): typeof fetch =>
  (async (input: RequestInfo | URL, init?: RequestInit) => {
    const headers = new Headers(init?.headers)
    const betas = (headers.get("anthropic-beta") ?? "").split(",").map((b) => b.trim()).filter(Boolean)
    for (const h of ["x-api-key", "authorization", "anthropic-beta", "anthropic-version", "content-length"]) headers.delete(h)
    const service = route.auth === "service-key"
    // The payer and call headers are the service-key route's contract; no other route gets them.
    if (!service) for (const h of ["x-cmux-team-id", "x-cmux-chief-id", "x-request-id"]) headers.delete(h)
    if (service) {
      // The gateway set x-cmux-team-id (required), x-cmux-chief-id and x-request-id per call.
      if (!route.key || !headers.get("x-cmux-team-id")) throw new ClaudeAuthError()
      headers.set("x-api-key", route.key)
    } else headers.set(route.auth === "bearer" ? "authorization" : "X-Stack-Auth", await auth())
    headers.set("x-coderouter-client", "cmux-cloud-chief")
    headers.set("user-agent", "cmux-cloud-chief/1")
    // The Chatmux session route names Opus in its own Bedrock URL; a service-key or multi-model route reads `model` (the Bedrock id).
    const model = service ? (id: string) => BEDROCK_IDS[id] ?? id : undefined
    const body = typeof init?.body === "string" ? bedrockBody(init.body, { keepModel: service || route.models.length > 1, ...(model ? { modelId: model } : {}), effort: route.effortBody === true, ...(route.forwardBetas ? { betas } : {}), ...(route.log ? { dropped: route.log } : {}), ...(route.ttl ? { ttl: route.ttl } : {}) }) : init?.body
    let res = await fetch(input, { ...init, headers, ...(body === undefined ? {} : { body }) })
    if (res.status === 401) {
      await refused().catch(() => undefined)
      // A cached header another isolate's refresh made stale: one more try with a fresh one.
      if (!service) {
        headers.set(route.auth === "bearer" ? "authorization" : "X-Stack-Auth", await auth())
        res = await fetch(input, { ...init, headers, ...(body === undefined ? {} : { body }) })
        if (res.status === 401) await refused().catch(() => undefined)
      }
    }
    // The route answers Bedrock's event stream; the Anthropic client reads Messages events.
    if (!res.ok || !res.body || !(res.headers.get("content-type") ?? "").includes("amazon.eventstream")) return res
    // The route names the Bedrock region that answered (x-bedrock-region): kept for the run's timing.
    const region = res.headers.get("x-bedrock-region")
    return new Response(eventStreamToSse(res.body), { status: res.status, headers: { "content-type": "text/event-stream", ...(region ? { "x-bedrock-region": region } : {}) } })
  }) as typeof fetch
