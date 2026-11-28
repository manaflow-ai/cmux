import { createHash } from "node:crypto"
import { canonicalJson, type Principal } from "@cmux/ownership"
import type { Connection } from "@cmux/protocol"
import { githubCovers, githubInstallationOf, githubRepoAllowed, mayUse, policyOf, providerAllowed, type ConnectionsState } from "../domains/connections.ts"
import type { Env } from "../env.ts"
import { open, seal, type SealedSecret } from "./crypto.ts"
import { appRequestedPermissions, installationConfigureUrl, installationPage, permissionsShort, type InstallationPage } from "./github-connect.ts"
import { rateLimitMessage, rateLimitWait } from "./provider-core.ts"
import { forgetInstallationToken, github, installationToken, InstallationTokenRefused, logGithubHeadroom, mintedToken, requestInstallationToken, revokeInstallationToken, type Http } from "./providers.ts"

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
export type TokenAsk = { readonly repo: string; readonly permissions: Readonly<Record<string, "read" | "write">>; readonly connection?: string; readonly label?: string; readonly machine?: string; readonly ttlSec?: number }
/**
 * Why a policy.denied refused a repository, so the machine's git and gh can name the one fix (cmux-host
 * github_cli.rs `Refused::explain`): `owner_not_connected`, no connection of this team is on the repository's
 * owner (another account's repository: its owner installs the App); `connection_other_owner`, the selected connection
 * is on another account than the repository's owner; `repo_not_granted`, the owner's installation
 * (or the linking person's recorded access) leaves it out; `repo_not_allowed`, the team's allowlist; `permissions_not_granted`,
 * the installation does not grant the asked access; `workflows_not_allowed`, the team policy's workflows switch.
 */
export type DenyReason = "owner_not_connected" | "connection_other_owner" | "repo_not_granted" | "repo_not_allowed" | "permissions_not_granted" | "workflows_not_allowed"
/** `configure_url`: on a policy.denied for a repository the owner's installation lacks, the installation's page where it is added. */
export type TokenFail = { readonly ok: false; readonly status: number; readonly code: string; readonly message: string; readonly retry_after?: number; readonly configure_url?: string; readonly reason?: DenyReason }
export type TokenReply = { readonly ok: true; readonly value: { token: string; expires_at: string; repo: string; connection_id: string; permissions: Record<string, string>; token_id: string } } | TokenFail

export type RepoListReply =
  | { readonly ok: true; readonly value: { readonly repos: ReadonlyArray<{ readonly full_name: string; readonly private: boolean; readonly default_branch?: string }>; readonly cursor: string | null } }
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
const deny = (reason: DenyReason, message: string): TokenFail => ({ ...fail(403, "policy.denied", message), reason })
const sha256hex = (s: string) => createHash("sha256").update(s).digest("hex")
const enc = new TextEncoder()

/**
 * A machine joined with `acpmux machine join` (cmux-platform's join registry), as machine-github.ts builds it after the
 * platform checked the machine's `cmm_` credential live: it has no install, so no UserDO socket is registered for it.
 */
export const JOINED_MACHINE_KIND = "joined"

/** The ledger's principal key: a joined machine (machine-github.ts), the install, else the person's session. */
export const principalKey = (p: Principal) =>
  p.install_kind === JOINED_MACHINE_KIND && p.bound_machine ? `machine:${p.bound_machine}` : p.kind === "install" && p.install ? `install:${p.install}` : `session:${p.user}`

