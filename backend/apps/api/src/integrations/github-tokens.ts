import { createHash } from "node:crypto"
import { canonicalJson, type Principal } from "@cmux/ownership"
import type { Connection } from "@cmux/protocol"
import { githubRepoAllowed, mayUse, policyOf, providerAllowed, type ConnectionsState } from "../domains/connections.ts"
import type { Env } from "../env.ts"
import { open, seal, type SealedSecret } from "./crypto.ts"
import { forgetInstallationToken, github, installationToken, InstallationTokenRefused, mintedToken, requestInstallationToken, revokeInstallationToken, type Http } from "./providers.ts"

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
export type TokenAsk = { readonly repo: string; readonly permissions: Readonly<Record<string, "read" | "write">>; readonly label?: string; readonly machine?: string; readonly ttlSec?: number }
export type TokenFail = { readonly ok: false; readonly status: number; readonly code: string; readonly message: string; readonly retry_after?: number }
export type TokenReply = { readonly ok: true; readonly value: { token: string; expires_at: string; repo: string; permissions: Record<string, string>; token_id: string } } | TokenFail

export type RepoListReply =
  | { readonly ok: true; readonly value: { readonly repos: ReadonlyArray<{ readonly full_name: string; readonly private: boolean }>; readonly cursor: string | null } }
  | TokenFail

