import type { Principal } from "@cmux/ownership"
import { USER_TEAMS_LIST_MAX } from "@cmux/protocol"
import { personalTeamIdFor } from "./domains/user.ts"
import type { Env } from "./env.ts"
import type { ReadResult } from "./owner-do.ts"
import { signInRules, ssoRefusal, withSsoSession } from "./policy-gate.ts"
import { stackHealDeps, stackTeamsOf, syncTeam, type StackHealDeps } from "./stack-team-heal.ts"

const TEAM_ID = /^team_[0-9a-f]{20}$/
type Membership = { role: string; display_name: string; kind: "personal" | "stack" } | null
type UserTeam = { id: string; display_name: string; kind: "personal" | "stack"; role: string; sso_required: boolean }
/** Teams one user.teams.list checks at once (each is a TeamDO membership call, plus its sign-in rules). */
const LIST_CONCURRENCY = 10

const logged = (msg: string, e: unknown) => console.error(JSON.stringify({ msg, error: String(e).slice(0, 200) }))

const membershipOf = async (env: Env, team: string, user: string): Promise<Membership | "unreachable"> => {
  try {
    const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team))
    return await stub.membership(team, user)
  } catch (e) {
    logged("team list membership unreachable", e)
    return "unreachable"
  }
}

/** What user.teams.list reads Stack with (stack-team-heal.ts). */
export type UserTeamsDeps = StackHealDeps

/** What the SSO gate (policy-gate.ts) answers for this session in `team`: true when that team requires its SSO and this session lacks it. */
const ssoRequiredIn = async (env: Env, p: Principal, team: string): Promise<boolean | "unreachable"> => {
  try {
    const rules = await signInRules(env, team, p.user!)
    if (!rules.sso_required) return false
    return ssoRefusal(await withSsoSession(env, { ...p, team }, team), rules, team) !== undefined
  } catch (e) {
    logged("team list sign-in rules unreachable", e)
    return "unreachable"
  }
}

/**
 * user.teams.list (cx-5xew): the teams a session may name with x-cmux-team. Candidates come from
 * the UserDO team index (a hint TeamDO keeps in step, eventually consistent); each shared team is
 * listed only when its TeamDO confirms the membership now, the same check selectTeam makes, so the
 * list never names a team the server would refuse as not a member. A confirmed team that requires
 * an SSO this session lacks is listed with sso_required (the SSO gate would refuse it), never
 * hidden. The personal team is always first (selectTeam lets it through without a lookup). Any
 * TeamDO that does not answer (the personal one too) sets `incomplete`, and its shared team is left
 * out; so is every team past USER_TEAMS_LIST_MAX.
 */
export const listUserTeams = async (env: Env, p: Principal, deps: UserTeamsDeps = stackHealDeps(env)): Promise<ReadResult> => {
  if (p.kind !== "session" || !p.user || p.agent !== undefined) return { ok: false, code: "auth.forbidden", message: "user.teams.list is for a person's session" }
  const user = p.user
  const personal = personalTeamIdFor(user)
  const stub = env.USER_DO.get(env.USER_DO.idFromName(user))
  const indexed = (await stub.homeTeamsOf(user)).filter((e) => e.team !== personal && TEAM_ID.test(e.team)).map((e) => e.team)
  // Stack's own list joins the index, so a team TeamDO never mirrored is synced below and listed.
  const fromStack = await stackTeamsOf(env, user, p.stack_user_id, deps)
  const index = [...new Set([...indexed, ...fromStack.keys()])]
  const candidates = index.slice(0, USER_TEAMS_LIST_MAX)
  let incomplete = index.length > candidates.length
  const own = await membershipOf(env, personal, user)
  if (own === "unreachable") incomplete = true
  // The personal team's SSO rule binds every request already (ssoGate), so it is never the picker's to flag.
  const teams: Array<UserTeam> = [
    own && own !== "unreachable" ? { id: personal, display_name: own.display_name, kind: "personal", role: own.role, sso_required: false } : { id: personal, display_name: "", kind: "personal", role: "owner", sso_required: false }
  ]
  for (let i = 0; i < candidates.length; i += LIST_CONCURRENCY) {
    const batch = candidates.slice(i, i + LIST_CONCURRENCY)
    const answers = await Promise.all(
      batch.map(async (team) => {
        let m = await membershipOf(env, team, user)
        const stackTeam = fromStack.get(team)
        // Stack lists the person in a team TeamDO does not confirm: sync that team from Stack, then ask again.
        if (m === null && stackTeam !== undefined) {
          await syncTeam(env, team, stackTeam, user, deps.now())
          m = await membershipOf(env, team, user)
        }
        return m && m !== "unreachable" ? { m, sso: await ssoRequiredIn(env, p, team) } : { m, sso: false as const }
      })
    )
    batch.forEach((team, j) => {
      const { m, sso } = answers[j]!
      if (m === "unreachable" || sso === "unreachable") incomplete = true
      else if (m) teams.push({ id: team, display_name: m.display_name, kind: m.kind, role: m.role, sso_required: sso })
    })
  }
  return { ok: true, value: { teams, incomplete }, revision: "0" }
}