export const createGithubTokenTable = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS github_tokens (
    token_id TEXT PRIMARY KEY, cache_key TEXT NOT NULL, principal TEXT NOT NULL, install TEXT, team TEXT NOT NULL, repo TEXT NOT NULL,
    connection_id TEXT,
    permissions TEXT NOT NULL, expires_at INTEGER NOT NULL, provider_expires_at INTEGER NOT NULL DEFAULT 0, sealed TEXT NOT NULL,
    revoking INTEGER NOT NULL DEFAULT 0, retry_at INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0)`)
  try {
    sql.exec(`ALTER TABLE github_tokens ADD COLUMN provider_expires_at INTEGER NOT NULL DEFAULT 0`)
  } catch {
    // The column already exists on current deployments.
  }
  try {
    sql.exec(`ALTER TABLE github_tokens ADD COLUMN connection_id TEXT`)
  } catch {
    // Existing tables that already have the column need no migration.
  }
  sql.exec(`UPDATE github_tokens SET provider_expires_at = expires_at WHERE provider_expires_at = 0`)
  sql.exec(`CREATE INDEX IF NOT EXISTS github_tokens_connection ON github_tokens (connection_id)`)
  sql.exec(`CREATE INDEX IF NOT EXISTS github_tokens_cache ON github_tokens (cache_key)`)
  sql.exec(`CREATE INDEX IF NOT EXISTS github_tokens_principal ON github_tokens (principal)`)
}

type Row = { token_id: string; principal: string; install: string | null; team: string; repo: string; connection_id: string | null; permissions: string; expires_at: number; provider_expires_at: number; sealed: string }
const aad = (r: Omit<Row, "sealed">) => enc.encode(`cmux-ghtok-v1|${canonicalJson([r.team, r.principal, r.install, r.repo, r.permissions, r.token_id, Number(r.expires_at)])}`)
const openRow = (env: Env, r: Row) => open(env.INTEGRATIONS_KEK!, JSON.parse(r.sealed) as SealedSecret, aad(r))

/** Token bucket per key (a principal, or a joined machine's minter); the wait in seconds when empty, else null. */
const take = (buckets: LedgerHost["buckets"], key: string, now: number): number | null => {
  const b = buckets.get(key) ?? { tokens: MINT_RATE.burst, at: now }
  const tokens = Math.min(MINT_RATE.burst, b.tokens + ((now - b.at) / 1000) * MINT_RATE.per_second)
  buckets.set(key, { tokens: tokens >= 1 ? tokens - 1 : tokens, at: now })
  return tokens >= 1 ? null : Math.ceil((1 - tokens) / MINT_RATE.per_second)
}

/**
 * GitHub rate limiting cmux (primary, secondary or abuse detection): a retryable 429 that names the wait. It never
 * touches the connection's status and never reads as "connect GitHub" (cmux-platform maps it to a wait as well).
 */
const rateLimited = (retry: number, installation: number, op: string): TokenFail => {
  console.log(JSON.stringify({ msg: "github.rate_limited", installation, op, retry_after: retry }))
  return fail(429, "rate_limited", rateLimitMessage("github", retry), retry)
}

/**
 * A connection's status_detail while its App installation is suspended (a refused mint or the
 * `installation.suspend` webhook). `installation.unsuspend` lifts only a connection with this detail.
 */
export const GITHUB_SUSPENDED_DETAIL = "the GitHub App installation is suspended"
/** A connection's detail once its installation no longer exists: the `installation.deleted` webhook, or GitHub's 404 on a mint. */
export const GITHUB_UNINSTALLED_DETAIL = "the GitHub App was uninstalled"
export const GITHUB_GONE_DETAIL = "the GitHub App installation is gone"
/**
 * Whether `c`'s installation is gone for good (uninstalled; GitHub answered 404). Its settings page is a 404 now, so
 * status names none, and Connect opens the App's install page instead (cmux#55104: Connect GitHub opened
 * github.com/settings/installations/<deleted id>, leaving the person no way back).
 */
export const githubInstallationGone = (c: Pick<Connection, "status" | "status_detail">): boolean =>
  c.status === "needs_reauth" && (c.status_detail === GITHUB_UNINSTALLED_DETAIL || c.status_detail === GITHUB_GONE_DETAIL)

/** The 409 a connection that needs a relink answers; a suspended installation says who can lift it, since a relink cannot. */
const relinkFail = (c: Connection | undefined, fallback: string): TokenFail =>
  c?.status_detail === GITHUB_SUSPENDED_DETAIL
    ? fail(409, "needs_reauth", `the GitHub App installation on ${c.account?.name ?? "this account"} is suspended; an owner of ${c.account?.name ?? "the account"} can unsuspend it in its GitHub settings`)
    : fail(409, "needs_reauth", fallback)

/**
 * One reading of a GitHub refusal, for the token mint and repository listing alike: the installation
 * is gone (404), suspended (a 403 naming it) or, where `unauthorizedIsRelink`, refuses us (401): a
 * relink; a rate limit keeps GitHub's wait; another 403 or a 422 is a refusal; anything else an outage.
 */
type Refusal = { readonly kind: "relink"; readonly detail: string } | { readonly kind: "rate"; readonly retry: number } | { readonly kind: "denied" } | { readonly kind: "unavailable" }
const githubRefusal = async (res: Response, now: number, unauthorizedIsRelink: boolean): Promise<Refusal> => {
  const message = res.status === 403 ? String(((await res.clone().json().catch(() => ({}))) as { message?: unknown }).message ?? "") : ""
  // A rate limit is read first: taking one for a suspension would mark a working connection needs_reauth.
  const wait = rateLimitWait(res, now, message)
  if (wait !== null) return { kind: "rate", retry: wait }
  if (res.status === 404) return { kind: "relink", detail: GITHUB_GONE_DETAIL }
  if (res.status === 403 && /suspend/i.test(message)) return { kind: "relink", detail: GITHUB_SUSPENDED_DETAIL }
  if (unauthorizedIsRelink && res.status === 401) return { kind: "relink", detail: "GitHub refused the App installation" }
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
  // When the user selected a connection, it is the only possible authority. Never fall
  // back to another installation for the same repo after revoke, expiry or relink.
  const selected = ask.connection === undefined ? undefined : all.find((c) => c.id === ask.connection)
  if (ask.connection !== undefined && selected === undefined)
    return fail(404, "integration.not_found", "the selected GitHub connection is not available")
  if (selected && selected.status !== "active")
    return relinkFail(selected, "the selected GitHub connection needs to be linked again")
  const active = all.filter((c) => c.status === "active")
  if (active.length === 0) return relinkFail(all.find((c) => c.account?.name.toLowerCase() === repo.split("/")[0]!.toLowerCase()), "the team's GitHub connection needs to be linked again")
  // `repositories` names repositories inside the installation's own account: the owner must be that account (githubCovers, shared with Connect's reuse).
  const owned = ownerConnections(active, ask)
  if (selected && owned.length === 0 && selected.account?.name.toLowerCase() !== repo.split("/")[0]!.toLowerCase()) return otherOwner(selected, active, repo)
  const c = owned.find((x) => githubCovers(x, policy, repo))
  const installation = c ? githubInstallationOf(c) : undefined
  if (!c || installation === undefined) return notCovered(owned, policy, repo)
  if (ask.permissions.workflows === "write" && policy.github.allow_workflows !== true) return deny("workflows_not_allowed", "workflows: write needs the team policy github.allowWorkflows")
  return { c, installation }
}

/** The active connections (of `ask.connection` when it names one) on the repository's owner account, with an installation. */
const ownerConnections = (active: ReadonlyArray<Connection>, ask: TokenAsk): ReadonlyArray<Connection> => {
  const owner = ask.repo.split("/")[0]!.toLowerCase()
  return active.filter((x) => (ask.connection === undefined || x.id === ask.connection) && x.account?.name.toLowerCase() === owner && githubInstallationOf(x) !== undefined)
}

/**
 * The selected connection is on another account than `repo`'s owner. It stays the only authority (no fallback), so the
 * reply names it and whether the team has a connection on the owner this principal may use (`active` is mayUse's).
 */
const otherOwner = (selected: Connection, active: ReadonlyArray<Connection>, repo: string): TokenFail => {
  const owner = repo.split("/")[0]!
  const on = selected.account?.name ? `is for ${selected.account.name}, not ${owner}` : `is for another account, not ${owner}`
  const another = active.some((x) => x.id !== selected.id && x.account?.name.toLowerCase() === owner.toLowerCase() && githubInstallationOf(x) !== undefined)
  return deny(
    "connection_other_owner",
    another
      ? `the selected GitHub connection ${on}: select the team's GitHub connection on ${owner} instead`
      : `the selected GitHub connection ${on}, and this team has no other cmux GitHub App connection on ${owner}: the App must be installed on ${owner} and connected to the team`,
  )
}

