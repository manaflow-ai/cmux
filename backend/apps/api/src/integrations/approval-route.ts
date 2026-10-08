import type { Principal } from "@cmux/ownership"
import type { Env } from "../env.ts"
import { signInRules, ssoRefusal, withSsoSession } from "../policy-gate.ts"
import type { SignInRules } from "../team-do.ts"

interface FeedStub {
  integrationApprovalTeam(user: string, request: string): Promise<string | null>
}
interface TeamStub {
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<{ ok: boolean }>
}

/** The target team's sign-in rules and SSO session lookup (policy-gate.ts); tests inject them. */
export interface RouteDeps {
  readonly rules: (env: Env, team: string, user: string) => Promise<SignInRules>
  readonly sso: (env: Env, principal: Principal, team: string) => Promise<Principal>
}
const live: RouteDeps = { rules: (env, team, user) => signInRules(env, team, user), sso: withSsoSession }

/**
 * G8 cross-team reads: a session token carries the person's personal team, but an approval from
 * a team's agent waits in that team's ConnectionDO. integration.approval.get goes to the team
 * whose ConnectionDO posted the person's own feed request for `request` (the feed checks the
 * poster scope), only when TeamDO lists the person as a member (its member-only read), and, when
 * that team enforces SSO, only with a session its SSO created (the auth gate checks only the
 * personal and email-domain teams). In every other case the reader stays as it is; the
 * ConnectionDO still requires the row's user.
 */
export const approvalReader = async (env: Env, reader: Principal, params: unknown, deps: RouteDeps = live): Promise<Principal> => {
  const request = (params as { request?: unknown } | null)?.request
  if (reader.kind !== "session" || !reader.user || typeof request !== "string") return reader
  const feed = env.FEED_DO.get(env.FEED_DO.idFromName(reader.user)) as unknown as FeedStub
  const team = await feed.integrationApprovalTeam(reader.user, request)
  if (!team || team === reader.team) return reader
  const asMember: Principal = { ...reader, team }
  const teamDO = env.TEAM_DO.get(env.TEAM_DO.idFromName(team)) as unknown as TeamStub
  const member = await teamDO.readOp(team, asMember, "team.members.list", { limit: 1 })
  if (!member.ok) return reader
  const rules = await deps.rules(env, team, reader.user)
  if (!rules.sso_required) return asMember
  const withSso = await deps.sso(env, asMember, team)
  return ssoRefusal(withSso, rules, team) ? reader : withSso
}
