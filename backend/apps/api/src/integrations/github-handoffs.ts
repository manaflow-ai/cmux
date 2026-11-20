import type { Connection } from "@cmux/protocol"
import { githubInstallationOf, policyOf, providerAllowed, type ConnectionsState, type GithubInstallRequest } from "../domains/connections.ts"
import type { Env } from "../env.ts"
import type { ProviderEvent } from "./external.ts"
import { github, GITHUB_REQUEST_SENT, githubScopesOf, githubUserOf, githubUserToken, ghHeaders, installationToken, mintedToken, ProviderError, requestInstallationToken, revokeInstallationToken, type Credential, type Http } from "./providers.ts"

/**
 * GitHub App changes that happen on GitHub after Connect, where the person who connected is not in the loop
 * (ConnectionDO calls these with a HandoffHost):
 *
 * - A repository added to the installation later (`installation_repositories.added`, githubReposAdded). Under
 *   the default `linking_user_repos` scope a connection may act only on repositories the person who linked could
 *   reach, and their GitHub sign-in is not kept. The App can still prove it: the webhook's `sender` is that person
 *   (adding a repository to an installation takes admin access to it), or GitHub answers that the person is a
 *   collaborator on it (`GET /repos/{repo}/collaborators/{login}`: 204 yes, 404 no, asked with an installation
 *   token narrowed to those repositories and `metadata: read`). Anything else stays out until the person relinks.
 * - A member's install that GitHub sent to the organization's owners (`setup_action=request`, githubInstallRequest),
 *   and an owner's approval of it (`installation.created` naming the `requester`, githubRequestApproved).
 *
 * The person is named by their numeric GitHub id (a login can be renamed and then taken by someone else); the
 * current login is read from the id when a check needs one.
 */

const GH_API = "https://api.github.com"

/** Collaborator checks per webhook; a larger change stays out (the person relinks, which reads their own list). */
export const MAX_REACH_CHECKS = 100

/** Checks at once, so 100 of them fit in GitHub's 10 s webhook window. */
const PARALLEL = 10

const REPO = /^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/

export type GithubUser = { readonly id: number; readonly login: string }

/** What a request answers when the approval will link by itself (the requester's GitHub user is known). */
export const GITHUB_REQUEST_LINKS = "GitHub sent your request to install the cmux GitHub App to the organization's owners. When an owner approves it, cmux connects it to this team without another Connect"

/** The account index key an owner's approval arrives by (provider-hook.ts): the requester's GitHub user id. */
export const requesterKey = (githubUserId: number) => `github:requester:${githubUserId}`

/** A connection id (`conn_` and 20 hex) chosen before its commit, so an approval's route can be written first. */
export const newConnectionId = () => `conn_${[...crypto.getRandomValues(new Uint8Array(10))].map((b) => b.toString(16).padStart(2, "0")).join("")}`

/** The `full_name`s of a webhook's repository list (`repositories_added`, `repositories`). */
export const repoNames = (list: unknown): Array<string> =>
  Array.isArray(list) ? list.map((r) => (r as { full_name?: unknown } | null)?.full_name).filter((n): n is string => typeof n === "string" && REPO.test(n)) : []

/** A webhook's `sender` or `requester` GitHub user id, or undefined. */
export const userIdOf = (u: unknown): number | undefined => {
  const id = (u as { id?: unknown } | null | undefined)?.id
  return typeof id === "number" && Number.isSafeInteger(id) && id > 0 ? id : undefined
}

export type Reach = { readonly reachable: Array<string>; readonly unknown: Array<string> }

/**
 * Of `repos` (full names in installation `installation`'s account), the ones GitHub user `userId` can reach,
 * and the ones GitHub did not answer for (left out, like the unreachable ones). One narrowed token, revoked after.
 */
export const reachableBy = async (env: Env, http: Http, installation: number, userId: number, repos: ReadonlyArray<string>): Promise<Reach> => {
  const names = [...new Set(repos.filter((r) => REPO.test(r)))]
  if (names.length === 0) return { reachable: [], unknown: [] }
  const checked = names.slice(0, MAX_REACH_CHECKS)
  const over = names.slice(MAX_REACH_CHECKS)
  const res = await requestInstallationToken(env, http, installation, { repositories: checked.map((r) => r.split("/")[1]!), permissions: { metadata: "read" } }).catch(() => null)
  if (!res?.ok) return { reachable: [], unknown: names }
  const { token } = await mintedToken(res)
  try {
    const u = await http(new Request(`${GH_API}/user/${userId}`, { headers: ghHeaders(token) })).catch(() => null)
    const login = u?.ok ? ((await u.json().catch(() => ({}))) as { login?: unknown }).login : undefined
    if (typeof login !== "string" || login.length === 0) return { reachable: [], unknown: names }
    const reachable: Array<string> = []
    const unknown: Array<string> = [...over]
    for (let i = 0; i < checked.length; i += PARALLEL) {
      const batch = checked.slice(i, i + PARALLEL)
      const answers = await Promise.all(
        batch.map((r) => {
          const [owner, name] = r.split("/") as [string, string]
          return http(new Request(`${GH_API}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(name)}/collaborators/${encodeURIComponent(login)}`, { headers: ghHeaders(token) }))
            .then((a) => a.status)
            .catch(() => 0)
        })
      )
      batch.forEach((r, j) => {
        if (answers[j] === 204) reachable.push(r)
        else if (answers[j] !== 404) unknown.push(r)
      })
    }
    return { reachable, unknown }
  } finally {
    await revokeInstallationToken(http, token)
  }
}

