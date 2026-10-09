import type { Principal } from "@cmux/ownership"
import { USER_TEAMS_LIST_MAX } from "@cmux/protocol"
import { personalTeamIdFor } from "./domains/user.ts"
import { isMachineInstallKind } from "./machine-installs.ts"
import type { Env } from "./env.ts"
import type { ReadResult } from "./owner-do.ts"

/**
 * Session team selection (cx-3bi.43; plans/cmux-next/enterprise.md "shared teams" item 3): a Stack
 * session acts in its personal team unless the request names another team with `x-cmux-team`
 * (HTTP) or the `team.<id>` WebSocket subprotocol. The Worker asks that team's TeamDO on every
 * request whether the user is a member now, never trusting the claim: every owner keyed by the
 * principal's team (TeamVmDO, CloudDO, SchedulerDO...) relies on this check. An install token
 * acts only in the team it was minted for, and that team too is checked unless it is the user's
 * personal team or a machine install's bound team (review P1-1: a token claim never outlives a
 * removal).
 */
export const TEAM_HEADER = "x-cmux-team"
export const TEAM_SUBPROTOCOL_PREFIX = "team."
const TEAM_ID = /^team_[0-9a-f]{20}$/

/** The principal in its own personal team, whatever team the request named (user.ensure creates that team). */
export const personalPrincipal = (p: Principal): Principal => (p.user ? { ...p, team: personalTeamIdFor(p.user) } : p)

/** A principal that names its user and team (what authenticate returns for a valid token). */
export type TeamPrincipal = Principal & { readonly user: string; readonly team: string }

export type TeamSelection =
  | { readonly ok: true; readonly principal: TeamPrincipal }
  | { readonly ok: false; readonly code: "auth.forbidden" | "owner.unreachable"; readonly message: string }

export const selectTeam = async (env: Env, p: TeamPrincipal, requested: string | null | undefined): Promise<TeamSelection> => {
  if (requested && requested !== p.team) {
    if (!TEAM_ID.test(requested)) return { ok: false, code: "auth.forbidden", message: `${TEAM_HEADER} must name a team id` }
    if (p.kind !== "session") return { ok: false, code: "auth.forbidden", message: "an install token acts only in the team it was minted for" }
  }
  const team = requested || p.team
  // The personal team needs no lookup (user.ensure made it); a machine install's team is its bound team (minted by UserDO).
  if (team === personalTeamIdFor(p.user) || (p.kind === "install" && isMachineInstallKind(p.install_kind))) return { ok: true, principal: { ...p, team } }
  let role: string | null
  try {
    const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team)) as unknown as { memberRole(entity: string, user: string): Promise<string | null> }
    role = await stub.memberRole(team, p.user)
  } catch (e) {
    console.error(JSON.stringify({ msg: "team selection unreachable", error: String(e).slice(0, 200) }))
    return { ok: false, code: "owner.unreachable", message: "team membership could not be checked; retry" }
  }
  if (!role) return { ok: false, code: "auth.forbidden", message: "not a member of this team" }
  return { ok: true, principal: { ...p, team } }
}

type Membership = { role: string; display_name: string; kind: "personal" | "stack" } | null
type UserTeam = { id: string; display_name: string; kind: "personal" | "stack"; role: string }
/** TeamDO calls one user.teams.list runs at once. */
const LIST_CONCURRENCY = 10

const membershipOf = async (env: Env, team: string, user: string): Promise<Membership | "unreachable"> => {
  try {
    const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team)) as unknown as { membership(entity: string, user: string): Promise<Membership> }
    return await stub.membership(team, user)
  } catch (e) {
    console.error(JSON.stringify({ msg: "team list membership unreachable", error: String(e).slice(0, 200) }))
    return "unreachable"
  }
}

/**
 * user.teams.list (cx-5xew): the teams a session may name with x-cmux-team. Candidates come from
 * the UserDO team index (a hint TeamDO keeps in step, eventually consistent); each shared team is
 * listed only when its TeamDO confirms the membership now, the same check selectTeam makes, so the
 * list never names a team the server would refuse. The personal team is always first (selectTeam
 * lets it through without a lookup). A TeamDO that does not answer leaves its team out and sets
 * `incomplete`; so does an index over USER_TEAMS_LIST_MAX shared teams.
 */
export const listUserTeams = async (env: Env, p: Principal): Promise<ReadResult> => {
  if (p.kind !== "session" || !p.user || p.agent !== undefined) return { ok: false, code: "auth.forbidden", message: "user.teams.list is for a person's session" }
  const user = p.user
  const personal = personalTeamIdFor(user)
  const stub = env.USER_DO.get(env.USER_DO.idFromName(user)) as unknown as { homeTeamsOf(entity: string): Promise<Array<{ team: string; kind: string }>> }
  const index = (await stub.homeTeamsOf(user)).filter((e) => e.team !== personal && TEAM_ID.test(e.team))
  const candidates = index.slice(0, USER_TEAMS_LIST_MAX).map((e) => e.team)
  let incomplete = index.length > candidates.length
  const own = await membershipOf(env, personal, user)
  const teams: Array<UserTeam> = [
    own && own !== "unreachable" ? { id: personal, display_name: own.display_name, kind: "personal", role: own.role } : { id: personal, display_name: "", kind: "personal", role: "owner" }
  ]
  for (let i = 0; i < candidates.length; i += LIST_CONCURRENCY) {
    const batch = candidates.slice(i, i + LIST_CONCURRENCY)
    const answers = await Promise.all(batch.map((team) => membershipOf(env, team, user)))
    batch.forEach((team, j) => {
      const m = answers[j]
      if (m === "unreachable") incomplete = true
      else if (m) teams.push({ id: team, display_name: m.display_name, kind: m.kind, role: m.role })
    })
  }
  return { ok: true, value: { teams, incomplete }, revision: "0" }
}
