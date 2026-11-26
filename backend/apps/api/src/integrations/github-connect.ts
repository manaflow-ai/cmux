import type { Env } from "../env.ts"
import { appJwt, ghHeaders, githubInstallBase, type Http } from "./providers.ts"

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
 */
export type GithubConnectTarget =
  | { readonly kind: "installed"; readonly installation: number; readonly configure_url: string }
  | { readonly kind: "install"; readonly target_id?: number }

const GH_API = "https://api.github.com"
const seg = encodeURIComponent
/** Each owner lookup gets this long; past it Connect answers the install page (the old behavior), never hangs. */
export const CONNECT_LOOKUP_TIMEOUT_MS = 5_000
const bounded = () => AbortSignal.timeout(CONNECT_LOOKUP_TIMEOUT_MS)

/** An installation's settings page on GitHub, where repositories are added to it. */
export const GITHUB_CONFIGURE_URL = /^https:\/\/github\.com\/(?:organizations\/[A-Za-z0-9-]{1,39}\/)?settings\/installations\/[0-9]{1,20}$/

type Installation = { id?: unknown; account?: { login?: unknown; type?: unknown } }

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

export const githubConnectTarget = async (env: Env, http: Http, repo: string): Promise<GithubConnectTarget> => {
  const owner = repo.split("/")[0]!
  try {
    const inst = await ownerInstallation(env, http, owner)
    if (!inst) return { kind: "install", ...(await ownerId(http, owner).then((id) => (id ? { target_id: id } : {}))) }
    const id = Number(inst.id)
    const configure_url = Number.isSafeInteger(id) ? configurePage(id, inst, owner) : undefined
    return configure_url ? { kind: "installed", installation: id, configure_url } : { kind: "install" }
  } catch {
    return { kind: "install" }
  }
}

/** The URL Connect answers for a target: never a permission beyond what the App already asks for. */
export const githubConnectUrl = async (env: Env, target: GithubConnectTarget, state: string, redirectUri: string): Promise<string> => {
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

export const createConfigurePageTable = (sql: SqlStorage) =>
  sql.exec(`CREATE TABLE IF NOT EXISTS github_configure_pages (installation INTEGER PRIMARY KEY, login TEXT NOT NULL, url TEXT NOT NULL, checked_at INTEGER NOT NULL)`)

/** What GitHub says about a linked installation: its configure page (null when not known), and whether it is gone (404). */
export type InstallationPage = { readonly url: string | null; readonly gone: boolean }

/** Installation `installation`'s page; `fresh` skips the cache (a reinstall's check of the installation it replaces). */
export const installationPage = async (sql: SqlStorage, env: Env, http: Http, installation: number, login: string, now: number, fresh = false): Promise<InstallationPage> => {
  const row = fresh ? undefined : sql.exec<{ login: string; url: string; checked_at: number }>(`SELECT login, url, checked_at FROM github_configure_pages WHERE installation = ?`, installation).toArray()[0]
  if (row && row.login === login.toLowerCase() && now - Number(row.checked_at) < (row.url ? CONFIGURE_PAGE_TTL_MS : CONFIGURE_MISS_TTL_MS))
    return { url: row.url && GITHUB_CONFIGURE_URL.test(row.url) ? row.url : null, gone: false }
  let url: string | undefined
  try {
    const res = await http(new Request(`${GH_API}/app/installations/${installation}`, { headers: ghHeaders(await appJwt(env)), signal: AbortSignal.timeout(CONFIGURE_LOOKUP_TIMEOUT_MS) }))
    if (res.status === 404) {
      sql.exec(`DELETE FROM github_configure_pages WHERE installation = ?`, installation)
      return { url: null, gone: true }
    }
    url = res.ok ? configurePage(installation, (await res.json()) as Installation, login) : undefined
  } catch {
    url = undefined
  }
  sql.exec(`INSERT OR REPLACE INTO github_configure_pages (installation, login, url, checked_at) VALUES (?, ?, ?, ?)`, installation, login.toLowerCase(), url ?? "", now)
  return { url: url ?? null, gone: false }
}

export const installationConfigureUrl = async (sql: SqlStorage, env: Env, http: Http, installation: number, login: string, now: number): Promise<string | null> =>
  (await installationPage(sql, env, http, installation, login, now)).url
