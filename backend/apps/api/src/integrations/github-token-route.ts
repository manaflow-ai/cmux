import type { Principal } from "@cmux/ownership"
import { GitHubMachineTokenRequest, GitHubTokenRequest, GitHubTokenRevokeRequest, TeamId } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { authenticate, mintAccessToken } from "../auth.ts"
import { roleHas } from "../domains/team-roles.ts"
import { personalTeamIdFor } from "../domains/user.ts"
import type { Env } from "../env.ts"
import { ssoGate } from "../policy-gate.ts"
import { principalForOwner, selectTeam } from "../team-select.ts"
import { ownConnectionsMayAnswer, type TokenAsk, type TokenReply } from "./github-tokens.ts"
import { platformRead } from "../platform-api.ts"
import { githubNext } from "./github-next.ts"

/**
 * The GitHub token routes (gh-app-product contract; the work is in github-tokens.ts): POST /token
 * {team, repo, permissions, label?}, POST /token/revoke {team, install? | machine?}, GET /status?team=,
 * GET /repos?team=&query?&cursor? -> {repos: [{full_name, private, default_branch}], truncated, cursor}. /status's
 * connection carries `configure_url`, the installation's GitHub page for adding repositories, or null. Callers:
 * a `vm` install for its own live machine (vmGate's checks: cmux-platform's POST /v1/read cloud.vm.self.get as that install), a
 * `daemon`, `cli` or `mac` install, or a member's session; chief tokens (`agent`), team VMs, phone
 * and web installs are refused. Errors are `{error: {code, message, configure_url?, reason?}}` (configure_url only on a
 * policy.denied for a repository the owner's installation lacks; reason, github-tokens.ts DenyReason, on a
 * policy.denied about the repository or its access) and never carry a token.
 */
export const GITHUB_TOKEN_PATH = /^\/v1\/integrations\/github\/(token|machine-token|token\/revoke|status|repos)$/

const TOKEN_INSTALL_KINDS: ReadonlySet<string> = new Set(["vm", "daemon", "cli", "mac"])
const NO_STORE = { "cache-control": "no-store" }
/** Upstream pages (100 repositories each) one repository listing walks, and the matches that end it early. */
const REPO_PAGES_PER_ANSWER = 10
const REPOS_PER_ANSWER = 100

type Fail = { status: number; code: string; message: string; retry_after?: number; configure_url?: string; reason?: string }
// `configure_url` and a policy.denied's `reason` (github-tokens.ts DenyReason) ride in `error`, where the machine's
// git and gh read them (cmux-host github.rs reply_for).
// `next` (github-next.ts): the one line that says what to do, and `next_action`, the cmux action that does it.
const failed = (f: Fail) => Response.json({ error: { code: f.code, message: f.message, ...(f.configure_url === undefined ? {} : { configure_url: f.configure_url }), ...(f.reason === undefined ? {} : { reason: f.reason }), ...githubNext(f.code, f.reason) }, ...(f.retry_after === undefined ? {} : { retry_after: f.retry_after }) }, { status: f.status, headers: f.retry_after === undefined ? NO_STORE : { ...NO_STORE, "retry-after": String(f.retry_after) } })
const no = (status: number, code: string, message: string): Fail => ({ status, code, message })
const unreachable = (what: string) => no(503, "integration.unavailable", `${what} could not be checked; retry`)

const connections = (env: Env, team: string) => env.CONNECTION_DO.get(env.CONNECTION_DO.idFromName(team))

/** At most this many of the person's other teams are asked for their own GitHub connections (cmux#55104). */
const OWN_TEAMS_MAX = 20
const TEAM_ID = /^team_[0-9a-f]{20}$/

/**
 * The person's other teams, where their own GitHub connections are asked when `who.team` has none on the repository's
 * owner (cmux#55104, github-tokens.ts ownConnectionsUnder): a person links GitHub in whichever team is active then
 * (their personal team, or any Stack team), and their Cloud machines run in another. The personal team first, then
 * each shared team of the UserDO index that TeamDO confirms now (the same check selectTeam makes), never `who.team`.
 * An index or TeamDO that does not answer leaves its teams out: the team's own answer stands for them.
 */
