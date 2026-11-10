import type { Env } from "../env.ts"
import { appJwt, ghHeaders, installationToken, type Http } from "./providers.ts"

/**
 * Connect's one page for a GitHub repository (design: remote-integrations, "a connect is one inline card, one
 * tap"). Asked with the App's own key, never a person's token, and it only picks which GitHub page to open:
 * linking still needs the person's own OAuth code, which `complete` checks against `/user/installations`.
 *
 * - covered: the App's installation on the repository's owner already includes the repository. GitHub's OAuth
 *   authorize page (skipped by GitHub for an App the person already authorized) brings the code back, and the
 *   signed state names the installation.
 * - configure: the installation leaves the repository out; its settings page on GitHub adds it.
 * - install: no installation on the owner; the install page, preselecting the owner when its id is known.
 *
 * Any failure answers `install` with no target, the page Connect opened before this existed.
 */
export type GithubConnectTarget =
  | { readonly kind: "covered"; readonly installation: number }
  | { readonly kind: "configure"; readonly url: string }
  | { readonly kind: "install"; readonly target_id?: number }

const GH_API = "https://api.github.com"
const seg = encodeURIComponent

type Installation = { id?: unknown; repository_selection?: unknown; account?: { login?: unknown; id?: unknown; type?: unknown } }

const findInstallation = async (env: Env, http: Http, owner: string, name: string): Promise<Installation | undefined> => {
  const headers = ghHeaders(await appJwt(env))
  for (const path of [`/repos/${seg(owner)}/${seg(name)}/installation`, `/orgs/${seg(owner)}/installation`, `/users/${seg(owner)}/installation`]) {
    const res = await http(new Request(`${GH_API}${path}`, { headers }))
    if (res.ok) return (await res.json()) as Installation
    if (res.status !== 404) throw new Error(`GitHub ${path}: ${res.status}`)
  }
  return undefined
}

/** The owner's numeric id for `target_id`: public data, asked without a token; best effort. */
const ownerId = async (http: Http, owner: string): Promise<number | undefined> => {
  const res = await http(new Request(`${GH_API}/users/${seg(owner)}`, { headers: { accept: "application/vnd.github+json", "x-github-api-version": "2022-11-28", "user-agent": "cmux-cloud" } })).catch(() => null)
  if (!res?.ok) return undefined
  const id = ((await res.json().catch(() => ({}))) as { id?: unknown }).id
  return typeof id === "number" && Number.isSafeInteger(id) && id > 0 ? id : undefined
}

export const githubConnectTarget = async (env: Env, http: Http, repo: string): Promise<GithubConnectTarget> => {
  const [owner, name] = repo.split("/") as [string, string]
  try {
    const inst = await findInstallation(env, http, owner, name)
    if (!inst) return { kind: "install", ...(await ownerId(http, owner).then((id) => (id ? { target_id: id } : {}))) }
    const id = Number(inst.id)
    const login = typeof inst.account?.login === "string" ? inst.account.login : ""
    if (!Number.isSafeInteger(id) || id < 1 || login.toLowerCase() !== owner.toLowerCase()) return { kind: "install" }
    if (inst.repository_selection === "all") return { kind: "covered", installation: id }
    // Selected repositories: the installation's own token reads the repository iff the installation includes it.
    const token = await installationToken(env, http, id)
    const res = await http(new Request(`${GH_API}/repos/${seg(owner)}/${seg(name)}`, { headers: ghHeaders(token) }))
    if (res.ok) return { kind: "covered", installation: id }
    if (res.status !== 404) return { kind: "install" }
    const url = inst.account?.type === "Organization"
      ? `https://github.com/organizations/${seg(login)}/settings/installations/${id}`
      : `https://github.com/settings/installations/${id}`
    return { kind: "configure", url }
  } catch {
    return { kind: "install" }
  }
}

/** The URL Connect answers for a target: never a permission beyond what the App already asks for. */
export const githubConnectUrl = (env: Env, target: GithubConnectTarget, state: string, redirectUri: string): string => {
  if (target.kind === "configure") return target.url
  if (target.kind === "covered") {
    const q = new URLSearchParams({ client_id: env.GITHUB_APP_CLIENT_ID!, redirect_uri: redirectUri, state })
    return `https://github.com/login/oauth/authorize?${q}`
  }
  const base = `https://github.com/apps/${env.GITHUB_APP_SLUG}/installations/new`
  return target.target_id ? `${base}/permissions?target_id=${target.target_id}&state=${encodeURIComponent(state)}` : `${base}?state=${encodeURIComponent(state)}`
}