/** Every repository of an installation (`repository_selection: all`), up to `max` + 1 so a caller sees "more than max". */
export const installationRepos = async (env: Env, http: Http, installation: number, max: number): Promise<Array<string> | null> => {
  const token = await installationToken(env, http, installation).catch(() => null)
  if (!token) return null
  const out: Array<string> = []
  for (let page = 1; out.length <= max; page++) {
    const r = await http(new Request(`${GH_API}/installation/repositories?per_page=100&page=${page}`, { headers: ghHeaders(token) })).catch(() => null)
    if (!r?.ok) return null
    const batch = repoNames(((await r.json().catch(() => ({}))) as { repositories?: unknown }).repositories)
    out.push(...batch)
    if (batch.length < 100) break
  }
  return out
}

/** What these handlers need from the team's ConnectionDO. */
export interface HandoffHost {
  readonly env: Env
  readonly http: Http
  readonly team: string
  readonly state: () => ConnectionsState
  /** A system op; its refusal's message, if refused (logged, never retried). */
  readonly submit: (op: string, params: unknown, key: string) => { readonly rejected?: string; readonly value?: unknown }
  readonly index: (key: string) => { add(team: string, connection: string): Promise<void>; remove(team: string, connection: string): Promise<void> }
  readonly seal: (c: Connection, credential: Credential) => Promise<unknown>
  readonly dropCredential: (connection: string) => void
  readonly linker: (connection: string) => GithubUser | undefined
  readonly setLinker: (connection: string, u: GithubUser) => void
  readonly scheduleAlarm: () => void
}

/** The requester index entry an approval would arrive by, once its request is gone (linked, replaced, expired). */
export const dropRequesterLink = async (h: HandoffHost, r: GithubInstallRequest) => {
  if (!r.github_user) return
  await h.index(requesterKey(r.github_user.id)).remove(h.team, r.id).catch((e) => console.error(JSON.stringify({ msg: "requester index remove failed", request: r.id, error: String(e) })))
}

/**
 * `setup_action=request` (no installation yet): an organization member's install went to the owners. The pending
 * connect ends and the team records the request. When the callback carries a code, its exchange proves the
 * requester's GitHub user, and the owner's approval links the installation to this team by itself; without one,
 * the person connects again after. The completion still answers a refusal saying what happens next: the app reads
 * it as a pending approval (cmux#47328).
 */
export const githubInstallRequest = async (h: HandoffHost, c: Connection, code: string | undefined): Promise<never> => {
  const user = code ? await githubUserToken(h.env, h.http, code).then((t) => githubUserOf(h.http, t)).catch(() => null) : null
  const request = newConnectionId()
  // Route the approval first (idempotent), then commit; a refused commit undoes the route.
  if (user) await h.index(requesterKey(user.id)).add(c.owner, request)
  const res = h.submit("connection.github.requested", { connection: c.id, request, github_user: user }, `gh-requested:${c.id}`)
  if (res.rejected !== undefined) {
    if (user) await h.index(requesterKey(user.id)).remove(c.owner, request).catch(() => undefined)
    throw new ProviderError("integration.state_invalid", res.rejected)
  }
  for (const r of (res.value as { dropped?: Array<GithubInstallRequest> } | undefined)?.dropped ?? []) await dropRequesterLink(h, r)
  h.scheduleAlarm()
  throw new ProviderError("integration.state_invalid", user && !policyOf(h.state()).github.require_org_admin ? GITHUB_REQUEST_LINKS : GITHUB_REQUEST_SENT)
}

/**
 * An owner approved `request` (`installation.created`, whose signed `requester` is the GitHub user recorded with
 * it). The installation becomes the team's connection as if the person had connected it: the requester must
 * match; under the default `linking_user_repos` scope the connection lists only the installation's repositories
 * the requester is proven to reach (reachableBy). A policy that needs an organization admin to link, or a list
 * too large to check, leaves it to the person: status says the owner approved, and Connect GitHub finishes it.
 */
