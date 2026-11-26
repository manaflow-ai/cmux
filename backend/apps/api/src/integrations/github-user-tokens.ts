import type { Env } from "../env.ts"
import { kmsConfig, openSecretText, sealSecretText, type CredentialAddress } from "./credentials.ts"
import type { Http } from "./provider-core.ts"

/**
 * GitHub App user-to-server tokens: acting as the person who linked GitHub, within what the cmux GitHub App
 * may do (github-integration-audit.md fix 7: "commits and PRs from agents are authored by the App bot").
 *
 * - Only the refresh token is stored, sealed with the credentials envelope (KMS data key; INTEGRATIONS_KEK
 *   alone only in development and test, never in production) at an address naming the connection and the
 *   person. A GitHub App with expiring user tokens off gives no refresh token, and then nothing is stored.
 * - The access token (8 hours at GitHub) lives in this isolate's memory only.
 * - The row goes with the connection's disconnect (and so with the team's), and when GitHub refuses the
 *   refresh token (the person revoked the App's authorization).
 * - Only server-side effects use it (ConnectionDO's provider calls). A machine never receives one: machines
 *   get one-repository installation tokens (security rule 4: a scoped, expiring capability, never a raw OAuth
 *   token).
 * - Any failure answers undefined and the caller uses the installation token, as before.
 */

/** What a GitHub code exchange gave besides the access token, when GitHub issued a refresh token. */
export interface GithubUserGrant {
  readonly access_token: string
  readonly expires_at: number
  readonly refresh_token: string
  readonly refresh_expires_at: number
  readonly github_id?: number
}

const PROVIDER = "github_user"
/** An access token is reused while at least this much of it remains. */
const ACCESS_MARGIN_MS = 5 * 60_000
/** GitHub's documented lifetimes, used when the exchange omits them. */
const [ACCESS_DEFAULT_MS, REFRESH_DEFAULT_MS] = [8 * 3600_000, 184 * 24 * 3600_000]

const access = new Map<string, { token: string; expires_at: number }>()
const refreshing = new Map<string, Promise<string | undefined>>()
const keyOf = (connection: string, user: string) => `${connection}\u0000${user}`

export const createGithubUserTokenTable = (sql: SqlStorage) =>
  sql.exec(`CREATE TABLE IF NOT EXISTS github_user_tokens (
    connection TEXT NOT NULL, user TEXT NOT NULL, generation INTEGER NOT NULL, sealed TEXT NOT NULL,
    refresh_expires_at INTEGER NOT NULL, github_id INTEGER, updated_at INTEGER NOT NULL, PRIMARY KEY (connection, user))`)

/** Whether this deployment may store a refresh token: KMS, or the bare KEK only in development and test. */
export const userTokensSealable = (env: Env): boolean =>
  kmsConfig(env) !== undefined || ((env.ENVIRONMENT === "development" || env.ENVIRONMENT === "test") && Boolean(env.INTEGRATIONS_KEK))

/** The grant in a GitHub OAuth token answer, when it carries a refresh token. */
export const grantOf = (body: Record<string, unknown>, now: number): GithubUserGrant | undefined => {
  const { access_token, refresh_token, expires_in, refresh_token_expires_in } = body
  if (typeof access_token !== "string" || !access_token || typeof refresh_token !== "string" || !refresh_token) return undefined
  const secs = (v: unknown, fallback: number) => (typeof v === "number" && Number.isFinite(v) && v > 0 ? v * 1000 : fallback)
  return { access_token, refresh_token, expires_at: now + secs(expires_in, ACCESS_DEFAULT_MS), refresh_expires_at: now + secs(refresh_token_expires_in, REFRESH_DEFAULT_MS) }
}

const address = (connection: string, user: string, generation: number): CredentialAddress => ({ connection, owner: user, provider: PROVIDER, generation })