const ownTeams = async (env: Env, who: { p: Principal; team: string }): Promise<ReadonlyArray<string>> => {
  const user = who.p.user
  if (!user) return []
  const personal = personalTeamIdFor(user)
  const indexed = await env.USER_DO.get(env.USER_DO.idFromName(user)).homeTeamsOf(user).catch(() => [] as Array<{ team: string }>)
  const shared = [...new Set(indexed.map((e) => e.team))].filter((t) => t !== personal && t !== who.team && TEAM_ID.test(t)).slice(0, OWN_TEAMS_MAX)
  const confirmed = await Promise.all(shared.map((t) => env.TEAM_DO.get(env.TEAM_DO.idFromName(t)).membership(t, user).then((m) => (m ? t : null), () => null)))
  return [...(personal === who.team ? [] : [personal]), ...confirmed.filter((t): t is string => t !== null)]
}

/** The asking team's policy (what a mint from the person's own connections elsewhere may do there); null when it could not be read. */
const teamPolicy = (env: Env, team: string) => connections(env, team).githubPolicy(team).catch(() => null)

/**
 * Where the machine-only seam (POST /machine-token) answers: every deployed environment, so Cloud
 * environment builds and machines mint scoped installation tokens in production too (on by default).
 * The caller must still be a live `vm` install of its own machine under the SSO gate and team policy.
 */
export const MACHINE_TOKEN_ENVIRONMENTS: ReadonlySet<string> = new Set(["development", "staging", "production"])

/** The caller, in `team` (a vm install: its machine's team), with grant classes, or why not. */
const caller = async (request: Request, env: Env, team: string | undefined): Promise<{ p: Principal; team: string; machine?: string; edgeOnly?: true; platformEdge?: true } | Fail> => {
  const authorization = request.headers.get("authorization") ?? ""
  const token = await authenticate(env, /^Bearer (.+)$/.exec(authorization)?.[1])
  if (!token?.user || !token.team) return no(401, "auth.required", "a cmux bearer token is required")
  if (token.agent !== undefined) return no(403, "auth.forbidden", "a chief token cannot get GitHub tokens")
  const vm = token.kind === "install" && token.install_kind === "vm"
  if (vm && team !== undefined && team !== token.team) return no(403, "auth.forbidden", "a VM install acts only in its machine's team")
  if (!vm && team === undefined) return no(400, "request.invalid", "team is required")
  const selected = await selectTeam(env, { ...token, user: token.user, team: token.team }, vm ? undefined : team)
  if (!selected.ok) return selected.code === "owner.unreachable" ? unreachable("team membership") : no(403, "auth.forbidden", selected.message)
  // Team policy (P17-4): the team's SSO rules, as the /v1 API applies them to every request.
  const gate = await ssoGate(env, selected.principal).catch(() => null)
  if (!gate) return unreachable("the sign-in policy")
  if (gate.refusal) return no(403, "auth.forbidden", gate.refusal.message)
  const { stack_session: _session, email_domain: _domain, ...authed } = gate.principal
  const granted = await principalForOwner(env, "cloud:ConnectionDO", authed).catch(() => null)
  if (granted === null) return unreachable("the install's grant")
  if (granted === undefined) return no(401, "auth.required", "install revoked or grant invalid")
  if ("refused" in granted) return no(403, "auth.forbidden", granted.refused)
  const p: Principal = granted
  if (p.kind !== "session" && !(p.kind === "install" && TOKEN_INSTALL_KINDS.has(p.install_kind ?? ""))) return no(403, "auth.forbidden", `a ${p.install_kind ?? p.kind} install cannot get GitHub tokens`)
  if (p.install_kind !== "vm") return { p, team: p.team! }
  // vmGate (cloud-vm.ts): its own bound machine, still naming this install, not deleting or failed.
  // This live-machine ownership check gates the VM's existing vm-self read and write access. The platform reads it
  // as this same install's bearer, so it applies its own vm-self gate too.
  const self = await platformRead(env.PLATFORM, request.url, authorization, "cloud.vm.self.get", { machine: p.bound_machine ?? "" })
  // An edge machine (cmux-platform PlatformEdge carries it: its git reaches GitHub through platform.cmux.internal)
  // says so on this same read; then only the platform egress's own bearer (claim `edge`) mints, never the guest's.
  const platformEdge = self.ok && (self.value as { platform_edge?: unknown } | null)?.platform_edge === true
  const edgeOnly = platformEdge && p.edge !== true
  return self.ok ? { p, team: p.team!, machine: p.bound_machine!, ...(edgeOnly ? { edgeOnly: true as const } : {}), ...(platformEdge ? { platformEdge: true as const } : {}) } : self.retryable ? unreachable("the VM's machine") : no(403, "auth.forbidden", "a VM install speaks only for its own live machine")
}