/**
 * Why no connection covers `repo`: none is on its owner (a repository of an account this team has not connected, such
 * as one the person only collaborates on), the team's allowlist leaves it out, or the owner's connection does not
 * include it (not selected on the installation, or added after the person linked it: the recorded list is the link's).
 */
const notCovered = (owned: ReadonlyArray<Connection>, policy: ReturnType<typeof policyOf>, repo: string): TokenFail => {
  const owner = repo.split("/")[0]!
  if (owned.length === 0) return deny("owner_not_connected", `this team has no cmux GitHub App connection on ${owner}: the App must be installed on ${owner} and connected to the team`)
  // The allowlist alone, whatever the scope.
  const anyScope = { ...policy, github: { ...policy.github, scope: "installation" as const } }
  if (!owned.some((x) => githubRepoAllowed(x, anyScope, repo))) return deny("repo_not_allowed", `the team's GitHub repository allowlist does not include ${repo}`)
  // Only the default scope gets here (the installation scope checks the allowlist alone): the recorded list is what the
  // person who connected GitHub could see in the installation, so either the installation or that person's access lacks it.
  return deny("repo_not_granted", `the team's GitHub connection on ${owner} does not include ${repo}: it lists the repositories the person who connected GitHub could see. If the installation on GitHub leaves ${repo} out, add it there; then connect GitHub again as someone who can see ${repo}`)
}

