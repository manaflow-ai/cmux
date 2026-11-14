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
const healedAt = new Map<string, { readonly at: number; readonly teams: Promise<ReadonlyMap<string, string>>; settled: boolean }>()
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
export const stackTeamsOf = async (env: Env, user: string, stackUser: string | undefined, deps: StackHealDeps): Promise<Map<string, string>> => {
  if (!deps.stack || !stackUser) return new Map()
  const stack = deps.stack
  const now = deps.now()
  const last = healedAt.get(user)
  if (last !== undefined && now - last.at < HEAL_WINDOW_MS && (last.settled || now - last.at < IN_FLIGHT_STALE_MS)) return new Map(await last.teams)
  if (!(await deps.pace().catch(() => false))) return new Map()
  if (healedAt.size >= HEALED_MAX) healedAt.clear()
  const teams = Promise.resolve()
    .then(() => stack.listUserTeams(stackUser))
    .then(
      (ids): ReadonlyMap<string, string> => new Map(ids.map((id) => [stackTeamIdFor(env.STACK_PROJECT_ID, id), id] as const)),
      (e): ReadonlyMap<string, string> => {
        logged("stack teams unreadable", e)
        return new Map()
      }
    )
  const entry = { at: now, teams, settled: false }
  healedAt.set(user, entry)
  void teams.then(() => void (entry.settled = true))
  return new Map(await teams)
}

/** Syncs still running, per isolate, by team and person: a second caller (a retried mint) waits on the first instead of a duplicate delivery. */
const syncing = new Map<string, { readonly at: number; readonly run: Promise<string | undefined> }>()

/**
 * A full sync of one Stack team in its TeamDO (team-stack-sync.ts), as a team.updated delivery would run it; one
 * per person per window. Answers the delivery's outcome (`queued`: not synced yet), undefined when it failed.
 */
export const syncTeam = (env: Env, team: string, stackTeam: string, user: string, now: number): Promise<string | undefined> => {
  const key = `${team}\u0000${user}`
  const running = syncing.get(key)
  if (running && Date.now() - running.at < IN_FLIGHT_STALE_MS) return running.run
  // Started on the next microtask, so `run` is assigned before its `finally` compares it.
  const run: Promise<string | undefined> = Promise.resolve().then(async () => {
    try {
      const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team))
      const reply = await stub.stackWebhook(team, { svix_id: `user-teams:${user}:${Math.floor(now / HEAL_WINDOW_MS)}`, type: "team.updated", stack_team: stackTeam, urgent: true })
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
    const stackTeam = (await stackTeamsOf(env, user, stackUser, deps)).get(team)
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
