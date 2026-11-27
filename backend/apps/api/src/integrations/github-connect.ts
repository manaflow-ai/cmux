import type { Env } from "../env.ts"
import { appJwt, ghHeaders, type Http, githubInstallBase } from "./providers.ts";

/**
 * Connect's one page for a GitHub repository (design: remote-integrations, "a connect is one inline card, one
 * tap"). Asked with the App's own key, never a person's token, and only about the repository's OWNER: whether
 * a given repository is in an installation is decided at completion with the person's own token, so this
 * answer never tells anyone whether a private repository exists.
 *
 * - installed: the App is installed on the owner. GitHub's OAuth authorize page (which GitHub skips for an App
 *   the person already authorized) brings the code back; the signed state names the installation, the repository
 *   and the installation's configure page. If the person's link leaves the repository out, the callback opens
 *   that configure page instead of the chat.
 * - install: no installation on the owner; the install page, preselecting the owner when its id is known.
 *
 * Any failure, or a lookup past CONNECT_LOOKUP_TIMEOUT_MS, answers `install` with no target, the page Connect
 * opened before this existed.
 *
 * `permissions_pending`: the installation has not accepted the permissions the App requests now (`requested`, the
 * App's own GET /app); Connect then opens its configure page, where GitHub's "Review request" accepts them.
 */
export type GithubConnectTarget =
  | { readonly kind: "installed"; readonly installation: number; readonly configure_url: string; readonly permissions_pending?: true }
  | { readonly kind: "install"; readonly target_id?: number }

const GH_API = "https://api.github.com"
const seg = encodeURIComponent
/** Each owner lookup gets this long; past it Connect answers the install page (the old behavior), never hangs. */
export const CONNECT_LOOKUP_TIMEOUT_MS = 5_000
const bounded = () => AbortSignal.timeout(CONNECT_LOOKUP_TIMEOUT_MS)

/** An installation's settings page on GitHub, where repositories are added to it. */
export const GITHUB_CONFIGURE_URL = /^https:\/\/github\.com\/(?:organizations\/[A-Za-z0-9-]{1,39}\/)?settings\/installations\/[0-9]{1,20}$/

type Installation = { id?: unknown; account?: { login?: unknown; type?: unknown }; permissions?: unknown }

/** Installation `id`'s configure page, when its account is `owner`; undefined for another account or a page GITHUB_CONFIGURE_URL refuses. */
const configurePage = (id: number, inst: Installation, owner: string): string | undefined => {
  const login = typeof inst.account?.login === "string" ? inst.account.login : ""
  if (id < 1 || login.toLowerCase() !== owner.toLowerCase()) return undefined
  const url = inst.account?.type === "Organization"
    ? `https://github.com/organizations/${seg(login)}/settings/installations/${id}`
    : `https://github.com/settings/installations/${id}`
  return GITHUB_CONFIGURE_URL.test(url) ? url : undefined
}

const ownerInstallation = async (env: Env, http: Http, owner: string): Promise<Installation | undefined> => {
  const headers = ghHeaders(await appJwt(env))
  for (const path of [`/orgs/${seg(owner)}/installation`, `/users/${seg(owner)}/installation`]) {
    const res = await http(new Request(`${GH_API}${path}`, { headers, signal: bounded() }))
    if (res.ok) return (await res.json()) as Installation
    if (res.status !== 404) throw new Error(`GitHub ${path}: ${res.status}`)
  }
  return undefined
}

/** The owner's numeric id for `target_id`: public data, asked without a token; best effort. */
const ownerId = async (http: Http, owner: string): Promise<number | undefined> => {
  const res = await http(new Request(`${GH_API}/users/${seg(owner)}`, { headers: { accept: "application/vnd.github+json", "x-github-api-version": "2022-11-28", "user-agent": "cmux-cloud" }, signal: bounded() })).catch(() => null)
  if (!res?.ok) return undefined
  const id = ((await res.json().catch(() => ({}))) as { id?: unknown }).id
  return typeof id === "number" && Number.isSafeInteger(id) && id > 0 ? id : undefined
}

export const githubConnectTarget = async (env: Env, http: Http, repo: string, requested?: () => Promise<Readonly<Record<string, string>> | null>): Promise<GithubConnectTarget> => {
  const owner = repo.split("/")[0]!
  try {
    const inst = await ownerInstallation(env, http, owner)
    if (!inst) return { kind: "install", ...(await ownerId(http, owner).then((id) => (id ? { target_id: id } : {}))) }
    const id = Number(inst.id)
    const configure_url = Number.isSafeInteger(id) ? configurePage(id, inst, owner) : undefined
    if (!configure_url) return { kind: "install" }
    const granted = permsOf(inst.permissions)
    const asks = granted && requested ? await requested().catch(() => null) : null
    return { kind: "installed", installation: id, configure_url, ...(granted && asks && permissionsShort(granted, asks) ? { permissions_pending: true as const } : {}) }
  } catch {
    return { kind: "install" }
  }
}

