import { createHash } from "node:crypto"
import { canonicalJson, type Principal } from "@cmux/ownership"
import type { Connection } from "@cmux/protocol"
import { githubRepoAllowed, mayUse, policyOf, providerAllowed, type ConnectionsState } from "../domains/connections.ts"
import type { Env } from "../env.ts"
import { open, seal, type SealedSecret } from "./crypto.ts"
import { github, mintedToken, requestInstallationToken, revokeInstallationToken, type Http } from "./providers.ts"

/**
 * GitHub installation tokens handed to callers (POST /v1/integrations/github/token, gh-app-product
 * contract): one repository, exactly the asked permissions, for one principal (an install or a
 * person's session). The team's ConnectionDO keeps the ledger, which is also the cache: each live
 * token is sealed under INTEGRATIONS_KEK (AAD: principal, install, team, repo, permissions,
 * token_id, expiry), reused for the same principal, installation, repo and permissions while more
 * than 15 minutes remain, never for another principal, and dropped once it expires. A revoke (the
 * route, or UserDO's closeInstall after an install revoke or machine delete) sends GitHub
 * `DELETE /installation/token` per token; a failed one is retried from the alarm until expiry.
 * A token never reaches a log, event, audit record or error; token_id (16 hex of SHA-256) names it.
 */

/** New mints per principal (cache hits are free): a burst of 60, then one per second, in memory. */
const [REUSE_MARGIN_MS, MINT_RATE, REVOKE_RETRY_MAX_MS] = [15 * 60_000, { burst: 60, per_second: 1 }, 10 * 60_000]

/** `machine`: a vm install's own machine (the route checked it through vmGate). */
export type TokenAsk = { readonly repo: string; readonly permissions: Readonly<Record<string, "read" | "write">>; readonly label?: string; readonly machine?: string }
export type TokenFail = { readonly ok: false; readonly status: number; readonly code: string; readonly message: string; readonly retry_after?: number }
export type TokenReply = { readonly ok: true; readonly value: { token: string; expires_at: string; repo: string; permissions: Record<string, string>; token_id: string } } | TokenFail

/** What the ledger needs from its ConnectionDO. */
export interface LedgerHost {
  readonly sql: SqlStorage; readonly env: Env; readonly http: Http; readonly team: string
  /** The ConnectionDO's state now. */
  readonly state: () => ConnectionsState
  /** Asks the install's UserDO to call closeInstall here when the install is revoked; false: it is not active. */
  readonly register: (p: Principal, expiresAt: number) => Promise<boolean>
  readonly audit: (record: Record<string, unknown>) => void
  readonly needsReauth: (c: Connection, detail: string) => void
  readonly buckets: Map<string, { tokens: number; at: number }>
  readonly inflight: Map<string, Promise<TokenReply>>
  /** Revokes per principal key since this object started: a mint that began before one never answers (memory: a restart drops in-flight mints too). */
  readonly revokes: Map<string, number>
}

const fail = (status: number, code: string, message: string, retry_after?: number): TokenFail => ({ ok: false, status, code, message, ...(retry_after === undefined ? {} : { retry_after }) })
const sha256hex = (s: string) => createHash("sha256").update(s).digest("hex")
const enc = new TextEncoder()

/** The ledger's principal key: the install, else the person's session. */
export const principalKey = (p: Principal) => (p.kind === "install" && p.install ? `install:${p.install}` : `session:${p.user}`)

