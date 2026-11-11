import { stackTeamIdFor } from "./domains/user.ts"
import type { Env } from "./env.ts"
import { stackReadPace, stackServer, type StackServer } from "./stack-server.ts"

/** What a heal reads Stack with: the Worker's server client and the shared pace of Stack reads (tests pass fakes). */
export interface StackHealDeps {
  readonly stack: Pick<StackServer, "listUserTeams"> | undefined
  /** One token of the shared Stack read pace (stack-server.ts stackReadPace); false = not now. */
  readonly pace: () => Promise<boolean>
  readonly now: () => number
}
export const stackHealDeps = (env: Env): StackHealDeps => ({ stack: stackServer(env), pace: () => stackReadPace(env), now: () => Date.now() })

/** How often one person's Stack teams are compared with TeamDO. */
export const HEAL_WINDOW_MS = 10 * 60_000
/** When each person's Stack teams were last read, per isolate: a soft limit (the shared pace and TeamDO's delivery dedupe bound the rest). */
const healedAt = new Map<string, number>()
const HEALED_MAX = 10_000

const logged = (msg: string, e: unknown) => console.error(JSON.stringify({ msg, error: String(e).slice(0, 200) }))

/**
 * The person's Stack teams as cmux ids (to their Stack ids), read at most once per HEAL_WINDOW_MS and only
 * with a pace token; empty when not read now. A Stack team whose webhook deliveries never reached TeamDO
 * (one made before the mirror existed, or events Stack never sent) is otherwise never known: its TeamDO
 * does not know its members (prod 2026-10-29: Home listed no teammates; 2026-11-11: `cmux auth token`
 * refused the app's own active team as not a member).
 */
export const stackTeamsOf = async (env: Env, user: string, stackUser: string | undefined, deps: StackHealDeps): Promise<Map<string, string>> => {
  if (!deps.stack || !stackUser) return new Map()
  const now = deps.now()
  const last = healedAt.get(user)
  if (last !== undefined && now - last < HEAL_WINDOW_MS) return new Map()
  if (!(await deps.pace().catch(() => false))) return new Map()
  if (healedAt.size >= HEALED_MAX) healedAt.clear()
  healedAt.set(user, now)
  try {
    const ids = await deps.stack.listUserTeams(stackUser)
    return new Map(ids.map((id) => [stackTeamIdFor(env.STACK_PROJECT_ID, id), id] as const))
  } catch (e) {
    logged("stack teams unreadable", e)
    return new Map()
  }
}

/** A full sync of one Stack team in its TeamDO (team-stack-sync.ts), as a team.updated delivery would run it; one per person per window. */
export const syncTeam = async (env: Env, team: string, stackTeam: string, user: string, now: number): Promise<void> => {
  try {
    const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team))
    const reply = await stub.stackWebhook(team, { svix_id: `user-teams:${user}:${Math.floor(now / HEAL_WINDOW_MS)}`, type: "team.updated", stack_team: stackTeam, urgent: true })
    console.log(JSON.stringify({ msg: "synced a stack team", team, outcome: reply.ok ? reply.outcome : reply.reason }))
  } catch (e) {
    logged("stack team sync failed", e)
  }
}

/**
 * The person's role in shared team `team` now, by TeamDO; when TeamDO does not know them but Stack lists
 * them in that team, the role once the team is synced from Stack. Every membership check that refuses
 * "not a member" (an install token's team at mint, a session's x-cmux-team) goes through this, so a team
 * the webhook never mirrored is refused only when Stack agrees. Throws when TeamDO does not answer.
 */
export const memberRoleHealed = async (env: Env, team: string, user: string, stackUser: string | undefined, deps: StackHealDeps = stackHealDeps(env)): Promise<string | null> => {
  const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team))
  const role = await stub.memberRole(team, user)
  if (role) return role
  const stackTeam = (await stackTeamsOf(env, user, stackUser, deps)).get(team)
  if (stackTeam === undefined) return null
  await syncTeam(env, team, stackTeam, user, deps.now())
  return stub.memberRole(team, user)
}
