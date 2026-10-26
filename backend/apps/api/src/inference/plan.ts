import { INFERENCE_PERSONAL_PLAN_IDS, INFERENCE_TEAM_PLAN_IDS } from "@cmux/protocol"
import type { TeamState } from "../domains/team.ts"
import { memberLimit } from "../domains/team-ai-limit.ts"
import type { StackServer } from "../stack-server.ts"

/**
 * The paid-plan gate of the model router (cx-ds09i): a signed-in caller's team must hold a paid
 * plan (inference-plans.ts says which sign-in service field carries which plan). The team's
 * TeamDO reads the plan and keeps it in its own storage:
 *
 * - a shared team: the team's plan, written on every Stack team webhook delivery
 *   (team-stack-sync.ts) and read again from Stack when the copy is older than PLAN_FRESH_MS;
 * - a personal team: its owner's personal plan, read from Stack the same way. The Worker names
 *   the owner's Stack user (UserDO.stackUserOf of the authenticated user) and calls this only
 *   for that user's own personal team id.
 *
 * A Stack failure keeps a copy up to PLAN_STALE_MS (2 h); with no usable copy the answer is
 * "unavailable" (503, retryable), never "unpaid", so an outage does not lock out a paying team.
 */
export const PLAN_FRESH_MS = 10 * 60_000
/** An unpaid answer is asked again sooner: a person who just bought a plan has no webhook for it. */
export const UNPAID_FRESH_MS = 60_000
/** During a Stack failure a stored copy answers at most this long after it was read (review P3). */
export const PLAN_STALE_MS = 2 * 60 * 60_000
/** After a failed Stack read, the stale copy answers without a new read for this long. */
export const FAILURE_BACKOFF_MS = 60_000

/** `user_limit_usd`: the caller's monthly AI limit in this team (personal, else team default, else 200; team-ai-limit.ts). */
/** `plan`: the plan id the sign-in service holds (go, pro, max, founders, team), or null (cx-y79zh S5: the included-amount stop). */
export type PlanAnswer = { readonly ok: true; readonly paid: boolean; readonly user_limit_usd: number; readonly plan?: string | null } | { readonly ok: false; readonly reason: "unavailable" }

const ensure = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS inference_plan (id INTEGER PRIMARY KEY CHECK (id = 1), plan TEXT, checked_at INTEGER NOT NULL, failed_at INTEGER)`)
}

/**
 * Stores what Stack answered at `at` (null = no plan). A read that started before a newer write
 * (a webhook delivery) never overwrites it.
 */
export const storePlan = (sql: SqlStorage, plan: string | null, at: number) => {
  ensure(sql)
  sql.exec(`INSERT INTO inference_plan (id, plan, checked_at, failed_at) VALUES (1, ?, ?, NULL) ON CONFLICT (id) DO UPDATE SET plan = excluded.plan, checked_at = excluded.checked_at, failed_at = NULL WHERE excluded.checked_at >= inference_plan.checked_at`, plan, at)
}

/**
 * The stored plan when fresh, else Stack's answer (stored), else a stale copy within
 * PLAN_STALE_MS, else unavailable. `read` throws on a Stack failure.
 */
export const readPlan = async (sql: SqlStorage, now: number, read: () => Promise<string | null>): Promise<{ ok: true; plan: string | null } | { ok: false }> => {
  ensure(sql)
  const row = sql.exec<{ plan: string | null; checked_at: number; failed_at: number | null }>(`SELECT plan, checked_at, failed_at FROM inference_plan WHERE id = 1`).toArray()[0]
  const age = row ? now - Number(row.checked_at) : Infinity
  if (row && age < (row.plan === null ? UNPAID_FRESH_MS : PLAN_FRESH_MS)) return { ok: true, plan: row.plan }
  // Stack failed a moment ago: answer from the stale copy (or unavailable) without waiting on Stack again.
  if (row && row.failed_at !== null && now - Number(row.failed_at) < FAILURE_BACKOFF_MS) return age < PLAN_STALE_MS ? { ok: true, plan: row.plan } : { ok: false }
  try {
    const plan = await read()
    storePlan(sql, plan, now)
    return { ok: true, plan }
  } catch (e) {
    console.warn(JSON.stringify({ msg: "inference.plan.read_failed", error: String(e).slice(0, 160), stale: Boolean(row) }))
    if (row) sql.exec(`UPDATE inference_plan SET failed_at = ? WHERE id = 1`, now)
    if (row && now - Number(row.checked_at) < PLAN_STALE_MS) return { ok: true, plan: row.plan }
    return { ok: false }
  }
}

export const teamPlanPaid = (plan: string | null) => plan !== null && INFERENCE_TEAM_PLAN_IDS.has(plan)
export const personalPlanPaid = (plan: string | null) => plan !== null && INFERENCE_PERSONAL_PLAN_IDS.has(plan)

/**
 * Plans bought through a Chief's test-mode checkout link (plan-checkout.ts). The sign-in service's
 * plan is written only by web billing, so each paid test session is kept here instead, one row per
 * session with its subscription. A cancelled subscription marks its row revoked; a row is never
 * deleted, so a replayed session (the return page reloaded, a webhook redelivered) never grants again.
 * The plan is the newest unrevoked row. TeamDO honors it only off production (`testGrants`).
 */
const ensureGrant = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS test_plan_session (session TEXT PRIMARY KEY, plan TEXT NOT NULL, subscription TEXT NOT NULL, granted_at INTEGER NOT NULL, revoked_at INTEGER)`)
}