export const createGithubTokenTable = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS github_tokens (
    token_id TEXT PRIMARY KEY, cache_key TEXT NOT NULL, principal TEXT NOT NULL, install TEXT, team TEXT NOT NULL, repo TEXT NOT NULL,
    permissions TEXT NOT NULL, expires_at INTEGER NOT NULL, sealed TEXT NOT NULL, revoking INTEGER NOT NULL DEFAULT 0, retry_at INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0)`)
  sql.exec(`CREATE INDEX IF NOT EXISTS github_tokens_cache ON github_tokens (cache_key)`)
  sql.exec(`CREATE INDEX IF NOT EXISTS github_tokens_principal ON github_tokens (principal)`)
}

type Row = { token_id: string; principal: string; install: string | null; team: string; repo: string; permissions: string; expires_at: number; sealed: string }
const aad = (r: Omit<Row, "sealed">) => enc.encode(`cmux-ghtok-v1|${canonicalJson([r.team, r.principal, r.install, r.repo, r.permissions, r.token_id, Number(r.expires_at)])}`)
const openRow = (env: Env, r: Row) => open(env.INTEGRATIONS_KEK!, JSON.parse(r.sealed) as SealedSecret, aad(r))

/** Token bucket per principal; the wait in seconds when empty, else null. */
const take = (buckets: LedgerHost["buckets"], key: string, now: number): number | null => {
  const b = buckets.get(key) ?? { tokens: MINT_RATE.burst, at: now }
  const tokens = Math.min(MINT_RATE.burst, b.tokens + ((now - b.at) / 1000) * MINT_RATE.per_second)
  buckets.set(key, { tokens: tokens >= 1 ? tokens - 1 : tokens, at: now })
  return tokens >= 1 ? null : Math.ceil((1 - tokens) / MINT_RATE.per_second)
}

/** Seconds GitHub asks us to wait (Retry-After, else the primary limit's reset), at least 1. */
const retryAfter = (res: Response, now: number) => {
  const [after, reset] = [Number(res.headers.get("retry-after")), Number(res.headers.get("x-ratelimit-reset"))]
  return Number.isFinite(after) && after > 0 ? Math.ceil(after) : Number.isFinite(reset) && reset * 1000 > now ? Math.ceil(reset - now / 1000) : 60
}

/**
 * The connection and policy checks of one ask against the state now (run again after every await
 * that could change it): a GitHub connection this principal may use, active, of the repository's
 * owner, whose repository scope and the team's allowlist include it; workflows: write needs the flag.
 */
const authorize = (state: ConnectionsState, p: Principal, ask: TokenAsk): { c: Connection; installation: number } | TokenFail => {
  const repo = ask.repo
  const all = Object.values(state.connections).filter((c) => c.provider === "github" && mayUse(c, p) && (c.status === "active" || c.status === "needs_reauth" || c.status === "error"))
  if (all.length === 0) return fail(404, "integration.not_found", "this team has no GitHub connection")
  const policy = policyOf(state)
  if (!providerAllowed(policy, "github")) return fail(403, "policy.denied", "the team policy does not allow GitHub")
  const active = all.filter((c) => c.status === "active")
  if (active.length === 0) return fail(409, "needs_reauth", "the team's GitHub connection needs to be linked again")
  const owner = repo.split("/")[0]!.toLowerCase()
  // `repositories` names repositories inside the installation's own account: the owner must be that account.
  const c = active.find((x) => x.account?.name.toLowerCase() === owner && githubRepoAllowed(x, policy, repo))
  const installation = Number(/^github:installation:(\d+)$/.exec(c?.account?.key ?? "")?.[1])
  if (!c || !Number.isSafeInteger(installation)) return fail(403, "policy.denied", `the team's GitHub connection may not act on ${repo} (team policy or the linking user's access)`)
  if (ask.permissions.workflows === "write" && policy.github.allow_workflows !== true) return fail(403, "policy.denied", "workflows: write needs the team policy github.allowWorkflows")
  return { c, installation }
}

/** POST /v1/integrations/github/token for an authenticated, team-checked principal. */
export const githubToken = (h: LedgerHost, p: Principal, ask: TokenAsk, now: number): Promise<TokenReply> => {
  if (!github.configured(h.env) || !h.env.INTEGRATIONS_KEK) return Promise.resolve(fail(503, "integration.unavailable", "the cmux GitHub App is not configured on this deployment"))
  const picked = authorize(h.state(), p, ask)
  if ("ok" in picked) return Promise.resolve(picked)
  const pk = principalKey(p)
  const permissions = Object.fromEntries(Object.entries(ask.permissions).sort(([a], [b]) => a.localeCompare(b)))
  const cacheKey = sha256hex(canonicalJson([pk, picked.installation, ask.repo.toLowerCase(), permissions]))
  // One mint at a time per cache key: concurrent asks share it (and the token).
  const running = h.inflight.get(cacheKey)
  if (running) return running
  const work = mintOrReuse(h, picked, p, pk, cacheKey, { ...ask, permissions }, now).finally(() => h.inflight.delete(cacheKey))
  h.inflight.set(cacheKey, work)
  return work
}

/** A row is served only while it is live and nobody revoked it (checked after each await, with no await before the answer). */
const stillLive = (sql: SqlStorage, tokenId: string) => sql.exec(`SELECT 1 FROM github_tokens WHERE token_id = ? AND revoking = 0`, tokenId).toArray().length > 0

const mintOrReuse = async (h: LedgerHost, picked: { c: Connection; installation: number }, p: Principal, pk: string, cacheKey: string, ask: TokenAsk, now: number): Promise<TokenReply> => {
  const generation = h.revokes.get(pk) ?? 0
  pruneExpired(h.sql, now)
  const live = h.sql.exec<Row>(`SELECT * FROM github_tokens WHERE cache_key = ? AND principal = ? AND revoking = 0 AND expires_at > ? ORDER BY expires_at DESC LIMIT 1`, cacheKey, pk, now + REUSE_MARGIN_MS).toArray()[0]
  if (live) {
    const token = await openRow(h.env, live).catch(() => null)
    const again = authorize(h.state(), p, ask)
    if (token && stillLive(h.sql, live.token_id) && (h.revokes.get(pk) ?? 0) === generation && !("ok" in again) && again.c.id === picked.c.id) {
      return { ok: true, value: { token, expires_at: new Date(Number(live.expires_at)).toISOString(), repo: ask.repo, permissions: JSON.parse(live.permissions) as Record<string, string>, token_id: live.token_id } }
    }
    if ("ok" in again) return again
  }
  const wait = take(h.buckets, pk, now)
  if (wait !== null) return fail(429, "rate_limited", "too many new GitHub tokens for this caller; slow down", wait)
  let res: Response
  try {
    res = await requestInstallationToken(h.env, h.http, picked.installation, { repositories: [ask.repo.split("/")[1]!], permissions: ask.permissions })
  } catch {
    return fail(503, "integration.unavailable", "GitHub did not answer; retry")
  }
  if (!res.ok) {
    const message = String((await res.clone().json().catch(() => ({})) as { message?: unknown }).message ?? "")
    if (res.status === 404 || (res.status === 403 && /suspend/i.test(message))) {
      h.needsReauth(picked.c, res.status === 404 ? "the GitHub App installation is gone" : "the GitHub App installation is suspended")
      return fail(409, "needs_reauth", "the GitHub App installation is gone or suspended; link GitHub again")
    }
    if (res.status === 429 || (res.status === 403 && (res.headers.get("x-ratelimit-remaining") === "0" || res.headers.has("retry-after")))) return fail(429, "rate_limited", "GitHub is rate limiting this installation", retryAfter(res, now))
    if (res.status === 403 || res.status === 422) return fail(403, "policy.denied", `GitHub refused: the installation does not include ${ask.repo} or does not grant these permissions`)
    return fail(503, "integration.unavailable", `GitHub token mint failed: HTTP ${res.status}`)
  }
  const minted = await mintedToken(res)
  if (!minted.token) return fail(503, "integration.unavailable", "GitHub returned no token")
  const tokenId = sha256hex(minted.token).slice(0, 16)
  const row = { token_id: tokenId, principal: pk, install: p.kind === "install" ? (p.install ?? null) : null, team: h.team, repo: ask.repo, permissions: JSON.stringify(minted.permissions), expires_at: minted.expires_at }
  const sealed = JSON.stringify(await seal(h.env.INTEGRATIONS_KEK!, minted.token, aad(row)))
  // From here every minted token has a durable row: one we refuse is revoked at GitHub (retried from the alarm until it expires).
  const refuse = async (f: TokenFail) => {
    h.sql.exec(`UPDATE github_tokens SET revoking = 1, retry_at = ? WHERE token_id = ?`, Date.now(), tokenId)
    await drainTokenRevocations(h, Date.now())
    return f
  }
  h.sql.exec(
    `INSERT OR REPLACE INTO github_tokens (token_id, cache_key, principal, install, team, repo, permissions, expires_at, sealed) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    row.token_id, cacheKey, row.principal, row.install, row.team, row.repo, row.permissions, row.expires_at, sealed
  )
  // Refuse rather than hand out less than was asked (GitHub never widens; it must not narrow either), or what the state no longer allows.
  const short = Object.entries(ask.permissions).find(([k, v]) => !(minted.permissions[k] === "write" || minted.permissions[k] === v))
  if (short) return refuse(fail(403, "policy.denied", `GitHub granted less than ${short[0]}: ${short[1]}`))
  const changed = () => ((a) => ("ok" in a ? a : a.c.id !== picked.c.id ? fail(403, "policy.denied", "the team's GitHub connection changed; retry") : null))(authorize(h.state(), p, ask))
  const before = changed()
  if (before) return refuse(before)
  // UserDO calls closeInstall here once the install is revoked; false: it already is.
  if (p.kind === "install") {
    const registered = await h.register(p, minted.expires_at).catch(() => null)
    if (registered !== true) return refuse(registered === null ? fail(503, "integration.unavailable", "the install could not be checked; retry") : fail(401, "auth.required", "this install was revoked"))
    const after = changed()
    if (after) return refuse(after)
  }
  // A revoke that ran during the awaits above marked the row, or ran before it existed: never hand it out.
  if (!stillLive(h.sql, tokenId) || (h.revokes.get(pk) ?? 0) !== generation) return refuse(fail(401, "auth.required", "this caller's GitHub tokens were revoked"))
  const kind = p.kind === "install" ? (p.install_kind ?? "cli") : "session"
  h.audit({
    at: now, team: h.team, principal_kind: kind, user: p.user!,
    ...(row.install ? { install: row.install } : {}), ...(ask.machine ? { machine: ask.machine } : {}), ...(ask.label ? { label: ask.label } : {}),
    repo: ask.repo, permissions: minted.permissions, token_id: tokenId, expires_at: minted.expires_at
  })
  console.log(JSON.stringify({ msg: "github.token.minted", team: h.team, principal_kind: kind, install: row.install, repo: ask.repo, token_id: tokenId, label: ask.label ?? null }))
  return { ok: true, value: { token: minted.token, expires_at: new Date(minted.expires_at).toISOString(), repo: ask.repo, permissions: { ...minted.permissions }, token_id: tokenId } }
}

