import type { Principal, SqlStore } from "@cmux/ownership"
import type { Env } from "./env.ts"

/**
 * Home rate limits on the ops that resolve human reach (home-messaging.md section 9). Each such
 * op fans out to TeamDOs, other users' UserDOs and ConversationDOs (home-reach.ts, about four
 * RPCs per target and up to 64 targets), so the Worker asks the caller's UserDO first and stops
 * there when the hour's budget is spent. The count is per acting principal (a user, or one of
 * the user's chiefs) in the user's UserDO, and every attempt counts, also a refused one.
 * dm.open with a user peer spends the conversation.create budget (home-routes.ts).
 */
export const HOME_RATE_LIMITS = { "conversation.create": 60, "participants.add": 120 } as const
export type HomeRateOp = keyof typeof HOME_RATE_LIMITS
export const HOME_RATE_WINDOW_MS = 3_600_000
export const HOME_RATE_LIMITED = "home.rate_limited"

export type HomeRateGate = { readonly ok: true } | { readonly ok: false; readonly retry_after_ms: number }

export const isHomeRateOp = (op: string): op is HomeRateOp => Object.hasOwn(HOME_RATE_LIMITS, op)

/**
 * All of an owner's chiefs together get CHIEF_TOTAL_FACTOR times the per-actor limit per hour
 * (180 conversation.create, 360 participants.add), counted under CHIEF_TOTAL_ACTOR besides each
 * chief's own budget. Without it an archive-and-create loop of chiefs would mint fresh budgets.
 * 3 lets an owner run three chiefs at full rate at once (a default chief plus two task chiefs is
 * the common case) while capping a chief-driven flood at three humans' worth.
 */
export const CHIEF_TOTAL_FACTOR = 3
/** Not a valid principal id (no `user_`/`agent_` prefix), so it never collides with an actor. */
export const CHIEF_TOTAL_ACTOR = "chiefs:total"
const isChiefActor = (actor: string) => actor.startsWith("agent_")

/**
 * The decision for one attempt at `now`, given the attempts already counted in the window.
 * Refused: wait until the oldest counted attempt leaves the window.
 */
export const homeRateDecision = (times: ReadonlyArray<number>, now: number, limit: number, windowMs: number = HOME_RATE_WINDOW_MS): HomeRateGate => {
  const live = times.filter((t) => t > now - windowMs)
  if (live.length < limit) return { ok: true }
  return { ok: false, retry_after_ms: Math.max(1, Math.min(...live) + windowMs - now) }
}

/**
 * The UserDO side of takeHomeRate: takes one attempt from `actor`'s hourly budget for `op`, or
 * answers how long to wait. Attempts live in a private table, never in events; rows older than
 * the window are pruned on every call.
 */
export const homeRateTakeSql = (sql: SqlStore, actor: string, op: HomeRateOp, now: number): HomeRateGate => {
  if (!isHomeRateOp(op) || typeof actor !== "string" || actor.length === 0 || actor.length > 128) return { ok: false, retry_after_ms: HOME_RATE_WINDOW_MS }
  sql.exec(`CREATE TABLE IF NOT EXISTS home_rate (actor TEXT NOT NULL, op TEXT NOT NULL, at INTEGER NOT NULL)`)
  sql.exec(`CREATE INDEX IF NOT EXISTS home_rate_by_actor ON home_rate (actor, op, at)`)
  sql.exec(`DELETE FROM home_rate WHERE at <= ?`, now - HOME_RATE_WINDOW_MS)
  const decide = (who: string, limit: number) => homeRateDecision(sql.exec<{ at: number }>(`SELECT at FROM home_rate WHERE actor = ? AND op = ?`, who, op).map((r) => Number(r.at)), now, limit)
  // A chief's attempt needs room in its own budget and in the owner's chief total; it counts in both.
  const counted = isChiefActor(actor) ? [actor, CHIEF_TOTAL_ACTOR] : [actor]
  const gates = counted.map((who) => decide(who, who === CHIEF_TOTAL_ACTOR ? HOME_RATE_LIMITS[op] * CHIEF_TOTAL_FACTOR : HOME_RATE_LIMITS[op]))
  const refused = gates.filter((g): g is Extract<HomeRateGate, { ok: false }> => !g.ok)
  if (refused.length > 0) return { ok: false, retry_after_ms: Math.max(...refused.map((g) => g.retry_after_ms)) }
  for (const who of counted) sql.exec(`INSERT INTO home_rate (actor, op, at) VALUES (?, ?, ?)`, who, op, now)
  return { ok: true }
}

interface RateStub {
  homeRateTake(entity: string, actor: string, op: HomeRateOp): Promise<HomeRateGate>
}

/**
 * Takes one attempt from the caller's budget for `op`. A principal with no user has no UserDO
 * and no reach (home-reach.ts answers it with no facts and no RPCs), so it is not counted here.
 */
export const takeHomeRate = async (env: Env, principal: Principal, actor: string, op: HomeRateOp): Promise<HomeRateGate> => {
  const raw = principal.user
  if (!raw) return { ok: true }
  const user = raw.startsWith("user_") ? raw : `user_${raw}`
  const stub = env.USER_DO.get(env.USER_DO.idFromName(user)) as unknown as RateStub
  return stub.homeRateTake(user, actor, op)
}