/**
 * Records a paid test session's plan. `added` is false when this session was seen before; `revoked`
 * is true when its subscription was cancelled since (a replay of it grants nothing).
 */
export const grantTestPlan = (sql: SqlStorage, plan: string, session: string, subscription: string, now: number): { added: boolean; revoked: boolean } => {
  ensureGrant(sql)
  const added = sql.exec(`INSERT OR IGNORE INTO test_plan_session (session, plan, subscription, granted_at) VALUES (?, ?, ?, ?)`, session, plan, subscription, now).rowsWritten > 0
  const revoked = sql.exec<{ revoked_at: number | null }>(`SELECT revoked_at FROM test_plan_session WHERE session = ?`, session).one().revoked_at !== null
  return { added, revoked }
}

/** Marks the grants its subscription made revoked (the subscription was cancelled); true when one was live. */
export const revokeTestPlan = (sql: SqlStorage, subscription: string, now: number): boolean => {
  if (!hasGrantTable(sql)) return false
  return sql.exec(`UPDATE test_plan_session SET revoked_at = ? WHERE subscription = ? AND revoked_at IS NULL`, now, subscription).rowsWritten > 0
}

/** The newest unrevoked test plan, or null (no table create on a read). */
export const testPlanGrant = (sql: SqlStorage): string | null =>
  hasGrantTable(sql) ? (sql.exec<{ plan: string }>(`SELECT plan FROM test_plan_session WHERE revoked_at IS NULL ORDER BY granted_at DESC, session DESC LIMIT 1`).toArray()[0]?.plan ?? null) : null

const hasGrantTable = (sql: SqlStorage) => sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'test_plan_session'`).one().n > 0

/**
 * TeamDO.inferencePlan: the answer for `entity`. `stackUser` is set only for the caller's own
 * personal team (route.ts); a shared team needs its live mirrored Stack team. With `testGrants`
 * (off production), a test plan grant makes an unpaid or unreadable answer paid with that plan.
 */
export const inferencePlanOf = async (sql: SqlStorage, state: TeamState | null, entity: string, stack: StackServer | undefined, stackUser: string | undefined, user: string, now = Date.now(), testGrants = false): Promise<PlanAnswer> => {
  const answer = await sourcePlanOf(sql, state, entity, stack, stackUser, user, now)
  const granted = testGrants && !(answer.ok && answer.paid) ? testPlanGrant(sql) : null
  return granted === null ? answer : { ok: true, paid: true, user_limit_usd: memberLimit(state, user).limit_usd, plan: granted }
}

const sourcePlanOf = async (sql: SqlStorage, state: TeamState | null, entity: string, stack: StackServer | undefined, stackUser: string | undefined, user: string, now: number): Promise<PlanAnswer> => {
  const team = state?.team ?? null
  const limit = memberLimit(state, user).limit_usd
  const read = (fetch: (s: StackServer) => Promise<string | null>) =>
    readPlan(sql, now, async () => {
      if (!stack) throw new Error("stack server not configured")
      return fetch(stack)
    })
  if (stackUser !== undefined) {
    // A personal team may not be mirrored here yet; the Worker checked the id is the caller's own.
    if (team && (team.id !== entity || team.kind !== "personal")) return { ok: true, paid: false, user_limit_usd: limit }
    const r = await read(async (s) => {
      const plan = await s.getUserPlan(stackUser)
      return plan === "user_gone" ? null : plan
    })
    return r.ok ? { ok: true, paid: personalPlanPaid(r.plan), user_limit_usd: limit, plan: r.plan } : { ok: false, reason: "unavailable" }
  }
  if (!team || team.id !== entity || team.deleted_at !== undefined || team.kind !== "stack" || !team.stack_team) return { ok: true, paid: false, user_limit_usd: limit }
  const stackTeam = team.stack_team
  const r = await read(async (s) => (await s.getTeam(stackTeam))?.plan ?? null)
  return r.ok ? { ok: true, paid: teamPlanPaid(r.plan), user_limit_usd: limit, plan: r.plan } : { ok: false, reason: "unavailable" }
}

/** The stored plan copy, without a Stack read (team.ai_limit.get's team line); null when there is none yet. */
export const storedPlan = (sql: SqlStorage): string | null => {
  // A read: no table create (review P3); a team that never had a plan check has no copy.
  if (sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'inference_plan'`).one().n === 0) return null
  return sql.exec<{ plan: string | null }>(`SELECT plan FROM inference_plan WHERE id = 1`).toArray()[0]?.plan ?? null
}
