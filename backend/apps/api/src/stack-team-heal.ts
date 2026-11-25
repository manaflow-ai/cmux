import { waitUntil } from "cloudflare:workers"
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
/**
 * How long a membership check waits on TeamDO's first read, and on the Stack heal after it. A member TeamDO
 * already knows is answered by the first read; only a team TeamDO does not confirm waits on Stack, and at most
 * HEAL_BUDGET_MS: the app gives `/v1/auth/token` 25 s (NEXT Nightly on production, 2026-11-14: a team-scoped
 * mint ran past it while Stack's team read, 10 s a request plus 429 retries, and the team sync, up to 10 s,
 * ran one after the other with no total budget).
 */
export const MEMBER_READ_MS = 5_000
export const HEAL_BUDGET_MS = 3_000
/**
 * Each person's last Stack read, per isolate: when, and the teams it named (a read still running included).
 * Inside the window every caller gets that same map, so a mint that heals one team never hides the person's
 * other teams from a later user.teams.list (each caller still asks TeamDO first and syncs only a team TeamDO
 * does not confirm), and a mint retried while the read runs waits on it instead of finding no teams. A soft
 * limit: the shared pace and TeamDO's delivery dedupe bound the rest.
 */
const healedAt = new Map<string, { readonly at: number; readonly teams: Promise<ReadonlyMap<string, string> | undefined>; settled: boolean }>()
/**
 * A read or sync still running after this long is not waited on again (a Worker request that ended can drop
 * its fetch, leaving the promise unsettled for good): Stack's read gives up within about 12 s, a sync within 10 s.
 */
export const IN_FLIGHT_STALE_MS = 30_000
const HEALED_MAX = 10_000

const logged = (msg: string, e: unknown) => console.error(JSON.stringify({ msg, error: String(e).slice(0, 200) }))

/**
 * Keeps work that outlived its caller's budget running after the response (the request's waitUntil): without it
 * the Workers runtime may cancel a heal once a Worker request answers, and the retry finds nothing synced.
 */
export const keepAlive = (p: Promise<unknown>): void => {
  const settled = p.catch((e) => logged("background stack work failed", e))
  try {
    waitUntil(settled)
  } catch (e) {
    logged("no request to keep stack work alive in", e)
  }
}

/** `p`'s value when it settles within `ms`; `{ done: false }` past it (p keeps running). */
export const within = <T>(p: Promise<T>, ms: number): Promise<{ readonly done: true; readonly value: T } | { readonly done: false }> => {
  let timer: ReturnType<typeof setTimeout> | undefined
  const late = new Promise<{ done: false }>((resolve) => (timer = setTimeout(() => resolve({ done: false }), ms)))
  return Promise.race([p.then((value) => ({ done: true as const, value })), late]).finally(() => clearTimeout(timer))
}

/**
 * The person's Stack teams as cmux ids (to their Stack ids), read at most once per HEAL_WINDOW_MS and only
 * with a pace token; inside the window, the last read's teams; empty when never read (or unreadable). A Stack team whose webhook deliveries never reached TeamDO
 * (one made before the mirror existed, or events Stack never sent) is otherwise never known: its TeamDO
 * does not know its members (prod 2026-10-29: Home listed no teammates; 2026-11-11: `cmux auth token`
 * refused the app's own active team as not a member).
 */
export const stackTeamsOf = async (env: Env, user: string, stackUser: string | undefined, deps: StackHealDeps): Promise<Map<string, string>> =>
  new Map((await stackTeamsRead(env, user, stackUser, deps)) ?? [])

/**
 * stackTeamsOf's read, telling "Stack answered" (its teams, maybe none) from "Stack was not asked or did not answer"
 * (undefined: no pace token, or the read failed). Neither of the latter is kept for the window: the next check asks
 * again. memberCheck refuses "not a member" only on an answer (prod 2026-11-24: an unread Stack refused the probe
 * account's own selected team as auth.forbidden on every mint, where a retry would have healed it).
 */