/** What the ledger needs from its ConnectionDO. */
export interface LedgerHost {
  readonly sql: SqlStorage; readonly env: Env; readonly http: Http; readonly team: string
  /** The ConnectionDO's state now. */
  readonly state: () => ConnectionsState
  /** Asks the install's UserDO to call closeInstall here when the install is revoked; false: it is not active. */
  readonly register: (p: Principal, expiresAt: number) => Promise<boolean>
  /** Whether the install and its grant are still live (UserDO); checked again after an await, as the mint's register is. */
  readonly installActive: (p: Principal) => Promise<boolean>
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
    permissions TEXT NOT NULL, expires_at INTEGER NOT NULL, provider_expires_at INTEGER NOT NULL DEFAULT 0, sealed TEXT NOT NULL,
    revoking INTEGER NOT NULL DEFAULT 0, retry_at INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0)`)
  try {
    sql.exec(`ALTER TABLE github_tokens ADD COLUMN provider_expires_at INTEGER NOT NULL DEFAULT 0`)
  } catch {
    // The column already exists on current deployments.
  }
  sql.exec(`UPDATE github_tokens SET provider_expires_at = expires_at WHERE provider_expires_at = 0`)
  sql.exec(`CREATE INDEX IF NOT EXISTS github_tokens_cache ON github_tokens (cache_key)`)
  sql.exec(`CREATE INDEX IF NOT EXISTS github_tokens_principal ON github_tokens (principal)`)
}

type Row = { token_id: string; principal: string; install: string | null; team: string; repo: string; permissions: string; expires_at: number; provider_expires_at: number; sealed: string }
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
 * One reading of a GitHub refusal, for the token mint and repository listing alike: the installation
 * is gone (404), suspended (a 403 naming it) or, where `unauthorizedIsRelink`, refuses us (401): a
 * relink; a rate limit keeps GitHub's wait; another 403 or a 422 is a refusal; anything else an outage.
 */
type Refusal = { readonly kind: "relink"; readonly detail: string } | { readonly kind: "rate"; readonly retry: number } | { readonly kind: "denied" } | { readonly kind: "unavailable" }
const githubRefusal = async (res: Response, now: number, unauthorizedIsRelink: boolean): Promise<Refusal> => {
  const message = res.status === 403 ? String(((await res.clone().json().catch(() => ({}))) as { message?: unknown }).message ?? "") : ""
  if (res.status === 404) return { kind: "relink", detail: "the GitHub App installation is gone" }
  if (res.status === 403 && /suspend/i.test(message)) return { kind: "relink", detail: "the GitHub App installation is suspended" }
  if (unauthorizedIsRelink && res.status === 401) return { kind: "relink", detail: "GitHub refused the App installation" }
  if (res.status === 429 || (res.status === 403 && (res.headers.get("x-ratelimit-remaining") === "0" || res.headers.has("retry-after")))) return { kind: "rate", retry: retryAfter(res, now) }
  if (res.status === 403 || res.status === 422) return { kind: "denied" }
  return { kind: "unavailable" }
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
  // TTL is part of the cache identity: a short machine request must never reuse a longer-lived token.
  const cacheKey = sha256hex(canonicalJson([pk, picked.installation, ask.repo.toLowerCase(), permissions, ask.ttlSec ?? null]))
  // One mint at a time per cache key: concurrent asks share it (and the token).
  const running = h.inflight.get(cacheKey)
  if (running) return running
  const work = mintOrReuse(h, picked, p, pk, cacheKey, { ...ask, permissions }, now).finally(() => h.inflight.delete(cacheKey))
  h.inflight.set(cacheKey, work)
  return work
}

/**
 * The connection id, not its position: a connection that changes status between pages cannot shift
 * the walk onto another installation. The normalized query rides along, so later pages stay filtered.
 */
type RepoCursor = { readonly connection: string; readonly page: number; readonly query: string }
const encodeRepoCursor = (cursor: RepoCursor) => {
  // UTF-8 first: btoa takes Latin-1 only, and a query may be any text.
  const raw = btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(cursor))))
  return raw.replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "")
}
const decodeRepoCursor = (value: string): RepoCursor | TokenFail => {
  try {
    const padded = value.replaceAll("-", "+").replaceAll("_", "/") + "===".slice((value.length + 3) % 4)
    const parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(Uint8Array.from(atob(padded), (c) => c.charCodeAt(0)))) as { connection?: unknown; page?: unknown; query?: unknown }
    if (typeof parsed.connection !== "string" || parsed.connection === "" || typeof parsed.page !== "number" || !Number.isSafeInteger(parsed.page) || parsed.page < 1 || typeof parsed.query !== "string")
      return fail(400, "request.invalid", "cursor is invalid")
    return { connection: parsed.connection, page: parsed.page, query: parsed.query }
  } catch {
    return fail(400, "request.invalid", "cursor is invalid")
  }
}

/** Lists one bounded upstream page at a time; the cursor carries installation and page. */
export const githubRepos = async (
  h: { readonly env: Env; readonly http: Http; readonly state: () => ConnectionsState; readonly needsReauth: LedgerHost["needsReauth"]; readonly installActive: LedgerHost["installActive"] },
  p: Principal,
  query: { readonly query?: string; readonly cursor?: string },
): Promise<RepoListReply> => {
  if (p.kind === "install" && p.install_kind !== "vm" && !p.grant_classes?.includes("read")) return fail(403, "auth.forbidden", "this install's grant does not cover read")
  if (!github.configured(h.env) || !h.env.INTEGRATIONS_KEK) return fail(503, "integration.unavailable", "the cmux GitHub App is not configured on this deployment")
  const state = h.state()
  if (!providerAllowed(policyOf(state), "github")) return fail(403, "policy.denied", "the team policy does not allow GitHub")
  // As the token path (authorize): a visible connection that needs a relink is 409 needs_reauth, not "no connection".
  const visible = Object.values(state.connections).filter((c) => c.provider === "github" && mayUse(c, p) && (c.status === "active" || c.status === "needs_reauth" || c.status === "error"))
  if (visible.length === 0) return fail(404, "integration.not_found", "this team has no GitHub connection")
  const connections = visible.filter((c) => c.status === "active").sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
  if (connections.length === 0) return fail(409, "needs_reauth", "the team's GitHub connection needs to be linked again")
  const asked = (query.query ?? "").trim().toLowerCase()
  const cursor = query.cursor === undefined ? { connection: connections[0]!.id, page: 1, query: asked } : decodeRepoCursor(query.cursor)
  if ("ok" in cursor) return cursor
  if (query.query !== undefined && asked !== cursor.query) return fail(400, "request.invalid", "cursor belongs to another query; list again")
  const at = connections.findIndex((c) => c.id === cursor.connection)
  // The paginated connection is gone or no longer active: list again rather than continue in another installation.
  if (at < 0) return fail(400, "request.invalid", "cursor is stale: the GitHub connection changed while listing; list again")
  const connection = connections[at]!
  {
    const installation = Number(/^github:installation:(\d+)$/.exec(connection.account?.key ?? "")?.[1])
    if (!Number.isSafeInteger(installation)) return fail(503, "integration.unavailable", "the GitHub connection has no installation")
    // A listing GitHub answers with a refusal the mint reads as a relink (the token revoked, the
    // installation removed or suspended) drops the cached installation token and tries once more with
    // a fresh one, whose mint may answer for the installation itself. Every refusal, the mint's or the
    // listing's, then reads as the token mint reads its own (githubRefusal).
    type Attempt = { readonly token: string; readonly response: Response } | { readonly mint: Response }
    const list = async (): Promise<Attempt | null> => {
      let token: string
      try {
        token = await installationToken(h.env, h.http, installation)
      } catch (error) {
        return error instanceof InstallationTokenRefused ? { mint: error.response } : null
      }
      const response = await h.http(new Request(`https://api.github.com/installation/repositories?per_page=100&page=${cursor.page}`, { headers: { authorization: `Bearer ${token}`, accept: "application/vnd.github+json", "x-github-api-version": "2022-11-28", "user-agent": "cmux-cloud" } })).catch(() => null)
      return response ? { token, response } : null
    }
    const stale = async (a: Attempt | null) => a !== null && "token" in a && !a.response.ok && (await githubRefusal(a.response, Date.now(), true)).kind === "relink"
    let listed = await list()
    if (await stale(listed)) {
      forgetInstallationToken(installation, (listed as { token: string }).token)
      listed = await list()
      if (await stale(listed)) forgetInstallationToken(installation, (listed as { token: string }).token)
    }
    if (!listed) return fail(503, "integration.unavailable", "GitHub did not answer; retry")
    const refusal = "mint" in listed ? listed.mint : listed.response.ok ? null : listed.response
    if (refusal) {
      // A 401 on the mint is GitHub refusing the App's own JWT, not the installation (as on the token path).
      const r = await githubRefusal(refusal, Date.now(), !("mint" in listed))
      if (r.kind === "relink") {
        // Recorded on the connection, so /status shows the relink and later asks stop minting for it;
        // only while it is the version this listing started from: a relink that landed while GitHub
        // answered is not undone by this stale refusal.
        const now = h.state().connections[connection.id]
        if (now?.status === "active" && now.updated_at === connection.updated_at && now.account?.key === connection.account?.key) h.needsReauth(connection, r.detail)
        return fail(409, "needs_reauth", "the GitHub App installation is gone or suspended; link GitHub again")
      }
      if (r.kind === "rate") return fail(429, "rate_limited", "GitHub is rate limiting this installation", r.retry)
      if (r.kind === "denied") return fail(403, "policy.denied", "GitHub refused to list this installation's repositories")
      return fail(503, "integration.unavailable", "GitHub repository listing failed")
    }
    const response = (listed as { response: Response }).response
    const body = (await response.json().catch(() => undefined)) as { repositories?: unknown; total_count?: unknown } | undefined
    if (!body || !Array.isArray(body.repositories)) return fail(503, "integration.unavailable", "GitHub returned an invalid repository list")
    const repos = body.repositories.flatMap((entry) => {
      if (!entry || typeof entry !== "object") return []
      const repo = entry as { full_name?: unknown; private?: unknown }
      const fullName = typeof repo.full_name === "string" ? repo.full_name : ""
      return fullName && githubRepoAllowed(connection, policyOf(state), fullName) && (!cursor.query || fullName.toLowerCase().includes(cursor.query))
        ? [{ full_name: fullName, private: repo.private === true }]
        : []
    })
    const hasNext = body.repositories.length >= 100 && (typeof body.total_count !== "number" || cursor.page * 100 < body.total_count)
    const next = hasNext
      ? { connection: connection.id, page: cursor.page + 1, query: cursor.query }
      : at + 1 < connections.length
        ? { connection: connections[at + 1]!.id, page: 1, query: cursor.query }
        : null
    // An install revoked while GitHub answered gets no repository names (the mint checks the same after its awaits).
    if (p.kind === "install") {
      const active = await h.installActive(p).catch(() => null)
      if (active === null) return fail(503, "integration.unavailable", "the install could not be checked; retry")
      if (!active) return fail(401, "auth.required", "this install was revoked")
    }
    const current = h.state()
    if (!providerAllowed(policyOf(current), "github")) return fail(403, "policy.denied", "the team policy does not allow GitHub")
    const stillAllowed = Object.values(current.connections).some(
      (candidate) =>
        candidate.id === connection.id &&
        candidate.provider === "github" &&
        candidate.status === "active" &&
        mayUse(candidate, p) &&
        repos.every((repo) => githubRepoAllowed(candidate, policyOf(current), repo.full_name)),
    )
    if (repos.length > 0 && !stillAllowed) return fail(403, "policy.denied", "the team's GitHub connection changed; retry")
    return { ok: true, value: { repos, cursor: next ? encodeRepoCursor(next) : null } }
  }
}

