import type { Env } from "../env.ts"
import { appJwt, ghHeaders, type Http } from "./providers.ts"

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
    const login = typeof inst.account?.login === "string" ? inst.account.login : ""
    if (!Number.isSafeInteger(id) || id < 1 || login.toLowerCase() !== owner.toLowerCase()) return { kind: "install" }
    const configure_url = inst.account?.type === "Organization"
      ? `https://github.com/organizations/${seg(login)}/settings/installations/${id}`
      : `https://github.com/settings/installations/${id}`
    return GITHUB_CONFIGURE_URL.test(configure_url) ? { kind: "installed", installation: id, configure_url } : { kind: "install" }
  } catch {
    return { kind: "install" }
  }
}

/** The URL Connect answers for a target: never a permission beyond what the App already asks for. */
export const githubConnectUrl = (env: Env, target: GithubConnectTarget, state: string, redirectUri: string): string => {
  if (target.kind === "installed") {
    const q = new URLSearchParams({ client_id: env.GITHUB_APP_CLIENT_ID!, redirect_uri: redirectUri, state })
    return `https://github.com/login/oauth/authorize?${q}`
  }
  const base = `https://github.com/apps/${env.GITHUB_APP_SLUG}/installations/new`
  return target.target_id ? `${base}/permissions?target_id=${target.target_id}&state=${encodeURIComponent(state)}` : `${base}?state=${encodeURIComponent(state)}`
}

/**
 * After a completion: the configure page to open when the person's own link leaves the asked repository out.
 * `repos` is what their token reached (null under the installation scope, where nothing more is known here).
 */
export const configureAfterLink = (repos: ReadonlyArray<string> | null | undefined, repo: string | undefined, configureUrl: string | undefined): string | undefined =>
  repo && configureUrl && GITHUB_CONFIGURE_URL.test(configureUrl) && Array.isArray(repos) && !repos.some((r) => r.toLowerCase() === repo.toLowerCase()) ? configureUrl : undefined