export const githubRequestApproved = async (h: HandoffHost, request: string, event: ProviderEvent): Promise<"linked" | "seen" | "dropped"> => {
  const r = h.state().github_requests?.[request]
  const p = (event.payload ?? {}) as { installation?: { id?: unknown; account?: { login?: unknown; html_url?: unknown }; permissions?: unknown; repository_selection?: unknown }; repositories?: unknown; requester?: unknown }
  const installation = p.installation?.id
  const login = p.installation?.account?.login
  if (!r?.github_user || userIdOf(p.requester) !== r.github_user.id || typeof installation !== "number" || !Number.isSafeInteger(installation) || installation <= 0 || typeof login !== "string" || login.length === 0) return "dropped"
  const policy = policyOf(h.state())
  const seen = (reason: string) => (h.submit("connection.github.request_seen", { request, account: login.slice(0, 100), reason }, `gh-request-seen:${request}:${event.delivery_id}`), "seen" as const)
  const url = p.installation?.account?.html_url
  const account = { key: `github:installation:${installation}`, name: login, ...(typeof url === "string" ? { url } : {}) }
  const perms = p.installation?.permissions
  const scopes_granted = perms && typeof perms === "object" ? githubScopesOf(perms as Record<string, unknown>) : []
  // The team connected this installation meanwhile: that connection serves the request (no second credential or route).
  if (Object.values(h.state().connections).some((x) => x.account?.key === account.key && x.status !== "revoked" && x.status !== "expired")) {
    const served = h.submit("connection.github.approved", { request, account, scopes_granted, resources: { repos: [] } }, `gh-approved:${request}`)
    if (served.rejected === undefined) await dropRequesterLink(h, r)
    return served.rejected === undefined ? "linked" : "dropped"
  }
  if (!providerAllowed(policy, "github") || !github.configured(h.env) || !h.env.INTEGRATIONS_KEK) return seen("GitHub is not available to this team")
  if (policy.github.require_org_admin) return seen(`the team policy requires a ${login} organization admin to link GitHub`)
  let repos: Array<string> | null = null
  if (policy.github.scope === "linking_user_repos") {
    const listed = p.installation?.repository_selection === "all" ? await installationRepos(h.env, h.http, installation, MAX_REACH_CHECKS) : repoNames(p.repositories)
    if (listed === null || listed.length > MAX_REACH_CHECKS) return seen(`cmux could not check which ${login} repositories you can reach`)
    repos = (await reachableBy(h.env, h.http, installation, r.github_user.id, listed)).reachable
    if (repos.length === 0) return seen(`the installation on ${login} includes no repository you can reach`)
  }
  const params = { request, account, scopes_granted, resources: { repos } }
  const now = Date.now()
  const shape: Connection = { id: request, owner: h.team, created_by: r.requested_by, provider: "github", account, scopes_requested: [...r.scopes_requested], scopes_granted: [], status: "pending", sharing: r.sharing, created_at: now, updated_at: now }
  // As ConnectionDO.complete: route webhooks, seal, then commit; a refused commit undoes both.
  await h.index(account.key).add(h.team, request)
  try {
    await h.seal(shape, { kind: "github_installation", installation_id: installation })
  } catch (e) {
    await h.index(account.key).remove(h.team, request).catch(() => undefined)
    throw e
  }
  const res = h.submit("connection.github.approved", params, `gh-approved:${request}`)
  if (res.rejected !== undefined) {
    h.dropCredential(request)
    await h.index(account.key).remove(h.team, request).catch(() => undefined)
    return seen(res.rejected)
  }
  h.setLinker(request, r.github_user)
  await dropRequesterLink(h, r)
  h.scheduleAlarm()
  return "linked"
}

/**
 * `installation_repositories.added` on an active connection with a recorded list (the default `linking_user_repos`
 * scope; under `installation` scope the list is not consulted): the added repositories join when the person who
 * linked is proven to reach them. When that person added them (the signed `sender`), all join; otherwise GitHub is
 * asked per repository (reachableBy). The rest stay out, and a mint for one says to connect GitHub again as
 * someone who can see it. A connection linked before its linker was recorded joins nothing until it is relinked.
 */
export const githubReposAdded = async (h: HandoffHost, c: Connection, event: ProviderEvent): Promise<void> => {
  if (c.status !== "active" || !Array.isArray(c.resources?.repos)) return
  const installation = githubInstallationOf(c)
  const p = (event.payload ?? {}) as { repositories_added?: unknown; sender?: unknown }
  const owner = c.account?.name.toLowerCase()
  const added = repoNames(p.repositories_added).filter((r) => r.split("/")[0]!.toLowerCase() === owner)
  if (installation === undefined || added.length === 0) return
  const linker = h.linker(c.id)
  if (!linker) return void console.warn(JSON.stringify({ msg: "github repositories added; no linker recorded", connection: c.id, added: added.length }))
  const joined = userIdOf(p.sender) === linker.id ? added : (await reachableBy(h.env, h.http, installation, linker.id, added).catch(() => ({ reachable: [], unknown: added }))).reachable
  if (joined.length > 0) h.submit("connection.github.sync", { connection: c.id, repos_added: joined }, `github-sync-added:${c.id}:${event.delivery_id}`)
  if (joined.length < added.length) console.warn(JSON.stringify({ msg: "github repositories added; some left out", connection: c.id, added: added.length, joined: joined.length }))
}