/** A row is served only while it is live and nobody revoked it (checked after each await, with no await before the answer). */
const stillLive = (sql: SqlStorage, tokenId: string) => sql.exec(`SELECT 1 FROM github_tokens WHERE token_id = ? AND revoking = 0`, tokenId).toArray().length > 0

const mintOrReuse = async (h: LedgerHost, picked: { c: Connection; installation: number }, p: Principal, pk: string, cacheKey: string, ask: TokenAsk, now: number): Promise<TokenReply> => {
  const generation = h.revokes.get(pk) ?? 0
  expireRows(h.sql, now)
  // A short-lived ask (a machine token of a few minutes) is reused while half its life remains; the
  // fixed margin alone would exceed its whole life and mint on every ask until the bucket refuses.
  const margin = ask.ttlSec === undefined ? REUSE_MARGIN_MS : Math.min(REUSE_MARGIN_MS, ask.ttlSec * 500)
  const live = h.sql.exec<Row>(`SELECT * FROM github_tokens WHERE cache_key = ? AND principal = ? AND revoking = 0 AND expires_at > ? ORDER BY expires_at DESC LIMIT 1`, cacheKey, pk, now + margin).toArray()[0]
  if (live) {
    const token = await openRow(h.env, live).catch(() => null)
    const again = authorize(h.state(), p, ask)
    if (token && Number(live.expires_at) > Date.now() + margin && stillLive(h.sql, live.token_id) && (h.revokes.get(pk) ?? 0) === generation && !("ok" in again) && again.c.id === picked.c.id) {
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
    const r = await githubRefusal(res, now, false)
    if (r.kind === "relink") {
      h.needsReauth(picked.c, r.detail)
      return fail(409, "needs_reauth", "the GitHub App installation is gone or suspended; link GitHub again")
    }
    if (r.kind === "rate") return fail(429, "rate_limited", "GitHub is rate limiting this installation", r.retry)
    if (r.kind === "denied") return fail(403, "policy.denied", `GitHub refused: the installation does not include ${ask.repo} or does not grant these permissions`)
    return fail(503, "integration.unavailable", `GitHub token mint failed: HTTP ${res.status}`)
  }
  const minted = await mintedToken(res)
  if (!minted.token) return fail(503, "integration.unavailable", "GitHub returned no token")
  if (!Number.isFinite(minted.expires_at) || minted.expires_at <= now) return fail(503, "integration.unavailable", "GitHub returned an expired token")
  const tokenId = sha256hex(minted.token).slice(0, 16)
  const requestedExpiry = ask.ttlSec === undefined ? minted.expires_at : Math.min(minted.expires_at, now + ask.ttlSec * 1000)
  const row = {
    token_id: tokenId,
    principal: pk,
    install: p.kind === "install" ? (p.install ?? null) : null,
    team: h.team,
    repo: ask.repo,
    permissions: JSON.stringify(minted.permissions),
    expires_at: requestedExpiry,
    provider_expires_at: minted.expires_at,
  }
  const sealed = JSON.stringify(await seal(h.env.INTEGRATIONS_KEK!, minted.token, aad(row)))
  // From here every minted token has a durable row: one we refuse is revoked at GitHub (retried from the alarm until it expires).
  const refuse = async (f: TokenFail) => {
    h.sql.exec(`UPDATE github_tokens SET revoking = 1, retry_at = ? WHERE token_id = ?`, Date.now(), tokenId)
    await drainTokenRevocations(h, Date.now())
    return f
  }
  h.sql.exec(
    `INSERT OR REPLACE INTO github_tokens (token_id, cache_key, principal, install, team, repo, permissions, expires_at, provider_expires_at, sealed) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    row.token_id, cacheKey, row.principal, row.install, row.team, row.repo, row.permissions, row.expires_at, row.provider_expires_at, sealed
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
  // Provider calls, sealing and install registration can outlast a short requested TTL.
  // Keep the durable revocation path even when GitHub's native token is still live.
  if (row.expires_at <= Date.now()) return refuse(fail(503, "integration.unavailable", "the GitHub token expired before it could be returned; retry"))
  const kind = p.kind === "install" ? (p.install_kind ?? "cli") : "session"
  h.audit({
    at: now, team: h.team, principal_kind: kind, user: p.user!,
    ...(row.install ? { install: row.install } : {}), ...(ask.machine ? { machine: ask.machine } : {}), ...(ask.label ? { label: ask.label } : {}),
    repo: ask.repo, permissions: minted.permissions, token_id: tokenId, expires_at: row.expires_at
  })
  console.log(JSON.stringify({ msg: "github.token.minted", team: h.team, principal_kind: kind, install: row.install, repo: ask.repo, token_id: tokenId, label: ask.label ?? null }))
  return { ok: true, value: { token: minted.token, expires_at: new Date(row.expires_at).toISOString(), repo: ask.repo, permissions: { ...minted.permissions }, token_id: tokenId } }
}

const expireRows = (sql: SqlStorage, now: number) =>
  sql.exec(`UPDATE github_tokens SET revoking = 1, retry_at = ? WHERE expires_at <= ? AND revoking = 0`, now, now)

/**
 * Revokes every live token of one principal (`install:<id>` or `session:<user>`), or of one install
 * by id: marks the rows, then tries GitHub's DELETE for each at once. Returns how many were live.
 */
export const revokeTokens = async (h: Pick<LedgerHost, "sql" | "env" | "http" | "revokes">, who: { principal: string } | { install: string }, now: number): Promise<number> => {
  const key = "install" in who ? `install:${who.install}` : who.principal
  h.revokes.set(key, (h.revokes.get(key) ?? 0) + 1)
  expireRows(h.sql, now)
  const [col, val] = "install" in who ? ["install", who.install] : ["principal", who.principal]
  const n = h.sql.exec(`UPDATE github_tokens SET revoking = 1, retry_at = ? WHERE ${col} = ? AND revoking = 0`, now, val).rowsWritten
  await drainTokenRevocations(h, now)
  return n
}

/** The alarm's pass: revokes expired rows and retries provider DELETEs (backoff up to 10 minutes). */
export const drainTokenRevocations = async (h: Pick<LedgerHost, "sql" | "env" | "http">, now: number) => {
  expireRows(h.sql, now)
  // A row is due at its retry or at GitHub's native expiry, whichever comes first (then it is only dropped).
  const due = h.sql.exec<Row & { attempts: number }>(
    `SELECT * FROM github_tokens WHERE revoking = 1 AND (retry_at <= ? OR (provider_expires_at > 0 AND provider_expires_at <= ?)) LIMIT 100`, now, now
  ).toArray()
  await Promise.all(
    due.map(async (r) => {
      // Once GitHub's native expiry has passed, the provider token is unusable even if DELETE
      // remains unavailable. Drop the sealed row so a KEK or provider outage cannot retain it forever.
      if (r.provider_expires_at > 0 && r.provider_expires_at <= now) {
        h.sql.exec(`DELETE FROM github_tokens WHERE token_id = ?`, r.token_id)
        return
      }
      const token = await openRow(h.env, r).catch(() => null)
      // A row that does not open (a KEK misconfigured or rotated) stays for the next try and goes only at its expiry.
      if (token === null) console.error(JSON.stringify({ msg: "github token revoke: the ledger row does not open", token_id: r.token_id }))
      if (token !== null && (await revokeInstallationToken(h.http, token))) h.sql.exec(`DELETE FROM github_tokens WHERE token_id = ?`, r.token_id)
      else h.sql.exec(`UPDATE github_tokens SET attempts = attempts + 1, retry_at = ? WHERE token_id = ?`, now + Math.min(REVOKE_RETRY_MAX_MS, 5_000 * 2 ** Number(r.attempts)), r.token_id)
    })
  )
}

/** When the alarm has ledger work: the next revoke retry (or GitHub's native expiry, if sooner) or the next expiry. */
export const nextLedgerAt = (sql: SqlStorage): number | null => {
  const r = sql.exec<{ at: number | null }>(
    `SELECT MIN(CASE WHEN revoking = 1 THEN (CASE WHEN provider_expires_at > 0 AND provider_expires_at < retry_at THEN provider_expires_at ELSE retry_at END) ELSE expires_at END) AS at FROM github_tokens`
  ).toArray()[0]
  return r?.at === null || r?.at === undefined ? null : Number(r.at)
}

/** GET /v1/integrations/github/status: whether the App is configured, and the connection this principal would use. */
export const githubStatus = (env: Env, state: ConnectionsState, p: Principal) => {
  // `expired` is a pending link that timed out (no account, and activate refuses it): hidden, as on /repos.
  const usable = Object.values(state.connections).filter((c) => c.provider === "github" && mayUse(c, p) && c.status !== "revoked" && c.status !== "expired" && c.status !== "pending")
  const c = usable.find((x) => x.status === "active") ?? usable.sort((a, b) => b.updated_at - a.updated_at)[0]
  return {
    configured: Boolean(env.INTEGRATIONS_KEK) && github.configured(env),
    app_slug: env.GITHUB_APP_SLUG ?? null,
    // The token route's own policy check: a connection the team policy disallows mints nothing.
    allowed: providerAllowed(policyOf(state), "github"),
    connection: c ? { id: c.id, account: c.account?.name ?? null, status: c.status, repos: c.resources?.repos ?? null, allow_workflows: policyOf(state).github.allow_workflows === true } : null
  }
}