const decode = <A>(schema: Schema.Codec<A, unknown>, body: unknown): A | Fail => {
  const exit = Schema.decodeUnknownExit(schema)(body, { onExcessProperty: "error" })
  return Exit.isSuccess(exit) ? exit.value : no(400, "request.invalid", `invalid request: ${String(exit.cause).slice(0, 300)}`)
}
const isFail = (x: unknown): x is Fail => typeof x === "object" && x !== null && "status" in x && "code" in x

/** Whether `p` administers `team` (its personal team, or an owner or admin in TeamDO). */
const teamAdmin = async (env: Env, p: Principal, team: string): Promise<boolean | null> => {
  if (team === personalTeamIdFor(p.user!)) return true
  const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team))
  return stub.memberRole(team, p.user!).then((role) => roleHas(role ?? undefined, "team.manage"), () => null)
}

/** How a request reached the route: `edgeService` only from edgeGithubToken (the platform's named entrypoint), never HTTP. */
type RouteCall = { readonly edgeService?: true }

export const handleGithubToken = async (request: Request, env: Env, sub: string, call: RouteCall = {}): Promise<Response> => {
  // The machine-only seam answers in MACHINE_TOKEN_ENVIRONMENTS (not the test runner's own `test`). Repository
  // enumeration answers in every environment: a signed-in person (a session or their own install), and a
  // `vm` install for its own team under exactly the gate POST /token applies to it (caller: its machine's
  // team only, the SSO gate, a live grant, vmGate's own live machine). The listing is no wider than the
  // tokens that VM could mint: githubRepos keeps only the connections it may use and the repositories
  // their scope and the team's allowlist cover (githubRepoAllowed, as authorize's githubCovers).
  if (sub === "machine-token" && !MACHINE_TOKEN_ENVIRONMENTS.has(env.ENVIRONMENT)) return new Response("not found", { status: 404 })
  if (sub === "repos") {
    if (request.method !== "GET") return failed(no(405, "request.invalid", "GET"))
    const url = new URL(request.url)
    const raw = url.searchParams.get("team") ?? undefined
    const team = raw === undefined ? undefined : decode(TeamId as unknown as Schema.Codec<string, unknown>, raw)
    if (isFail(team)) return failed(team)
    const asked = url.searchParams.get("query")
    if (asked !== null && (asked.length > 256 || /\p{Cc}/u.test(asked))) return failed(no(400, "request.invalid", "query is at most 256 characters of text"))
    const who = await caller(request, env, team)
    if (isFail(who)) return failed(who)
    // One answer walks a few upstream pages, so a filter finds a repository past the first hundred;
    // `truncated` says more remain, and `cursor` continues from there.
    const repos: Array<{ full_name: string; private: boolean; default_branch: string | null }> = []
    let cursor = url.searchParams.get("cursor")
    // The team's connections, else (none this person may use) their own in another of their teams, as the token route.
    let list = (query: { query?: string; cursor?: string }) => connections(env, who.team).githubRepos(who.team, who.p, query)
    for (let page = 0; page < REPO_PAGES_PER_ANSWER && repos.length < REPOS_PER_ANSWER; page++) {
      const query = { ...(asked === null ? {} : { query: asked }), ...(cursor === null ? {} : { cursor }) }
      let listed = await list(query).catch(() => null)
      if (page === 0 && listed !== null && !listed.ok && listed.code === "integration.not_found") {
        const teams = await ownTeams(env, who)
        const policy = teams.length === 0 ? undefined : await teamPolicy(env, who.team)
        if (policy === null) return failed(unreachable("the team's GitHub policy"))
        for (const other of teams) {
          if (policy === undefined) break
          const own = (query: { query?: string; cursor?: string }) => connections(env, other).githubReposOwn(other, who.p, query, policy)
          const answered = await own(query).catch(() => null)
          // The person has no connection of their own there either: ask the next team; the team's answer stands after the last.
          if (answered !== null && !answered.ok && answered.code === "integration.not_found") continue
          list = own
          listed = answered
          break
        }
      }
      if (listed === null) return failed(unreachable("the team's GitHub repositories"))
      if (!listed.ok) return failed(listed)
      for (const repo of listed.value.repos) repos.push({ full_name: repo.full_name, private: repo.private, default_branch: repo.default_branch ?? null })
      cursor = listed.value.cursor
      if (cursor === null) break
    }
    return Response.json({ repos, truncated: cursor !== null, cursor }, { headers: NO_STORE })
  }
  if (sub === "status") {
    if (request.method !== "GET") return failed(no(405, "request.invalid", "GET"))
    const raw = new URL(request.url).searchParams.get("team") ?? undefined
    const team = raw === undefined ? undefined : decode(TeamId as unknown as Schema.Codec<string, unknown>, raw)
    if (isFail(team)) return failed(team)
    const who = await caller(request, env, team)
    if (isFail(who)) return failed(who)
    const status = await connections(env, who.team).githubStatus(who.team, who.p)
    // No connection in this team: the one the person linked in another of their teams, as the token route mints from it.
    if (status.connection === null && status.configured) {
      const teams = await ownTeams(env, who)
      const policy = teams.length === 0 ? null : await teamPolicy(env, who.team)
      for (const other of policy === null ? [] : teams) {
        const own = await connections(env, other).githubStatusOwn(other, who.p, policy!).catch(() => null)
        if (own?.connection) return Response.json(own, { headers: NO_STORE })
      }
    }
    return Response.json(status, { headers: NO_STORE })
  }
  if (request.method !== "POST") return failed(no(405, "request.invalid", "POST"))
  const json = (await request.json().catch(() => undefined)) as unknown
  if (sub === "token" || sub === "machine-token") {
    const body = sub === "machine-token"
      ? decode(GitHubMachineTokenRequest as unknown as Schema.Codec<typeof GitHubMachineTokenRequest.Type, unknown>, json)
      : decode(GitHubTokenRequest as unknown as Schema.Codec<typeof GitHubTokenRequest.Type, unknown>, json)
    if (isFail(body)) return failed(body)
    if (Object.keys(body.permissions).length === 0) return failed(no(400, "request.invalid", "permissions must name at least one permission"))
    const who = await caller(request, env, body.team)
    if (isFail(who)) return failed(who)
    // No secret through a request the guest can make: on an edge machine its git needs no token (T15).
    if (who.edgeOnly) return failed(no(403, "github.edge_only", "this machine's git reaches GitHub through its platform edge; the machine may not ask for a GitHub token"))
    // The platform's service mint (edgeGithubToken) serves only a machine its edge carries, as that machine's own install.
    if (call.edgeService && (!who.platformEdge || sub !== "token" || who.p.kind !== "install" || who.p.install_kind !== "vm" || who.p.edge !== true)) {
      return failed(no(403, "auth.forbidden", "the platform's edge mint serves only a machine its platform edge carries"))
    }
    if (sub === "machine-token" && (who.p.kind !== "install" || who.p.install_kind !== "vm" || !who.machine)) return failed(no(403, "auth.forbidden", "a machine install is required"))
    if (who.p.kind === "install" && who.p.install_kind !== "vm" && !who.p.grant_classes?.includes("read")) {
      return failed(no(403, "auth.forbidden", "this install's grant does not cover read"))
    }
    // A person's install writes only with mutate-own. On /token a vm install's vm-self grant covers its
    // own machine's git (the existing Cloud machine contract); the machine-token seam stays read-only for it.
    const writes = Object.values(body.permissions).some((access) => access === "write")
    const vmSelf = sub === "token" && who.p.kind === "install" && who.p.install_kind === "vm"
    if (writes && who.p.kind === "install" && !vmSelf && !who.p.grant_classes?.includes("mutate-own")) {
      return failed(no(403, "auth.forbidden", "this install's grant does not cover write access"))
    }
    const ttlSec = sub === "machine-token" ? (body as typeof GitHubMachineTokenRequest.Type).ttlSec : undefined
    const ask: TokenAsk = { repo: body.repo, permissions: body.permissions as Record<string, "read" | "write">, ...(body.connection ? { connection: body.connection } : {}), ...(body.label ? { label: body.label } : {}), ...(ttlSec === undefined ? {} : { ttlSec }), ...(who.machine ? { machine: who.machine } : {}) }
    let r: TokenReply | null = await connections(env, who.team).githubToken(who.team, who.p, ask).catch(() => null)
    // The team has nothing on the repository's owner: the person's own connection, linked in another of their teams,
    // may. Its answer wins when it says more than the team's: a token, a refusal about a connection that covers the
    // owner, or (over "no GitHub connection") "the App is not installed on this owner", which is the person's next step
    // when the only install is on another account (the reporter's: their own account, the repository an organization's).
    if (r !== null && !r.ok && ownConnectionsMayAnswer(r, ask)) {
      const teams = await ownTeams(env, who)
      const policy = teams.length === 0 ? null : await teamPolicy(env, who.team)
      for (const other of policy === null ? [] : teams) {
        const own = await connections(env, other).githubTokenOwn(other, who.p, ask, policy!).catch(() => null)
        if (own === null) continue
        if (own.ok || !ownConnectionsMayAnswer(own, ask)) {
          r = own
          break
        }
        if (!r.ok && r.code === "integration.not_found" && own.code !== "integration.not_found") r = own
      }
    }
    return r === null ? failed(unreachable("the team's GitHub connection")) : r.ok ? Response.json(r.value, { headers: NO_STORE }) : failed(r)
  }
  const body = decode(GitHubTokenRevokeRequest as unknown as Schema.Codec<typeof GitHubTokenRevokeRequest.Type, unknown>, json)
  if (isFail(body)) return failed(body)
  const who = await caller(request, env, body.team)
  if (isFail(who)) return failed(who)
  if (body.machine !== undefined) {
    // A joined machine's tokens (cmux-platform revokes them itself on machine revoke and rotation): a team admin only.
    if (body.install !== undefined) return failed(no(400, "request.invalid", "name an install or a machine, not both"))
    const admin = await teamAdmin(env, who.p, who.team)
    if (admin === null) return failed(unreachable("the team role"))
    if (!admin) return failed(no(403, "auth.forbidden", "revoking a joined machine's tokens needs a team admin"))
    const revoked = await connections(env, who.team).githubRevoke(who.team, { principal: `machine:${body.machine}` }).catch(() => null)
    return revoked === null ? failed(unreachable("the team's GitHub tokens")) : Response.json({ revoked }, { headers: NO_STORE })
  }
  const own = who.p.kind === "install" ? who.p.install : undefined
  if (body.install !== undefined && body.install !== own) {
    const admin = await teamAdmin(env, who.p, who.team)
    if (admin === null) return failed(unreachable("the team role"))
    if (!admin) return failed(no(403, "auth.forbidden", "revoking another install's tokens needs a team admin"))
  }
  const target = body.install ?? own
  const whose = target ? { install: target } : { principal: `session:${who.p.user}` }
  let revoked = await connections(env, who.team).githubRevoke(who.team, whose).catch(() => null)
  // Tokens minted from the person's own connections (cmux#55104) are in the ledger of the team that holds the connection:
  // the caller's own go too.
  if (revoked !== null && (target === undefined || target === own)) {
    let total: number | null = revoked
    for (const other of await ownTeams(env, who)) {
      const more = await connections(env, other).githubRevoke(other, whose).catch(() => null)
      total = more === null || total === null ? null : total + more
    }
    revoked = total
  }
  return revoked === null ? failed(unreachable("the team's GitHub tokens")) : Response.json({ revoked }, { headers: NO_STORE })
}