const stackTeamsRead = async (env: Env, user: string, stackUser: string | undefined, deps: StackHealDeps): Promise<ReadonlyMap<string, string> | undefined> => {
  if (!deps.stack || !stackUser) return new Map()
  const stack = deps.stack
  const now = deps.now()
  const last = healedAt.get(user)
  if (last !== undefined && now - last.at < HEAL_WINDOW_MS && (last.settled || now - last.at < IN_FLIGHT_STALE_MS)) return last.teams
  if (healedAt.size >= HEALED_MAX) healedAt.clear()
  // Published before the pace token is asked for, so a concurrent check waits on this read instead of asking for a
  // token of its own and, without one, refusing a real member while the read runs (review F1 on cmux#42958).
  let entry: { readonly at: number; readonly teams: Promise<ReadonlyMap<string, string> | undefined>; settled: boolean } | undefined
  // Stack was not asked (no token) or did not answer: nothing is kept for the window, so the next check asks again.
  const unread = (): undefined => {
    if (entry !== undefined && healedAt.get(user) === entry) healedAt.delete(user)
    return undefined
  }
  const teams = Promise.resolve()
    .then(() => deps.pace().catch(() => false))
    .then(async (paced): Promise<ReadonlyMap<string, string> | undefined> => {
      if (!paced) return unread()
      try {
        const ids = await stack.listUserTeams(stackUser)
        return new Map(ids.map((id) => [stackTeamIdFor(env.STACK_PROJECT_ID, id), id] as const))
      } catch (e) {
        logged("stack teams unreadable", e)
        return unread()
      }
    })
  entry = { at: now, teams, settled: false }
  const published = entry
  healedAt.set(user, published)
  void teams.then(() => void (published.settled = true))
  return teams
}

/** Syncs still running, per isolate, by team and person: a second caller (a retried mint) waits on the first instead of a duplicate delivery. */
const syncing = new Map<string, { readonly at: number; readonly run: Promise<string | undefined> }>()

/**
 * A full sync of one Stack team in its TeamDO (team-stack-sync.ts), as a team.updated delivery would run it; one
 * per person per window. Answers the delivery's outcome (`queued`: not synced yet), undefined when it failed.
 */
export const syncTeam = (env: Env, team: string, stackTeam: string, user: string, now: number, delivery = `user-teams:${user}:${Math.floor(now / HEAL_WINDOW_MS)}`): Promise<string | undefined> => {
  if (teamSyncedAt.size >= HEALED_MAX) teamSyncedAt.clear()
  teamSyncedAt.set(team, now)
  const key = `${team}\u0000${user}\u0000${delivery}`
  const running = syncing.get(key)
  if (running && Date.now() - running.at < IN_FLIGHT_STALE_MS) return running.run
  // Started on the next microtask, so `run` is assigned before its `finally` compares it.
  const run: Promise<string | undefined> = Promise.resolve().then(async () => {
    try {
      const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team))
      const reply = await stub.stackWebhook(team, { svix_id: delivery, type: "team.updated", stack_team: stackTeam, urgent: true })
      const outcome = reply.ok ? reply.outcome : reply.reason
      console.log(JSON.stringify({ msg: "synced a stack team", team, outcome }))
      return reply.ok ? reply.outcome : undefined
    } catch (e) {
      logged("stack team sync failed", e)
      return undefined
    } finally {
      if (syncing.get(key)?.run === run) syncing.delete(key)
    }
  })
  if (syncing.size >= HEALED_MAX) syncing.clear()
  syncing.set(key, { at: Date.now(), run })
  return run
}

/** When each team was last synced from Stack, per isolate (any member's sync counts): refreshTeam's window. */
const teamSyncedAt = new Map<string, number>()