/** A `repo_not_granted` refusal with the owner's installation page, where the repository is added, when GitHub names one. */
const withConfigurePage = async (h: LedgerHost, p: Principal, ask: TokenAsk, refusal: TokenFail): Promise<TokenFail> => {
  const active = Object.values(h.state().connections).filter((c) => c.provider === "github" && c.status === "active" && mayUse(c, p))
  const c = ownerConnections(active, ask)[0]
  const installation = c ? githubInstallationOf(c) : undefined
  if (!c?.account || installation === undefined) return refusal
  const page = await installationConfigureUrl(h.sql, h.env, h.http, installation, c.account.name, Date.now()).catch(() => null)
  return page ? { ...refusal, configure_url: page } : refusal
}

/**
 * The person's own connections in their personal team, under another team's policy (cmux#55104). A person links GitHub
 * once, often in their personal team (Settings with no Stack team selected), while their Cloud machines run in their
 * selected Stack team, whose ConnectionDO holds none of their connections: the machine's clone ended
 * `seed.needs_github` though the App they installed covers the repository. The token, status and repository routes
 * fall back to this state when the asking team has nothing on the repository's owner. Only connections the person
 * created count (never another member's shared one), and the asking team's policy decides what they may mint.
 */
export const ownConnectionsUnder = (state: ConnectionsState, user: string, policy: ReturnType<typeof policyOf>): ConnectionsState => ({
  ...state,
  policy,
  connections: Object.fromEntries(Object.entries(state.connections).filter(([, c]) => c.created_by === user))
})

/**
 * Whether a refusal in the asking team leaves room for the person's own connections (``ownConnectionsUnder``): the team
 * has no GitHub connection this principal may use, or none on the repository's owner, and the ask selected no connection
 * (a selected one is the only authority). Any other refusal (policy, a relink, a repository the owner's installation
 * leaves out, a rate limit) is the team's answer.
 */