/** The URL Connect answers for a target: never a permission beyond what the App already asks for. */
export const githubConnectUrl = async (env: Env, target: GithubConnectTarget, state: string, redirectUri: string): Promise<string> => {
  if (target.kind === "installed" && target.permissions_pending) return target.configure_url
  if (target.kind === "installed") {
    const q = new URLSearchParams({ client_id: env.GITHUB_APP_CLIENT_ID!, redirect_uri: redirectUri, state })
    return `https://github.com/login/oauth/authorize?${q}`
  }
  const base = await githubInstallBase(env)
  return target.target_id ? `${base}/permissions?target_id=${target.target_id}&state=${encodeURIComponent(state)}` : `${base}?state=${encodeURIComponent(state)}`
}

/**
 * After a completion: the configure page to open when the person's own link leaves the asked repository out.
 * `repos` is what their token reached (null under the installation scope, where nothing more is known here).
 */
export const configureAfterLink = (repos: ReadonlyArray<string> | null | undefined, repo: string | undefined, configureUrl: string | undefined): string | undefined =>
  repo && configureUrl && GITHUB_CONFIGURE_URL.test(configureUrl) && Array.isArray(repos) && !repos.some((r) => r.toLowerCase() === repo.toLowerCase()) ? configureUrl : undefined

/** GitHub's permission levels, lowest first; an unknown level reads as none. */
const LEVEL: Readonly<Record<string, number>> = { read: 1, write: 2, admin: 3 }
const levelOf = (v: unknown) => (typeof v === "string" ? (LEVEL[v] ?? 0) : 0)
type Perms = Readonly<Record<string, string>>
const permsOf = (value: unknown): Perms | null =>
  value && typeof value === "object" && !Array.isArray(value)
    ? Object.fromEntries(Object.entries(value as Record<string, unknown>).filter((e): e is [string, string] => typeof e[1] === "string"))
    : null

/** Whether `granted` (an installation's) lacks any permission `requested` names, or grants it at a lower level. */
export const permissionsShort = (granted: Perms, requested: Perms): boolean =>
  Object.entries(requested).some(([name, level]) => levelOf(granted[name]) < levelOf(level))

/**
 * The permissions the App itself requests now (GET /app with the App's own key), cached per ConnectionDO for
 * APP_PERMISSIONS_TTL_MS (a failed read for CONFIGURE_MISS_TTL_MS, answering null). When the App asks for more
 * than an installation granted, GitHub mints nothing beyond the old grant until an owner of the installation's
 * account accepts the update on the installation's settings page: that is a pending permission update.
 */
export const APP_PERMISSIONS_TTL_MS = 10 * 60_000

export const createAppPermissionsTable = (sql: SqlStorage) =>
  sql.exec(`CREATE TABLE IF NOT EXISTS github_app_permissions (id INTEGER PRIMARY KEY CHECK (id = 1), permissions TEXT NOT NULL, checked_at INTEGER NOT NULL)`)

export const appRequestedPermissions = async (sql: SqlStorage, env: Env, http: Http, now: number): Promise<Perms | null> => {
  createAppPermissionsTable(sql)
  const row = sql.exec<{ permissions: string; checked_at: number }>(`SELECT permissions, checked_at FROM github_app_permissions WHERE id = 1`).toArray()[0]
  if (row && now - Number(row.checked_at) < (row.permissions ? APP_PERMISSIONS_TTL_MS : CONFIGURE_MISS_TTL_MS)) return row.permissions ? permsOf(JSON.parse(row.permissions)) : null
  let perms: Perms | null = null
  try {
    const res = await http(new Request(`${GH_API}/app`, { headers: ghHeaders(await appJwt(env)), signal: AbortSignal.timeout(CONFIGURE_LOOKUP_TIMEOUT_MS) }))
    perms = res.ok ? permsOf(((await res.json()) as { permissions?: unknown }).permissions) : null
  } catch {
    perms = null
  }
  sql.exec(`INSERT OR REPLACE INTO github_app_permissions (id, permissions, checked_at) VALUES (1, ?, ?)`, perms ? JSON.stringify(perms) : "", now)
  return perms
}