const pruneExpired = (sql: SqlStorage, now: number) => sql.exec(`DELETE FROM github_tokens WHERE expires_at <= ?`, now)

/**
 * Revokes every live token of one principal (`install:<id>` or `session:<user>`), or of one install
 * by id: marks the rows, then tries GitHub's DELETE for each at once. Returns how many were live.
 */
export const revokeTokens = async (h: Pick<LedgerHost, "sql" | "env" | "http" | "revokes">, who: { principal: string } | { install: string }, now: number): Promise<number> => {
  const key = "install" in who ? `install:${who.install}` : who.principal
  h.revokes.set(key, (h.revokes.get(key) ?? 0) + 1)
  pruneExpired(h.sql, now)
  const [col, val] = "install" in who ? ["install", who.install] : ["principal", who.principal]
  const n = h.sql.exec(`UPDATE github_tokens SET revoking = 1, retry_at = ? WHERE ${col} = ? AND revoking = 0`, now, val).rowsWritten
  await drainTokenRevocations(h, now)
  return n
}

/** The alarm's pass: drops expired rows and retries the DELETEs that are due (backoff up to 10 minutes). */
export const drainTokenRevocations = async (h: Pick<LedgerHost, "sql" | "env" | "http">, now: number) => {
  pruneExpired(h.sql, now)
  const due = h.sql.exec<Row & { attempts: number }>(`SELECT * FROM github_tokens WHERE revoking = 1 AND retry_at <= ? LIMIT 100`, now).toArray()
  await Promise.all(
    due.map(async (r) => {
      const token = await openRow(h.env, r).catch(() => null)
      // A row that does not open (a KEK misconfigured or rotated) stays for the next try and goes only at its expiry.
      if (token === null) console.error(JSON.stringify({ msg: "github token revoke: the ledger row does not open", token_id: r.token_id }))
      if (token !== null && (await revokeInstallationToken(h.http, token))) h.sql.exec(`DELETE FROM github_tokens WHERE token_id = ?`, r.token_id)
      else h.sql.exec(`UPDATE github_tokens SET attempts = attempts + 1, retry_at = ? WHERE token_id = ?`, now + Math.min(REVOKE_RETRY_MAX_MS, 5_000 * 2 ** Number(r.attempts)), r.token_id)
    })
  )
}