/** Seals `grant`'s refresh token for (connection, user) and keeps its access token in memory. False: not stored. */
export const storeUserGrant = async (sql: SqlStorage, env: Env, http: Http, connection: string, user: string, grant: GithubUserGrant, now: number): Promise<boolean> => {
  if (!userTokensSealable(env)) return false
  const prev = sql.exec<{ generation: number }>(`SELECT generation FROM github_user_tokens WHERE connection = ? AND user = ?`, connection, user).toArray()[0]
  const generation = Number(prev?.generation ?? 0) + 1
  const sealed = await sealSecretText(env, http, address(connection, user, generation), grant.refresh_token)
  sql.exec(
    `INSERT OR REPLACE INTO github_user_tokens (connection, user, generation, sealed, refresh_expires_at, github_id, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
    connection, user, generation, JSON.stringify(sealed), grant.refresh_expires_at, grant.github_id ?? null, now
  )
  access.set(keyOf(connection, user), { token: grant.access_token, expires_at: grant.expires_at })
  return true
}

/** Drops (connection, user)'s row and access token, or every person's on the connection. */
export const forgetUserTokens = (sql: SqlStorage, connection: string, user?: string) => {
  if (user === undefined) sql.exec(`DELETE FROM github_user_tokens WHERE connection = ?`, connection)
  else sql.exec(`DELETE FROM github_user_tokens WHERE connection = ? AND user = ?`, connection, user)
  for (const k of [...access.keys()]) if (k.startsWith(`${connection}\u0000`) && (user === undefined || k === keyOf(connection, user))) access.delete(k)
}

/** Forgets an access token GitHub refused (a 401), so the next ask refreshes. */
export const dropAccessToken = (connection: string, user: string, token: string) => {
  if (access.get(keyOf(connection, user))?.token === token) access.delete(keyOf(connection, user))
}

/**
 * The person's access token on this connection, refreshed when needed; undefined when they never authorized,
 * this deployment may not store one, or GitHub refused (the caller then uses the installation token).
 */
export const userAccessToken = async (sql: SqlStorage, env: Env, http: Http, connection: string, user: string, now: number): Promise<string | undefined> => {
  const key = keyOf(connection, user)
  const cached = access.get(key)
  if (cached && cached.expires_at - ACCESS_MARGIN_MS > now) return cached.token
  // One refresh at a time per person: a refresh token is single use.
  const running = refreshing.get(key)
  if (running) return running
  const job = refresh(sql, env, http, connection, user, now).finally(() => refreshing.delete(key))
  refreshing.set(key, job)
  return job
}

const refresh = async (sql: SqlStorage, env: Env, http: Http, connection: string, user: string, now: number): Promise<string | undefined> => {
  const row = sql.exec<{ generation: number; sealed: string; refresh_expires_at: number; github_id: number | null }>(
    `SELECT generation, sealed, refresh_expires_at, github_id FROM github_user_tokens WHERE connection = ? AND user = ?`, connection, user
  ).toArray()[0]
  if (!row) return undefined
  if (Number(row.refresh_expires_at) <= now || !env.GITHUB_APP_CLIENT_ID || !env.GITHUB_APP_CLIENT_SECRET) {
    if (Number(row.refresh_expires_at) <= now) forgetUserTokens(sql, connection, user)
    return undefined
  }
  try {
    const refreshToken = await openSecretText(env, http, address(connection, user, Number(row.generation)), row.sealed)
    const res = await http(
      new Request("https://github.com/login/oauth/access_token", {
        method: "POST",
        headers: { accept: "application/json", "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ client_id: env.GITHUB_APP_CLIENT_ID, client_secret: env.GITHUB_APP_CLIENT_SECRET, grant_type: "refresh_token", refresh_token: refreshToken }).toString(),
        signal: AbortSignal.timeout(10_000)
      })
    )
    const body = (await res.json().catch(() => ({}))) as Record<string, unknown>
    const grant = res.ok ? grantOf(body, now) : undefined
    if (!grant) {
      // GitHub answers 200 with `error` for a refused refresh token: the person revoked the authorization,
      // or the token was spent. Drop the row; a relink stores a new one.
      if (body.error === "bad_refresh_token" || body.error === "unauthorized") forgetUserTokens(sql, connection, user)
      console.log(JSON.stringify({ msg: "github.user_token.refresh_failed", connection, status: res.status, error: typeof body.error === "string" ? body.error.slice(0, 40) : null }))
      return undefined
    }
    await storeUserGrant(sql, env, http, connection, user, { ...grant, ...(row.github_id ? { github_id: Number(row.github_id) } : {}) }, now)
    return grant.access_token
  } catch (e) {
    console.log(JSON.stringify({ msg: "github.user_token.refresh_failed", connection, error: e instanceof Error ? e.name : "unknown" }))
    return undefined
  }
}

/** Test only: empties the per-isolate access tokens. */
export const resetUserTokensForTest = () => {
  access.clear()
  refreshing.clear()
}
