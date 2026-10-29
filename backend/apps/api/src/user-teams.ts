import type { Principal } from "@cmux/ownership"
import { USER_TEAMS_LIST_MAX } from "@cmux/protocol"
import { personalTeamIdFor, stackTeamIdFor } from "./domains/user.ts"
import type { Env } from "./env.ts"
import type { ReadResult } from "./owner-do.ts"
import { signInRules, ssoRefusal, withSsoSession } from "./policy-gate.ts"
import { stackReadPace, stackServer, type StackServer } from "./stack-server.ts"
import type { StackEvent, StackSyncReply } from "./team-stack-sync.ts"

const TEAM_ID = /^team_[0-9a-f]{20}$/
type Membership = { role: string; display_name: string; kind: "personal" | "stack" } | null
type UserTeam = { id: string; display_name: string; kind: "personal" | "stack"; role: string; sso_required: boolean }
/** Teams one user.teams.list checks at once (each is a TeamDO membership call, plus its sign-in rules). */
const LIST_CONCURRENCY = 10

const logged = (msg: string, e: unknown) => console.error(JSON.stringify({ msg, error: String(e).slice(0, 200) }))

const membershipOf = async (env: Env, team: string, user: string): Promise<Membership | "unreachable"> => {
  try {
    const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team)) as unknown as { membership(entity: string, user: string): Promise<Membership> }
    return await stub.membership(team, user)
  } catch (e) {
    logged("team list membership unreachable", e)
    return "unreachable"
  }
}

/** What user.teams.list reads Stack with: the Worker's server client and the shared pace of Stack reads (tests pass fakes). */
export interface UserTeamsDeps {
  readonly stack: Pick<StackServer, "listUserTeams"> | undefined
  /** One token of the shared Stack read pace (stack-server.ts stackReadPace); false = not now. */
  readonly pace: () => Promise<boolean>
  readonly now: () => number
}
const defaultDeps = (env: Env): UserTeamsDeps => ({ stack: stackServer(env), pace: () => stackReadPace(env), now: () => Date.now() })

/** How often one person's Stack teams are compared with TeamDO. */
const HEAL_WINDOW_MS = 10 * 60_000
/** When each person's Stack teams were last read, per isolate: a soft limit (the shared pace and TeamDO's delivery dedupe bound the rest). */
const healedAt = new Map<string, number>()
const HEALED_MAX = 10_000

/**
 * The person's Stack teams as cmux ids (to their Stack ids), read at most once per HEAL_WINDOW_MS and only
 * with a pace token; empty when not read now. A Stack team whose webhook deliveries never reached TeamDO
 * (one made before the mirror existed, or events Stack never sent) is otherwise never listed: its TeamDO
 * does not know its members (prod 2026-10-29: Home listed no teammates).
 */
const stackTeamsOf = async (env: Env, p: Principal, deps: UserTeamsDeps): Promise<Map<string, string>> => {
  const stackUser = p.stack_user_id
  if (!deps.stack || !stackUser) return new Map()
  const now = deps.now()
  const last = healedAt.get(p.user!)
  if (last !== undefined && now - last < HEAL_WINDOW_MS) return new Map()
  if (!(await deps.pace().catch(() => false))) return new Map()
  if (healedAt.size >= HEALED_MAX) healedAt.clear()
  healedAt.set(p.user!, now)
  try {
    const ids = await deps.stack.listUserTeams(stackUser)
    return new Map(ids.map((id) => [stackTeamIdFor(env.STACK_PROJECT_ID, id), id] as const))
  } catch (e) {
    logged("team list stack teams unreadable", e)
    return new Map()
  }
}

/** A full sync of one Stack team in its TeamDO (team-stack-sync.ts), as a team.updated delivery would run it; one per person per window. */
const syncTeam = async (env: Env, team: string, stackTeam: string, user: string, now: number): Promise<void> => {
  try {
    const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team)) as unknown as { stackWebhook(entity: string, event: StackEvent): Promise<StackSyncReply> }
    const reply = await stub.stackWebhook(team, { svix_id: `user-teams:${user}:${Math.floor(now / HEAL_WINDOW_MS)}`, type: "team.updated", stack_team: stackTeam, urgent: true })
    console.log(JSON.stringify({ msg: "team list synced a stack team", team, outcome: reply.ok ? reply.outcome : reply.reason }))
  } catch (e) {
    logged("team list stack sync failed", e)
  }
}

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
export const listUserTeams = async (env: Env, p: Principal, deps: UserTeamsDeps = defaultDeps(env)): Promise<ReadResult> => {
  if (p.kind !== "session" || !p.user || p.agent !== undefined) return { ok: false, code: "auth.forbidden", message: "user.teams.list is for a person's session" }
  const user = p.user
  const personal = personalTeamIdFor(user)
  const stub = env.USER_DO.get(env.USER_DO.idFromName(user)) as unknown as { homeTeamsOf(entity: string): Promise<Array<{ team: string; kind: string }>> }
  const indexed = (await stub.homeTeamsOf(user)).filter((e) => e.team !== personal && TEAM_ID.test(e.team)).map((e) => e.team)
  // Stack's own list joins the index, so a team TeamDO never mirrored is synced below and listed.
  const fromStack = await stackTeamsOf(env, p, deps)
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