/** When the alarm has ledger work: the next revoke retry or the next expiry. */
export const nextLedgerAt = (sql: SqlStorage): number | null => {
  const r = sql.exec<{ at: number | null }>(`SELECT MIN(CASE WHEN revoking = 1 AND retry_at < expires_at THEN retry_at ELSE expires_at END) AS at FROM github_tokens`).toArray()[0]
  return r?.at === null || r?.at === undefined ? null : Number(r.at)
}

/** GET /v1/integrations/github/status: whether the App is configured, and the connection this principal would use. */
export const githubStatus = (env: Env, state: ConnectionsState, p: Principal) => {
  const usable = Object.values(state.connections).filter((c) => c.provider === "github" && mayUse(c, p) && c.status !== "revoked" && c.status !== "expired" && c.status !== "pending")
  const c = usable.find((x) => x.status === "active") ?? usable.sort((a, b) => b.updated_at - a.updated_at)[0]
  return {
    configured: Boolean(env.INTEGRATIONS_KEK) && github.configured(env),
    app_slug: env.GITHUB_APP_SLUG ?? null,
    connection: c ? { id: c.id, account: c.account?.name ?? null, status: c.status, repos: c.resources?.repos ?? null, allow_workflows: policyOf(state).github.allow_workflows === true } : null
  }
}
