import type { Principal } from "@cmux/ownership"
import { GitHubMachineTokenRequest, GitHubTokenRequest, GitHubTokenRevokeRequest, TeamId } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { authenticate } from "../auth.ts"
import { roleHas } from "../domains/team-roles.ts"
import { personalTeamIdFor } from "../domains/user.ts"
import type { Env } from "../env.ts"
import { ssoGate } from "../policy-gate.ts"
import { principalForOwner, selectTeam } from "../team-select.ts"
import type { RepoListReply, TokenAsk, TokenReply } from "./github-tokens.ts"

/**
 * The GitHub token routes (gh-app-product contract; the work is in github-tokens.ts): POST /token
 * {team, repo, permissions, label?}, POST /token/revoke {team, install?}, GET /status?team=. Callers:
 * a `vm` install for its own live machine (vmGate's checks, through CloudDO's cloud.vm.self.get), a
 * `daemon`, `cli` or `mac` install, or a member's session; chief tokens (`agent`), team VMs, phone
 * and web installs are refused. Errors are `{error: {code, message}}` and never carry a token.
 */
export const GITHUB_TOKEN_PATH = /^\/v1\/integrations\/github\/(token|machine-token|token\/revoke|status|repos)$/

const TOKEN_INSTALL_KINDS: ReadonlySet<string> = new Set(["vm", "daemon", "cli", "mac"])
const NO_STORE = { "cache-control": "no-store" }

type Fail = { status: number; code: string; message: string; retry_after?: number }
const failed = (f: Fail) => Response.json({ error: { code: f.code, message: f.message }, ...(f.retry_after === undefined ? {} : { retry_after: f.retry_after }) }, { status: f.status, headers: NO_STORE })
const no = (status: number, code: string, message: string): Fail => ({ status, code, message })
const unreachable = (what: string) => no(503, "integration.unavailable", `${what} could not be checked; retry`)

interface ConnectionStub {
  githubToken(entity: string, p: Principal, ask: TokenAsk): Promise<TokenReply>
  githubRevoke(entity: string, who: { principal: string } | { install: string }): Promise<number>
  githubStatus(entity: string, p: Principal): Promise<unknown>
  githubRepos(entity: string, p: Principal, query: { readonly query?: string; readonly cursor?: string }): Promise<RepoListReply>
}
const connections = (env: Env, team: string) => env.CONNECTION_DO.get(env.CONNECTION_DO.idFromName(team)) as unknown as ConnectionStub

/** The caller, in `team` (a vm install: its machine's team), with grant classes, or why not. */
const caller = async (request: Request, env: Env, team: string | undefined): Promise<{ p: Principal; team: string; machine?: string } | Fail> => {
  const token = await authenticate(env, /^Bearer (.+)$/.exec(request.headers.get("authorization") ?? "")?.[1])
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
  // This live-machine ownership check gates the VM's existing vm-self read and write access.
  const cloud = env.CLOUD_DO.get(env.CLOUD_DO.idFromName(p.team!)) as unknown as { readOp(e: string, p: Principal, op: string, params: unknown): Promise<{ ok: boolean }> }
  const self = await cloud.readOp(p.team!, p, "cloud.vm.self.get", { machine: p.bound_machine ?? "" }).catch(() => null)
  return self === null ? unreachable("the VM's machine") : self.ok ? { p, team: p.team!, machine: p.bound_machine! } : no(403, "auth.forbidden", "a VM install speaks only for its own live machine")
}

const decode = <A>(schema: Schema.Codec<A, unknown>, body: unknown): A | Fail => {
  const exit = Schema.decodeUnknownExit(schema)(body, { onExcessProperty: "error" })
  return Exit.isSuccess(exit) ? exit.value : no(400, "request.invalid", `invalid request: ${String(exit.cause).slice(0, 300)}`)
}
const isFail = (x: unknown): x is Fail => typeof x === "object" && x !== null && "status" in x && "code" in x

/** Whether `p` administers `team` (its personal team, or an owner or admin in TeamDO). */
const teamAdmin = async (env: Env, p: Principal, team: string): Promise<boolean | null> => {
  if (team === personalTeamIdFor(p.user!)) return true
  const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team)) as unknown as { memberRole(entity: string, user: string): Promise<string | null> }
  return stub.memberRole(team, p.user!).then((role) => roleHas(role ?? undefined, "team.manage"), () => null)
}

export const handleGithubToken = async (request: Request, env: Env, sub: string): Promise<Response> => {
  // Repository enumeration and the machine-only seam are development surfaces until the hosted
  // connector rollout. Existing token/status/revoke routes retain their normal environments.
  if ((sub === "repos" || sub === "machine-token") && env.ENVIRONMENT !== "development") return new Response("not found", { status: 404 })
  if (sub === "repos") {
    if (request.method !== "GET") return failed(no(405, "request.invalid", "GET"))
    const url = new URL(request.url)
    const raw = url.searchParams.get("team") ?? undefined
    const team = raw === undefined ? undefined : decode(TeamId as unknown as Schema.Codec<string, unknown>, raw)
    if (isFail(team)) return failed(team)
    const who = await caller(request, env, team)
    if (isFail(who)) return failed(who)
    const query = { ...(url.searchParams.get("query") === null ? {} : { query: url.searchParams.get("query")! }), ...(url.searchParams.get("cursor") === null ? {} : { cursor: url.searchParams.get("cursor")! }) }
    const listed = await connections(env, who.team).githubRepos(who.team, who.p, query).catch(() => null)
    return listed === null ? failed(unreachable("the team's GitHub repositories")) : listed.ok ? Response.json(listed.value, { headers: NO_STORE }) : failed(listed)
  }
  if (sub === "status") {
    if (request.method !== "GET") return failed(no(405, "request.invalid", "GET"))
    const raw = new URL(request.url).searchParams.get("team") ?? undefined
    const team = raw === undefined ? undefined : decode(TeamId as unknown as Schema.Codec<string, unknown>, raw)
    if (isFail(team)) return failed(team)
    const who = await caller(request, env, team)
    return isFail(who) ? failed(who) : Response.json(await connections(env, who.team).githubStatus(who.team, who.p), { headers: NO_STORE })
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
    const ask: TokenAsk = { repo: body.repo, permissions: body.permissions as Record<string, "read" | "write">, ...(body.label ? { label: body.label } : {}), ...(ttlSec === undefined ? {} : { ttlSec }), ...(who.machine ? { machine: who.machine } : {}) }
    const r = await connections(env, who.team).githubToken(who.team, who.p, ask).catch(() => null)
    return r === null ? failed(unreachable("the team's GitHub connection")) : r.ok ? Response.json(r.value, { headers: NO_STORE }) : failed(r)
  }
  const body = decode(GitHubTokenRevokeRequest as unknown as Schema.Codec<typeof GitHubTokenRevokeRequest.Type, unknown>, json)
  if (isFail(body)) return failed(body)
  const who = await caller(request, env, body.team)
  if (isFail(who)) return failed(who)
  const own = who.p.kind === "install" ? who.p.install : undefined
  if (body.install !== undefined && body.install !== own) {
    const admin = await teamAdmin(env, who.p, who.team)
    if (admin === null) return failed(unreachable("the team role"))
    if (!admin) return failed(no(403, "auth.forbidden", "revoking another install's tokens needs a team admin"))
  }
  const target = body.install ?? own
  const revoked = await connections(env, who.team).githubRevoke(who.team, target ? { install: target } : { principal: `session:${who.p.user}` }).catch(() => null)
  return revoked === null ? failed(unreachable("the team's GitHub tokens")) : Response.json({ revoked }, { headers: NO_STORE })
}
