import type { Principal } from "@cmux/ownership"
import { personalTeamIdFor } from "./domains/user.ts"
import type { Env } from "./env.ts"

/**
 * Session team selection (cx-3bi.43; plans/cmux-next/enterprise.md "shared teams" item 3): a Stack
 * session acts in its personal team unless the request names another team with `x-cmux-team`
 * (HTTP) or the `team.<id>` WebSocket subprotocol. The Worker asks that team's TeamDO on every
 * request whether the user is a member now, never trusting the claim: every owner keyed by the
 * principal's team (TeamVmDO, CloudDO, SchedulerDO...) relies on this check. An install token
 * acts only in the team it was minted for.
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
  if (!requested || requested === p.team) return { ok: true, principal: p }
  if (!TEAM_ID.test(requested)) return { ok: false, code: "auth.forbidden", message: `${TEAM_HEADER} must name a team id` }
  if (p.kind !== "session") return { ok: false, code: "auth.forbidden", message: "an install token acts only in the team it was minted for" }
  let role: string | null
  try {
    const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(requested)) as unknown as { memberRole(entity: string, user: string): Promise<string | null> }
    role = await stub.memberRole(requested, p.user)
  } catch (e) {
    console.error(JSON.stringify({ msg: "team selection unreachable", error: String(e).slice(0, 200) }))
    return { ok: false, code: "owner.unreachable", message: "team membership could not be checked; retry" }
  }
  if (!role) return { ok: false, code: "auth.forbidden", message: "not a member of this team" }
  return { ok: true, principal: { ...p, team: requested } }
}