export const ownConnectionsMayAnswer = (refusal: TokenFail, ask: Pick<TokenAsk, "connection">): boolean =>
  ask.connection === undefined && (refusal.code === "integration.not_found" || (refusal.code === "policy.denied" && refusal.reason === "owner_not_connected"))

/** POST /v1/integrations/github/token for an authenticated, team-checked principal. */
export const githubToken = (h: LedgerHost, p: Principal, ask: TokenAsk, now: number): Promise<TokenReply> => {
  if (!github.configured(h.env) || !h.env.INTEGRATIONS_KEK) return Promise.resolve(fail(503, "integration.unavailable", "the cmux GitHub App is not configured on this deployment"))
  const picked = authorize(h.state(), p, ask)
  if ("ok" in picked) return picked.reason === "repo_not_granted" ? withConfigurePage(h, p, ask, picked) : Promise.resolve(picked)
  const pk = principalKey(p)
  const permissions = Object.fromEntries(Object.entries(ask.permissions).sort(([a], [b]) => a.localeCompare(b)))
  // TTL is part of the cache identity: a short machine request must never reuse a longer-lived token.
  const cacheKey = sha256hex(canonicalJson([pk, picked.c.id, picked.installation, ask.repo.toLowerCase(), permissions, ask.ttlSec ?? null]))
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

/**
 * The last answer GitHub gave for an installation's repository page, with its ETag, per isolate: the next listing of
 * that page asks `If-None-Match`, and an unchanged page (304) is served from here without spending the installation's
 * rate limit. GitHub's answer for the installation, before any team filter (the filters below always run), kept as
 * only the fields read here (a full repository object is kilobytes) and for at most REPO_PAGES_KEPT pages.
 */
const repoPages = new Map<string, { readonly etag: string; readonly body: string }>()
const REPO_PAGES_KEPT = 200
const rememberRepoPage = (key: string, etag: string, answer: unknown) => {
  const page = answer as { repositories?: unknown; total_count?: unknown } | undefined
  if (!page || !Array.isArray(page.repositories)) return
  const repositories = page.repositories.map((entry) => {
    const r = (entry ?? {}) as { full_name?: unknown; private?: unknown; default_branch?: unknown }
    return { full_name: r.full_name, private: r.private, default_branch: r.default_branch }
  })
  repoPages.delete(key)
  repoPages.set(key, { etag, body: JSON.stringify({ total_count: page.total_count, repositories }) })
  if (repoPages.size > REPO_PAGES_KEPT) repoPages.delete(repoPages.keys().next().value!)
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
      // Revalidated, not re-read: GitHub answers an unchanged page 304, which costs no rate limit.
      const pageKey = `${installation}:${cursor.page}`
      const known = repoPages.get(pageKey)
      const response = await h.http(new Request(`https://api.github.com/installation/repositories?per_page=100&page=${cursor.page}`, { headers: { authorization: `Bearer ${token}`, accept: "application/vnd.github+json", "x-github-api-version": "2022-11-28", "user-agent": "cmux-cloud", ...(known ? { "if-none-match": known.etag } : {}) } })).catch(() => null)
      if (!response) return null
      logGithubHeadroom(response, { installation, auth: "installation", op: "list_repos" })
      if (response.status === 304 && known) return { token, response: new Response(known.body, { status: 200, headers: { "content-type": "application/json" } }) }
      const etag = response.headers.get("etag")
      if (response.ok && etag) rememberRepoPage(pageKey, etag, await response.clone().json().catch(() => undefined))
      return { token, response }
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
      if (r.kind === "rate") return rateLimited(r.retry, installation, "list_repos")
      if (r.kind === "denied") return fail(403, "policy.denied", "GitHub refused to list this installation's repositories")
      return fail(503, "integration.unavailable", "GitHub repository listing failed")
    }
    const response = (listed as { response: Response }).response
    const body = (await response.json().catch(() => undefined)) as { repositories?: unknown; total_count?: unknown } | undefined
    if (!body || !Array.isArray(body.repositories)) return fail(503, "integration.unavailable", "GitHub returned an invalid repository list")
    const repos = body.repositories.flatMap((entry) => {
      if (!entry || typeof entry !== "object") return []
      const repo = entry as { full_name?: unknown; private?: unknown; default_branch?: unknown }
      const fullName = typeof repo.full_name === "string" ? repo.full_name : ""
      return fullName && githubRepoAllowed(connection, policyOf(state), fullName) && (!cursor.query || fullName.toLowerCase().includes(cursor.query))
        ? [{ full_name: fullName, private: repo.private === true, ...(typeof repo.default_branch === "string" && repo.default_branch ? { default_branch: repo.default_branch } : {}) }]
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

/** GitHub includes metadata:read implicitly; every other grant must equal the requested permission. */
const exactGithubGrant = (granted: Readonly<Record<string, string>>, requested: Readonly<Record<string, "read" | "write">>): boolean =>
  Object.entries(requested).every(([name, access]) => granted[name] === access) &&
  Object.entries(granted).every(([name, access]) =>
    (name === "metadata" && access === "read" && requested.metadata === undefined) || requested[name] === access
  )

const mintOrReuse = async (h: LedgerHost, picked: { c: Connection; installation: number }, p: Principal, pk: string, cacheKey: string, ask: TokenAsk, now: number): Promise<TokenReply> => {
  const generation = h.revokes.get(pk) ?? 0
  expireRows(h.sql, now)
  // A short-lived ask (a machine token of a few minutes) is reused while half its life remains; the
  // fixed margin alone would exceed its whole life and mint on every ask until the bucket refuses.
  const margin = ask.ttlSec === undefined ? REUSE_MARGIN_MS : Math.min(REUSE_MARGIN_MS, ask.ttlSec * 500)
  const live = h.sql.exec<Row>(`SELECT * FROM github_tokens WHERE cache_key = ? AND principal = ? AND revoking = 0 AND expires_at > ? ORDER BY expires_at DESC LIMIT 1`, cacheKey, pk, now + margin).toArray()[0]
  if (live) {
    // Existing sealed rows may predate the stricter permission check. Never replay an
    // over-scoped token: retire it through the existing revocation ledger first.
    let saved: Record<string, string> | null = null
    try {
      const parsed: unknown = JSON.parse(live.permissions)
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) saved = parsed as Record<string, string>
    } catch { /* corrupt ledger grants are unusable */ }
    if (!saved || !exactGithubGrant(saved, ask.permissions)) {
      h.sql.exec(`UPDATE github_tokens SET revoking = 1, retry_at = ? WHERE token_id = ?`, Date.now(), live.token_id)
      await drainTokenRevocations(h, Date.now())
      return fail(403, "policy.denied", "the cached GitHub token permissions no longer match the requested grant")
    }
    const token = await openRow(h.env, live).catch(() => null)
    const again = authorize(h.state(), p, ask)
    if (token && Number(live.expires_at) > Date.now() + margin && stillLive(h.sql, live.token_id) && (h.revokes.get(pk) ?? 0) === generation && !("ok" in again) && again.c.id === picked.c.id) {
      return { ok: true, value: { token, expires_at: new Date(Number(live.expires_at)).toISOString(), repo: ask.repo, connection_id: picked.c.id, permissions: saved, token_id: live.token_id } }
    }
    if ("ok" in again) return again
  }
  // A joined machine's bucket is its minter's in this team (this ConnectionDO is the team's): N machines one person
  // joined share one rate, never N. Every other principal keeps its own.
  const wait = take(h.buckets, p.install_kind === JOINED_MACHINE_KIND ? `joined-user:${p.user}` : pk, now)
  if (wait !== null) return fail(429, "rate_limited", `too many new GitHub tokens for this caller; try again in ${wait} s`, wait)
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
    if (r.kind === "rate") return rateLimited(r.retry, picked.installation, "mint")
    if (r.kind === "denied") {
      // Adding the repository on the installation's page is the fix the machine's git and gh name (github_cli.rs).
      // GitHub's 422 says which: "The permissions requested are not granted to this installation." or a repository
      // that "does not exist or is not accessible to the parent installation".
      const said = String(((await res.clone().json().catch(() => ({}))) as { message?: unknown }).message ?? "")
      const permissions = /permissions?\b.*\bnot granted/i.test(said)
      if (permissions && picked.c.account) {
        const pending = await permissionsPendingFor(h, picked.installation, picked.c.account.name, ask)
        if (pending) return pending
      }
      const page = picked.c.account ? await installationConfigureUrl(h.sql, h.env, h.http, picked.installation, picked.c.account.name, Date.now()) : null
      const refusal = permissions
        ? deny("permissions_not_granted", `GitHub refused: the installation does not grant ${Object.entries(ask.permissions).map(([k, v]) => `${k}: ${v}`).join(", ")} on ${ask.repo}`)
        : deny("repo_not_granted", `GitHub refused: the installation does not include ${ask.repo} or does not grant these permissions`)
      return { ...refusal, ...(page ? { configure_url: page } : {}) }
    }
    return fail(503, "integration.unavailable", `GitHub token mint failed: HTTP ${res.status}`)
  }
  const minted = await mintedToken(res)
  if (!minted.token) return fail(503, "integration.unavailable", "GitHub returned no token")
  if (!Number.isFinite(minted.expires_at) || minted.expires_at <= now) {
    // A provider response without a trustworthy expiry must never be handed out or cached.
    await revokeInstallationToken(h.http, minted.token)
    return fail(503, "integration.unavailable", "GitHub returned a token without a valid future expiry")
  }
  const tokenId = sha256hex(minted.token).slice(0, 16)
  const requestedExpiry = ask.ttlSec === undefined ? minted.expires_at : Math.min(minted.expires_at, now + ask.ttlSec * 1000)
  const row = {
    token_id: tokenId,
    principal: pk,
    install: p.kind === "install" ? (p.install ?? null) : null,
    team: h.team,
    repo: ask.repo,
    connection_id: picked.c.id,
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
    `INSERT OR REPLACE INTO github_tokens (token_id, cache_key, principal, install, team, repo, connection_id, permissions, expires_at, provider_expires_at, sealed) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    row.token_id, cacheKey, row.principal, row.install, row.team, row.repo, row.connection_id, row.permissions, row.expires_at, row.provider_expires_at, sealed
  )
  // Refuse rather than hand out less than was asked (GitHub never widens; it must not narrow either), or what the state no longer allows.
  if (!exactGithubGrant(minted.permissions, ask.permissions))
    return refuse(fail(403, "policy.denied", "GitHub returned permissions different from the requested repository grant"))
  const changed = () => ((a) => ("ok" in a ? a : a.c.id !== picked.c.id ? fail(403, "policy.denied", "the team's GitHub connection changed; retry") : null))(authorize(h.state(), p, ask))
  const before = changed()
  if (before) return refuse(before)
  // UserDO calls closeInstall here once the install is revoked; false: it already is.
  if (p.kind === "install" && p.install_kind !== JOINED_MACHINE_KIND) {
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
  return { ok: true, value: { token: minted.token, expires_at: new Date(row.expires_at).toISOString(), repo: ask.repo, connection_id: picked.c.id, permissions: { ...minted.permissions }, token_id: tokenId } }
}

/** The code of a mint GitHub refused because the installation has not accepted the App's updated permissions. */
export const GITHUB_PERMISSIONS_PENDING = "github.permissions_pending"

/**
 * A mint GitHub refused for permissions ("not granted to this installation") that the App now requests but the
 * installation has not accepted yet: `github.permissions_pending` with the installation's settings page, where an
 * owner of `account` accepts the update. Read fresh (the refusal is the moment the cached grant may be stale). Null
 * when the App does not request the asked access either (then it is `permissions_not_granted`) or GitHub's answer
 * is not known.
 */
const permissionsPendingFor = async (h: LedgerHost, installation: number, account: string, ask: TokenAsk): Promise<TokenFail | null> => {
  const page: InstallationPage | null = await installationPage(h.sql, h.env, h.http, installation, account, Date.now(), true).catch(() => null)
  if (!page?.url || !page.granted) return null
  const requested = await appRequestedPermissions(h.sql, h.env, h.http, Date.now()).catch(() => null)
  if (!requested || permissionsShort(requested, ask.permissions) || !permissionsShort(page.granted, ask.permissions)) return null
  return { ...fail(403, GITHUB_PERMISSIONS_PENDING, `GitHub needs you to accept cmux's updated permissions for ${account}.`), configure_url: page.url }
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

/**
 * After an integration disconnect, fence affected tokens synchronously before the
 * connection revoke returns. This DO owns one team; unlabelled pre-migration rows
 * are retired conservatively because their originating connection is unknowable.
 * The existing alarm then retries the provider DELETE until expiry.
 */
export const markConnectionTokensRevoked = (
  h: Pick<LedgerHost, "sql" | "revokes">,
  connectionId: string,
  now: number,
): number => {
  const affected = h.sql.exec<{ principal: string }>(
    `SELECT DISTINCT principal FROM github_tokens WHERE revoking = 0 AND (connection_id = ? OR connection_id IS NULL)`,
    connectionId,
  ).toArray()
  for (const row of affected) h.revokes.set(row.principal, (h.revokes.get(row.principal) ?? 0) + 1)
  return h.sql.exec(
    `UPDATE github_tokens SET revoking = 1, retry_at = ? WHERE revoking = 0 AND (connection_id = ? OR connection_id IS NULL)`,
    now,
    connectionId,
  ).rowsWritten
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

/** The GitHub connection GET /status describes to this principal: an active one first, else the latest visible one. */
export const githubStatusConnection = (state: ConnectionsState, p: Principal): Connection | undefined => {
  // `expired` is a pending link that timed out (no account, and activate refuses it): hidden, as on /repos.
  const usable = Object.values(state.connections).filter((c) => c.provider === "github" && mayUse(c, p) && c.status !== "revoked" && c.status !== "expired" && c.status !== "pending")
  return usable.find((x) => x.status === "active") ?? usable.sort((a, b) => b.updated_at - a.updated_at)[0]
}

/**
 * GET /v1/integrations/github/status: whether the App is configured, and the connection this principal would use.
 * `configure_url` is that connection's installation page on GitHub, where repositories are added ("Add more
 * repositories"), or null when it is not known (github-connect.ts installationConfigureUrl). `permissions_pending`: the
 * App now requests permissions the installation has not accepted (a write token is refused until it is), and
 * `accept_url` is then the same settings page, where an owner of the account accepts them; null otherwise.
 */
export const githubStatus = (env: Env, state: ConnectionsState, p: Principal, configureUrl: string | null = null, appSlug: string | null = env.GITHUB_APP_SLUG ?? null, permissionsPending = false) => {
  const c = githubStatusConnection(state, p)
  // A pending permission update: the installation's settings page is where an owner accepts it.
  const pending = permissionsPending && configureUrl !== null
  return {
    configured: Boolean(env.INTEGRATIONS_KEK) && github.configured(env),
    // The slug GitHub names the App now (providers.ts githubAppSlug), so clients build its install URL after a rename.
    app_slug: appSlug,
    // The token route's own policy check: a connection the team policy disallows mints nothing.
    allowed: providerAllowed(policyOf(state), "github"),
    connection: c ? { id: c.id, account: c.account?.name ?? null, status: c.status, repos: c.resources?.repos ?? null, allow_workflows: policyOf(state).github.allow_workflows === true, configure_url: configureUrl, permissions_pending: pending, accept_url: pending ? configureUrl : null } : null
  }
}
