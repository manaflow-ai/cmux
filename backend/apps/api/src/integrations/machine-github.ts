import { WorkerEntrypoint } from "cloudflare:workers"
import type { Principal } from "@cmux/ownership"
import { GitHubTokenRequest } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { BASE_SPACE, spacedEnv } from "../build-space.ts"
import { roleHas } from "../domains/team-roles.ts"
import { personalTeamIdFor } from "../domains/user.ts"
import type { Env, RawEnv } from "../env.ts"
import { ssoGate } from "../policy-gate.ts"
import { JOINED_MACHINE_KIND, type TokenFail, type TokenReply } from "./github-tokens.ts"

/**
 * What cmux-platform's POST /v1/machines/github/token sends once it has checked a joined machine's `cmm_` credential
 * live against its join registry: the machine, the team and the person who minted its join token come from that join
 * record, never from the machine's request. `repo`, `permissions` and `label` are the machine's ask.
 */
export interface JoinedMachineTokenRequest {
  readonly machine: string
  readonly team: string
  readonly user: string
  readonly repo: string
  readonly permissions: Readonly<Record<string, "read" | "write">>
  readonly label?: string
}

const ID = /^[A-Za-z0-9_.:-]{1,128}$/
const TEAM = /^team_[0-9a-f]{20}$/
const fail = (status: number, code: string, message: string): TokenFail => ({ ok: false, status, code, message })

/**
 * Joined machines get scoped installation tokens in every environment, on by default (Leo: killer capabilities ship
 * on). The entrypoint is reachable only through cmux-platform's CMUX_MACHINE_GITHUB service binding, which checks
 * the machine's `cmm_` credential first. PLATFORM_MACHINE_GITHUB "off" is the kill switch: it mints and revokes nothing.
 */
export const machineGitHubOn = (env: Pick<Env, "PLATFORM_MACHINE_GITHUB" | "ENVIRONMENT">) => env.PLATFORM_MACHINE_GITHUB !== "off"
const off = () => fail(404, "platform.machine_github_off", "joined machine GitHub tokens are off in this environment")

/** The machine's ask, decoded exactly as POST /v1/integrations/github/token decodes a person's (no team, no connection). */
const ask = (input: JoinedMachineTokenRequest): { repo: string; permissions: Record<string, "read" | "write">; label?: string } | TokenFail => {
  const exit = Schema.decodeUnknownExit(GitHubTokenRequest as unknown as Schema.Codec<typeof GitHubTokenRequest.Type, unknown>)(
    { repo: input.repo, permissions: input.permissions, ...(input.label === undefined ? {} : { label: input.label }) },
    { onExcessProperty: "error" }
  )
  if (!Exit.isSuccess(exit)) return fail(400, "request.invalid", `invalid request: ${String(exit.cause).slice(0, 300)}`)
  const permissions = exit.value.permissions as Record<string, "read" | "write">
  if (Object.keys(permissions).length === 0) return fail(400, "request.invalid", "permissions must name at least one permission")
  return { repo: exit.value.repo, permissions, ...(exit.value.label ? { label: exit.value.label } : {}) }
}

/**
 * A repository token for a joined machine (RFD 0053, cmuxterm-hq#19720): one hour or less, one repository, from the
 * team's GitHub connections the minter may use (`mayUse`: the team's shared ones and the minter's own), under the
 * team's policy. The minter must still be in the team (their personal team, or a role with `team.resources`).
 */
export const joinedMachineToken = async (env: Env, input: JoinedMachineTokenRequest, deps: { readonly sso: typeof ssoGate } = { sso: ssoGate }): Promise<TokenReply> => {
  if (!machineGitHubOn(env)) return off()
  if (!input || !ID.test(input.machine ?? "") || !TEAM.test(input.team ?? "") || !ID.test(input.user ?? "")) return fail(400, "request.invalid", "invalid joined machine")
  const wanted = ask(input)
  if ("ok" in wanted) return wanted
  let team_role: string | undefined = "owner"
  if (input.team !== personalTeamIdFor(input.user)) {
    const role = await env.TEAM_DO.get(env.TEAM_DO.idFromName(input.team)).memberRole(input.team, input.user).catch(() => undefined)
    if (role === undefined) return fail(503, "integration.unavailable", "the team membership could not be checked; retry")
    if (!roleHas(role ?? undefined, "team.resources")) return fail(403, "auth.forbidden", "the person who joined this machine is no longer a member of its team")
    team_role = role ?? undefined
  }
  const principal: Principal = {
    identity: `machine:${input.machine}`,
    kind: "install",
    install_kind: JOINED_MACHINE_KIND,
    user: input.user,
    team: input.team,
    bound_machine: input.machine,
    ...(team_role ? { team_role } : {})
  }
  // Team policy (P17-4), as POST /token's caller applies it. A joined machine has no sign-in session to show and its
  // credential records none, so a team that requires SSO refuses it (fail closed) until the join carries that proof.
  const gate = await deps.sso(env, principal).catch(() => null)
  if (!gate) return fail(503, "integration.unavailable", "the sign-in policy could not be checked; retry")
  if (gate.refusal) {
    return fail(403, gate.refusal.code === "auth.sso_required" ? "auth.sso_required" : "auth.forbidden", gate.refusal.code === "auth.sso_required"
      ? "this team requires sign-in with its SSO, and a joined machine has no SSO sign-in to show; use a signed-in cmux client for GitHub tokens"
      : gate.refusal.message)
  }
  const connections = env.CONNECTION_DO.get(env.CONNECTION_DO.idFromName(input.team))
  return connections.githubToken(input.team, principal, { ...wanted, machine: input.machine }).catch(() => fail(503, "integration.unavailable", "the team's GitHub connection could not be checked; retry"))
}

/** Revokes every live token issued to joined machine `machine` in `team` (ledger key `machine:<id>`): how many. */
export const revokeJoinedMachineTokens = async (env: Env, input: { readonly machine: string; readonly team: string }): Promise<{ ok: true; value: { revoked: number } } | TokenFail> => {
  if (!machineGitHubOn(env)) return off()
  if (!input || !ID.test(input.machine ?? "") || !TEAM.test(input.team ?? "")) return fail(400, "request.invalid", "invalid joined machine")
  const connections = env.CONNECTION_DO.get(env.CONNECTION_DO.idFromName(input.team))
  const revoked = await connections.githubRevoke(input.team, { principal: `machine:${input.machine}` }).catch(() => null)
  return revoked === null ? fail(503, "integration.unavailable", "the team's GitHub tokens could not be revoked; retry") : { ok: true, value: { revoked } }
}

/** Account-local named service binding (cmux-platform's CMUX_MACHINE_GITHUB), never an HTTP route. */
export class MachineGitHub extends WorkerEntrypoint<RawEnv> {
  async joinedMachineToken(input: JoinedMachineTokenRequest): Promise<TokenReply> {
    // A joined machine belongs to nightly and stable's accounts: a service-binding call carries no build space.
    return joinedMachineToken(spacedEnv(this.env, BASE_SPACE), input)
  }

  /** cmux-platform's machine revoke and credential rotation: the machine's GitHub tokens die with its credential. */
  async revokeJoinedMachineTokens(input: { machine: string; team: string }): Promise<{ ok: true; value: { revoked: number } } | TokenFail> {
    return revokeJoinedMachineTokens(spacedEnv(this.env, BASE_SPACE), input)
  }
}
