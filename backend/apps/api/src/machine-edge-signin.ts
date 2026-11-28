import { WorkerEntrypoint } from "cloudflare:workers"
import { mintAccessToken } from "./auth.ts"
import { BASE_SPACE, spacedEnv } from "./build-space.ts"
import { edgeGithubToken, type EdgeGithubTokenReply, type EdgeGithubTokenRequest } from "./integrations/github-token-route.ts"
import type { Env, RawEnv } from "./env.ts"
import { signInRules, ssoGate, versionRefusal } from "./policy-gate.ts"
import type { RedeemResult } from "./user-do.ts"

/**
 * What cmux-platform's POST /v1/cloud/machine-identity/token sends once it has verified the edge header Freestyle
 * injects for `machine` (EdgeCaller.ts): the user, install and grant come from the machine's own CloudDO record,
 * never from the guest's request. `client_version` is the guest's x-cmux-client-version, checked as /token checks it.
 */
export interface MachineEdgeSigninRequest {
  readonly team: string
  readonly machine: string
  readonly user: string
  readonly install: string
  readonly grant: string
  readonly client_version?: string
}

export type MachineEdgeSigninReply =
  | { ok: true; value: { access_token: string; token_type: "Bearer"; expires_at: number; user: string; team: string; install: string; grant: string } }
  | { ok: false; status: number; code: string; message: string }

const ID = /^[A-Za-z0-9_.:-]{1,128}$/
const TEAM = /^team_[0-9a-f]{20}$/
const fail = (status: number, code: string, message: string): MachineEdgeSigninReply => ({ ok: false, status, code, message })

/**
 * A VM install's bearer without its install key (T17 key_off_machine): the same token /v1/auth/token mints for a
 * `vm` install, never with the `edge` claim, so it can't mint GitHub tokens on an edge machine
 * (github-token-route.ts). The install must still be live, bound to this team and machine, under a live vm-self grant,
 * and the team's SSO and minimum-version rules apply as at /token.
 */
export const machineEdgeSignin = async (env: Env, input: MachineEdgeSigninRequest): Promise<MachineEdgeSigninReply> => {
  if (!input || !TEAM.test(input.team ?? "") || ![input.machine, input.user, input.install, input.grant].every((v) => typeof v === "string" && ID.test(v))) {
    return fail(400, "request.invalid", "invalid machine sign-in")
  }
  const r: RedeemResult | null = await env.USER_DO.get(env.USER_DO.idFromName(input.user))
    .edgeRedeem(input.user, input.install, input.grant, input.team, input.machine).catch(() => null)
  if (!r) return fail(503, "owner.unreachable", "the machine's install could not be checked; retry")
  if (!r.ok) return fail(403, r.code, r.message)
  const rules = await signInRules(env, r.team, r.user).catch(() => null)
  const gate = await ssoGate(env, { identity: r.install, kind: "install", user: r.user, team: r.team, ...(r.sso_team ? { sso_team: r.sso_team } : {}), ...(r.email_domain ? { email_domain: r.email_domain } : {}) }).catch(() => null)
  if (!rules || !gate) return fail(503, "owner.unreachable", "the team's sign-in rules could not be read; retry")
  const refusal = gate.refusal ?? versionRefusal(input.client_version ?? null, rules)
  if (refusal) return fail(403, refusal.code, refusal.message)
  const { edge: _never, ...claims } = r
  const { token, expires_at } = await mintAccessToken(env, { ...claims, vm: true })
  return { ok: true, value: { access_token: token, token_type: "Bearer", expires_at, user: r.user, team: r.team, install: r.install, grant: r.grant } }
}

/** Account-local named service binding (cmux-platform's CMUX_MACHINE_EDGE_SIGNIN), never an HTTP route. */
export class MachineEdgeSignin extends WorkerEntrypoint<RawEnv> {
  async signIn(input: MachineEdgeSigninRequest): Promise<MachineEdgeSigninReply> {
    // A Cloud machine belongs to the base build space: a service-binding call carries none.
    return machineEdgeSignin(spacedEnv(this.env, BASE_SPACE), input)
  }

  /**
   * A repository token for an edge machine's git or GitHub API call, from cmux-platform's egress when it holds no
   * install token signer (github-token-route.ts edgeGithubToken: every gate of the edge path, and the edge must carry
   * the machine). Reachable only over this account-local binding.
   */
  async githubToken(input: EdgeGithubTokenRequest): Promise<EdgeGithubTokenReply> {
    return edgeGithubToken(spacedEnv(this.env, BASE_SPACE), input)
  }
}