/**
 * Where "Add more repositories" goes for a linked installation: its configure page, cached per ConnectionDO so
 * GET /status (read on every repository picker open) asks GitHub at most once per CONFIGURE_PAGE_TTL_MS per
 * installation. The cache is short because it is also how a read verifies the installation still exists: a missed
 * `installation.deleted` webhook (or an App the installation no longer belongs to) left a deleted installation's
 * page cached for a day, and Connect opened GitHub's 404 (cmux#55104). GitHub's 404 answers `gone`, caches
 * nothing, and the caller marks the connection gone. The
 * connection stores the installation id and account login but not whether the account is an organization,
 * which picks the page's path, so the first ask reads GET /app/installations/:id with the App's own key, within
 * CONFIGURE_LOOKUP_TIMEOUT_MS. A failed or refused ask is remembered for CONFIGURE_MISS_TTL_MS and answers null.
 * A row is used only for the same account login, so a relink to a renamed account asks again.
 */
export const CONFIGURE_LOOKUP_TIMEOUT_MS = 2_000
export const CONFIGURE_PAGE_TTL_MS = 5 * 60_000
export const CONFIGURE_MISS_TTL_MS = 10 * 60_000

export const createConfigurePageTable = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS github_configure_pages (installation INTEGER PRIMARY KEY, login TEXT NOT NULL, url TEXT NOT NULL, checked_at INTEGER NOT NULL)`)
  try {
    sql.exec(`ALTER TABLE github_configure_pages ADD COLUMN granted TEXT NOT NULL DEFAULT ''`)
  } catch {
    // The column already exists.
  }
  createAppPermissionsTable(sql)
}

/**
 * What GitHub says about a linked installation: its configure page (null when not known), whether it is gone (404),
 * its granted permissions (null when not known), and whether the App now requests more than it granted
 * (`permissionsPending`: an owner accepts the update on the configure page).
 */
export type InstallationPage = { readonly url: string | null; readonly gone: boolean; readonly granted: Perms | null; readonly permissionsPending: boolean }

/** Installation `installation`'s page; `fresh` skips the cache (a reinstall's check of the installation it replaces). */
export const installationPage = async (sql: SqlStorage, env: Env, http: Http, installation: number, login: string, now: number, fresh = false): Promise<InstallationPage> => {
  const row = fresh ? undefined : sql.exec<{ login: string; url: string; checked_at: number; granted: string }>(`SELECT login, url, checked_at, granted FROM github_configure_pages WHERE installation = ?`, installation).toArray()[0]
  if (row && row.login === login.toLowerCase() && now - Number(row.checked_at) < (row.url ? CONFIGURE_PAGE_TTL_MS : CONFIGURE_MISS_TTL_MS)) {
    const url = row.url && GITHUB_CONFIGURE_URL.test(row.url) ? row.url : null
    return withPending(sql, env, http, now, url, row.granted ? permsOf(JSON.parse(row.granted)) : null)
  }
  let url: string | undefined
  let granted: Perms | null = null
  try {
    const res = await http(new Request(`${GH_API}/app/installations/${installation}`, { headers: ghHeaders(await appJwt(env)), signal: AbortSignal.timeout(CONFIGURE_LOOKUP_TIMEOUT_MS) }))
    if (res.status === 404) {
      sql.exec(`DELETE FROM github_configure_pages WHERE installation = ?`, installation)
      return { url: null, gone: true, granted: null, permissionsPending: false }
    }
    const inst = res.ok ? ((await res.json()) as Installation) : undefined
    url = inst ? configurePage(installation, inst, login) : undefined
    granted = url && inst ? permsOf(inst.permissions) : null
  } catch {
    url = undefined
  }
  sql.exec(`INSERT OR REPLACE INTO github_configure_pages (installation, login, url, checked_at, granted) VALUES (?, ?, ?, ?, ?)`, installation, login.toLowerCase(), url ?? "", now, granted ? JSON.stringify(granted) : "")
  return withPending(sql, env, http, now, url ?? null, granted)
}

/** Pending only when the page, the installation's grant and the App's own request are all known. */
const withPending = async (sql: SqlStorage, env: Env, http: Http, now: number, url: string | null, granted: Perms | null): Promise<InstallationPage> => {
  const requested = url && granted ? await appRequestedPermissions(sql, env, http, now) : null
  return { url, gone: false, granted, permissionsPending: requested !== null && granted !== null && permissionsShort(granted, requested) }
}

export const installationConfigureUrl = async (sql: SqlStorage, env: Env, http: Http, installation: number, login: string, now: number): Promise<string | null> =>
  (await installationPage(sql, env, http, installation, login, now)).url