/**
 * What cmux-platform's git and GitHub API egress send (CloudDO machineRepoToken) when it holds no install token signer
 * (no JWT_PRIVATE_JWK, as in production): the machine's own record, never the guest's request. `creator` is the user
 * whose vm install it is; `sso_team` is the platform's copy, and the install's own record in UserDO is what is used.
 */
export interface EdgeGithubTokenRequest {
  readonly team: string
  readonly machine: string
  readonly install: string
  readonly grant: string
  readonly creator: string
  readonly sso_team?: string | null
  readonly repo: string
  readonly permissions: Record<string, "read" | "write">
}

/** The /token route's answer, as data: its HTTP status and JSON body (a token reply, or `{error}`). */
export type EdgeGithubTokenReply = { readonly status: number; readonly body: unknown; readonly retry_after?: string }

const EDGE_ID = /^[A-Za-z0-9_.:-]{1,128}$/
const EDGE_TEAM = /^team_[0-9a-f]{20}$/
const reply = async (res: Response): Promise<EdgeGithubTokenReply> => {
  const after = res.headers.get("retry-after")
  return { status: res.status, body: (await res.json().catch(() => null)) as unknown, ...(after === null ? {} : { retry_after: after }) }
}

/**
 * The platform edge's GitHub token mint without a platform-held signing key (named entrypoint MachineEdgeSignin
 * githubToken, account-local, never an HTTP route). Every gate of the vmSelf edge path applies, because it is that
 * path: the install must be live, a `vm` install bound to this team and machine under a live vm-self grant (UserDO
 * edgeRedeem, as edge sign-in); its bearer, with the `edge` claim and only in this Worker's memory, then goes through
 * POST /token, so the SSO gate, the install's grant, vmGate's live machine, the team's GitHub policy and allowlist apply
 * unchanged. One more: the platform's own cloud.vm.self.get must say the edge carries this machine, or nothing is
 * minted. The guest's own bearer never gets here and never carries `edge` (machine-edge-signin.ts strips it).
 */