/**
 * A full sync of a team the person is already confirmed in, at most once per team per HEAL_WINDOW_MS; undefined when
 * the team was synced inside the window. A teammate who joined in Stack (an accepted invite writes Stack only) and
 * whose webhook never reached TeamDO is otherwise never mirrored: the heal above runs only for the caller missing,
 * so Home never listed the new teammate and `dm.open` refused them as sharing no team (#48467, 2026-11-23: a member
 * shown in Settings > Accounts could not be messaged from Home).
 */
export const refreshTeam = (env: Env, team: string, stackTeam: string, user: string, now: number): Promise<string | undefined> | undefined => {
  const last = teamSyncedAt.get(team)
  if (last !== undefined && now - last < HEAL_WINDOW_MS && now >= last) return undefined
  // One delivery per team per window across isolates and people: TeamDO answers a repeat `duplicate` before it takes a
  // Stack pace token, and the per-person heal above keeps its own delivery for the window.
  const run = syncTeam(env, team, stackTeam, user, now, `team-refresh:${Math.floor(now / HEAL_WINDOW_MS)}`)
  // A sync that failed is tried again by the next list, not after the window.
  void run.then((outcome) => {
    if (outcome === undefined && teamSyncedAt.get(team) === now) teamSyncedAt.delete(team)
  })
  return run
}

/** A membership answer: the role (null = not a member, by TeamDO and Stack), or `pending`: the step still running past its budget. */
export type MemberCheck = { readonly role: string | null } | { readonly pending: string }

export interface MemberCheckOptions {
  readonly readMs?: number
  readonly healMs?: number
  /** Keeps a heal that outlived its budget running (a Durable Object's ctx.waitUntil); default: the request's waitUntil (keepAlive). */
  readonly background?: (p: Promise<unknown>) => void
}

/**
 * The person's role in shared team `team` now, by TeamDO; when TeamDO does not know them but Stack lists
 * them in that team, the role once the team is synced from Stack. Every membership check that refuses
 * "not a member" (an install token's team at mint, a session's x-cmux-team) goes through this, so a team
 * the webhook never mirrored is refused only when Stack agrees. Bounded: past MEMBER_READ_MS for TeamDO's
 * read, or HEAL_BUDGET_MS for the heal, it answers `pending` (callers answer a retryable owner.unreachable)
 * and the heal goes on, so the next check finds the team synced. Throws when TeamDO's first read fails.
 */
export const memberCheck = async (env: Env, team: string, user: string, stackUser: string | undefined, deps: StackHealDeps = stackHealDeps(env), opts: MemberCheckOptions = {}): Promise<MemberCheck> => {
  const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team))
  const first = await within(Promise.resolve(stub.memberRole(team, user)), opts.readMs ?? MEMBER_READ_MS)
  if (!first.done) return { pending: "reading the team's membership" }
  if (first.value) return { role: first.value }
  let step = "reading your teams from Stack"
  const heal = (async (): Promise<MemberCheck> => {
    const teams = await stackTeamsRead(env, user, stackUser, deps)
    // Stack was not asked or did not answer: not known to be outside the team, so ask again later.
    if (teams === undefined) return { pending: "reading your teams from Stack" }
    const stackTeam = teams.get(team)
    if (stackTeam === undefined) return { role: null }
    step = "syncing the team from Stack"
    const outcome = await syncTeam(env, team, stackTeam, user, deps.now())
    step = "reading the team's membership after its Stack sync"
    const role = await stub.memberRole(team, user)
    if (role) return { role }
    // Stack lists them, and the sync has not landed: queued behind the Stack pace, failed, or this window's delivery
    // already recorded and still queued (`duplicate`, review F2). Ask again later, never "not a member".
    return outcome === undefined || outcome === "queued" || outcome === "duplicate" ? { pending: "the team's sync from Stack is queued" } : { role: null }
  })()
  const healed = await within(heal, opts.healMs ?? HEAL_BUDGET_MS)
  if (healed.done) return healed.value
  console.log(JSON.stringify({ msg: "stack team heal past its budget", team, step }))
  const keep = opts.background ?? keepAlive
  keep(heal.catch((e) => logged("stack team heal failed", e)))
  return { pending: step }
}