export const edgeGithubToken = async (env: Env, input: EdgeGithubTokenRequest): Promise<EdgeGithubTokenReply> => {
  const refuse = (f: Fail): EdgeGithubTokenReply => ({ status: f.status, body: { error: { code: f.code, message: f.message, ...githubNext(f.code, f.reason) } } })
  if (!input || typeof input !== "object" || !EDGE_TEAM.test(input.team ?? "") || ![input.machine, input.install, input.grant, input.creator].every((v) => typeof v === "string" && EDGE_ID.test(v))) {
    return refuse(no(400, "request.invalid", "invalid edge token request"))
  }
  if (input.sso_team !== undefined && input.sso_team !== null && (typeof input.sso_team !== "string" || !EDGE_ID.test(input.sso_team))) return refuse(no(400, "request.invalid", "invalid edge token request"))
  const r = await env.USER_DO.get(env.USER_DO.idFromName(input.creator)).edgeRedeem(input.creator, input.install, input.grant, input.team, input.machine).catch(() => null)
  if (!r) return refuse(unreachable("the machine's install"))
  if (!r.ok) return refuse(no(403, "auth.forbidden", r.message))
  // The install's own SSO team decides; a platform copy naming another team is refused rather than trusted.
  if (r.sso_team && (input.sso_team ?? null) !== r.sso_team) return refuse(no(403, "auth.forbidden", "the machine's SSO team does not match its install"))
  const { token } = await mintAccessToken(env, { user: r.user, team: r.team, install: r.install, grant: r.grant, ...(r.sso_team ? { sso_team: r.sso_team } : {}), ...(r.email_domain ? { email_domain: r.email_domain } : {}), vm: true, edge: true })
  const request = new Request("https://cmux-api.internal/v1/integrations/github/token", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ team: input.team, repo: input.repo, permissions: input.permissions })
  })
  return reply(await handleGithubToken(request, env, "token", { edgeService: true }))
}
