import { INFERENCE_PERSONAL_PLAN_IDS, INFERENCE_TEAM_PLAN_IDS } from "@cmux/protocol"
import { readStackTeam } from "../cloud-vm-plan.ts"
import type { TeamState } from "../domains/team.ts"
import { memberLimit } from "../domains/team-ai-limit.ts"
import { chiefAddonId, nextPlanId, planTime, type StackServer } from "../stack-server.ts"

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
/** `next_plan`: the record's cmux NEXT plan (cmuxNextPlan: next_plus, next_pro, next_max, or an entry plan next_intro or next_taste), or null; for the Cloud service only, it never changes `paid` or the limit. */
/** `chief_addon`: the record's Cloud Chief add-on (cmuxChiefAddon: M, L or XL), or null (the included Chief); for the Cloud service only, it never changes `paid` or the limit. */
/** `next_plan_started_at`, `next_plan_ends_at`: the NEXT plan's term (cmuxNextPlanStartedAt, cmuxNextPlanEndsAt; ISO times, planTime), or null; for the Cloud service only, which enforces the term (RFD 0052). */
export type PlanAnswer = { readonly ok: true; readonly paid: boolean; readonly user_limit_usd: number; readonly plan?: string | null; readonly next_plan?: string | null; readonly chief_addon?: string | null; readonly next_plan_started_at?: string | null; readonly next_plan_ends_at?: string | null } | { readonly ok: false; readonly reason: "unavailable" }

const tableReady = new WeakSet<SqlStorage>()
const ensure = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS inference_plan (id INTEGER PRIMARY KEY CHECK (id = 1), plan TEXT, checked_at INTEGER NOT NULL, failed_at INTEGER)`)
  if (tableReady.has(sql)) return
  // The record's cmuxNextPlan; NULL (no NEXT plan) for a copy stored before it was read.
  const columns = sql.exec<{ name: string }>(`PRAGMA table_info(inference_plan)`).toArray()
  if (!columns.some((c) => c.name === "next_plan")) sql.exec(`ALTER TABLE inference_plan ADD COLUMN next_plan TEXT`)
  // The record's cmuxChiefAddon; NULL (no add-on) for a copy stored before it was read.
  if (!columns.some((c) => c.name === "chief_addon")) sql.exec(`ALTER TABLE inference_plan ADD COLUMN chief_addon TEXT`)
  // The NEXT plan's term (cmuxNextPlanStartedAt, cmuxNextPlanEndsAt); NULL (no term) for a copy stored before it was read.
  if (!columns.some((c) => c.name === "next_plan_started_at")) sql.exec(`ALTER TABLE inference_plan ADD COLUMN next_plan_started_at TEXT`)
  if (!columns.some((c) => c.name === "next_plan_ends_at")) sql.exec(`ALTER TABLE inference_plan ADD COLUMN next_plan_ends_at TEXT`)
  tableReady.add(sql)
}

/**
 * What one record read holds: `plan` (cmuxPlan), `next_plan` (cmuxNextPlan), `chief_addon` (cmuxChiefAddon) and the
 * NEXT plan's term `next_plan_started_at` and `next_plan_ends_at` (cmuxNextPlanStartedAt, cmuxNextPlanEndsAt); absent is none.
 */
export type PlanRead = { readonly plan: string | null; readonly next_plan: string | null; readonly chief_addon?: string | null; readonly next_plan_started_at?: string | null; readonly next_plan_ends_at?: string | null }

/**
 * Stores what Stack answered at `at` (null = no plan). A read that started before a newer write
 * (a webhook delivery) never overwrites it.
 */
export const storePlan = (sql: SqlStorage, plan: string | null, at: number, nextPlan: string | null = null, chiefAddon: string | null = null, nextPlanStartedAt: string | null = null, nextPlanEndsAt: string | null = null) => {
  ensure(sql)
  sql.exec(`INSERT INTO inference_plan (id, plan, checked_at, failed_at, next_plan, chief_addon, next_plan_started_at, next_plan_ends_at) VALUES (1, ?, ?, NULL, ?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET plan = excluded.plan, checked_at = excluded.checked_at, failed_at = NULL, next_plan = excluded.next_plan, chief_addon = excluded.chief_addon, next_plan_started_at = excluded.next_plan_started_at, next_plan_ends_at = excluded.next_plan_ends_at WHERE excluded.checked_at >= inference_plan.checked_at`, plan, at, nextPlanId(nextPlan), chiefAddonId(chiefAddon), planTime(nextPlanStartedAt), planTime(nextPlanEndsAt))
}

/**
 * The stored plan when fresh, else Stack's answer (stored), else a stale copy within
 * PLAN_STALE_MS, else unavailable. `read` throws on a Stack failure.
 */
export const readPlan = async (sql: SqlStorage, now: number, read: () => Promise<PlanRead>): Promise<({ ok: true } & Required<PlanRead>) | { ok: false }> => {
  ensure(sql)
  const row = sql.exec<{ plan: string | null; next_plan: string | null; chief_addon: string | null; next_plan_started_at: string | null; next_plan_ends_at: string | null; checked_at: number; failed_at: number | null }>(`SELECT plan, next_plan, chief_addon, next_plan_started_at, next_plan_ends_at, checked_at, failed_at FROM inference_plan WHERE id = 1`).toArray()[0]
  const age = row ? now - Number(row.checked_at) : Infinity
  // The copy's answer; a copy from before next_plan (or chief_addon, or the term) was stored has NULL there (no NEXT plan, no add-on, no term).
  const copy = row ? { ok: true as const, plan: row.plan, next_plan: nextPlanId(row.next_plan), chief_addon: chiefAddonId(row.chief_addon), next_plan_started_at: planTime(row.next_plan_started_at), next_plan_ends_at: planTime(row.next_plan_ends_at) } : undefined
  if (copy && age < (copy.plan === null ? UNPAID_FRESH_MS : PLAN_FRESH_MS)) return copy
  // Stack failed a moment ago: answer from the stale copy (or unavailable) without waiting on Stack again.
  if (row && copy && row.failed_at !== null && now - Number(row.failed_at) < FAILURE_BACKOFF_MS) return age < PLAN_STALE_MS ? copy : { ok: false }
  try {
    const r = await read()
    const next_plan = nextPlanId(r.next_plan)
    const chief_addon = chiefAddonId(r.chief_addon)
    const next_plan_started_at = planTime(r.next_plan_started_at)
    const next_plan_ends_at = planTime(r.next_plan_ends_at)
    storePlan(sql, r.plan, now, next_plan, chief_addon, next_plan_started_at, next_plan_ends_at)
    return { ok: true, plan: r.plan, next_plan, chief_addon, next_plan_started_at, next_plan_ends_at }
  } catch (e) {
    console.warn(JSON.stringify({ msg: "inference.plan.read_failed", error: String(e).slice(0, 160), stale: Boolean(row) }))
    if (row) sql.exec(`UPDATE inference_plan SET failed_at = ? WHERE id = 1`, now)
    if (copy && age < PLAN_STALE_MS) return copy
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
 * A cancellation that arrives before its checkout (webhooks are not ordered) leaves a tombstone in
 * `test_plan_revoked`, so the later checkout is born revoked. The plan is the newest unrevoked row.
 * TeamDO honors it only off production (`testGrants`).
 */
const ensureGrant = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS test_plan_session (session TEXT PRIMARY KEY, plan TEXT NOT NULL, subscription TEXT NOT NULL, granted_at INTEGER NOT NULL, revoked_at INTEGER)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS test_plan_revoked (subscription TEXT PRIMARY KEY, revoked_at INTEGER NOT NULL)`)
}

/**
 * Records a paid test session's plan. `added` is false when this session was seen before; `revoked`
 * is true when its subscription was cancelled since (a replay of it grants nothing).
 */
export const grantTestPlan = (sql: SqlStorage, plan: string, session: string, subscription: string, now: number): { added: boolean; revoked: boolean } => {
  ensureGrant(sql)
  const tomb = sql.exec<{ revoked_at: number }>(`SELECT revoked_at FROM test_plan_revoked WHERE subscription = ?`, subscription).toArray()[0]?.revoked_at ?? null
  const added = sql.exec(`INSERT OR IGNORE INTO test_plan_session (session, plan, subscription, granted_at, revoked_at) VALUES (?, ?, ?, ?, ?)`, session, plan, subscription, now, tomb).rowsWritten > 0
  const revoked = sql.exec<{ revoked_at: number | null }>(`SELECT revoked_at FROM test_plan_session WHERE session = ?`, session).one().revoked_at !== null
  return { added, revoked }
}

/**
 * The subscription was cancelled: its grants are marked revoked, and a tombstone keeps a checkout of it
 * that is delivered later from granting. True when a live grant was revoked.
 */
export const revokeTestPlan = (sql: SqlStorage, subscription: string, now: number): boolean => {
  ensureGrant(sql)
  sql.exec(`INSERT OR IGNORE INTO test_plan_revoked (subscription, revoked_at) VALUES (?, ?)`, subscription, now)
  return sql.exec(`UPDATE test_plan_session SET revoked_at = ? WHERE subscription = ? AND revoked_at IS NULL`, now, subscription).rowsWritten > 0
}

/**
 * The newest unrevoked test plan, or null (no table create on a read). `kind` "plan" is a classic plan (pro, max:
 * it stands in for cmuxPlan); "next_plan" is a cmux NEXT plan (next_plus, next_pro, next_max: it stands in for
 * cmuxNextPlan, plan-checkout.ts NEXT_PLANS). One kind never answers for the other.
 */
export const testPlanGrant = (sql: SqlStorage, kind: "plan" | "next_plan" = "plan"): string | null =>
  hasGrantTable(sql) ? (sql.exec<{ plan: string }>(`SELECT plan FROM test_plan_session WHERE revoked_at IS NULL AND (substr(plan, 1, 5) = 'next_') = ? ORDER BY granted_at DESC, session DESC LIMIT 1`, kind === "next_plan" ? 1 : 0).toArray()[0]?.plan ?? null) : null

const hasGrantTable = (sql: SqlStorage) => sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'test_plan_session'`).one().n > 0

/**
 * TeamDO.inferencePlan: the answer for `entity`. `stackUser` is set only for the caller's own
 * personal team (route.ts); a shared team needs its live mirrored Stack team. With `testGrants`
 * (off production), a test plan grant makes an unpaid or unreadable answer paid with that plan.
 */
export const inferencePlanOf = async (sql: SqlStorage, state: TeamState | null, entity: string, stack: StackServer | undefined, stackUser: string | undefined, user: string, now = Date.now(), testGrants = false): Promise<PlanAnswer> => {
  const answer = await sourcePlanOf(sql, state, entity, stack, stackUser, user, now)
  const granted = testGrants && !(answer.ok && answer.paid) ? testPlanGrant(sql) : null
  // A test NEXT plan stands in for the record's cmuxNextPlan, only where the record holds none (a real subscription
  // wins) and only on an answer that was read (an outage stays one). It carries no term: it is no intro pass.
  const nextGranted = testGrants && answer.ok && !answer.next_plan ? testPlanGrant(sql, "next_plan") : null
  const withNext = (a: PlanAnswer): PlanAnswer => (nextGranted === null || !a.ok ? a : { ...a, next_plan: nextGranted, next_plan_started_at: null, next_plan_ends_at: null })
  // The grant stands in for cmuxPlan only; the record's cmux NEXT plan (next_plan, with its term) and Chief add-on (chief_addon) are kept as read.
  if (granted === null) return withNext(answer)
  const read = answer.ok ? answer : undefined
  return withNext({ ok: true, paid: true, user_limit_usd: memberLimit(state, user).limit_usd, plan: granted, next_plan: read?.next_plan ?? null, chief_addon: read?.chief_addon ?? null, next_plan_started_at: read?.next_plan_started_at ?? null, next_plan_ends_at: read?.next_plan_ends_at ?? null })
}

const sourcePlanOf = async (sql: SqlStorage, state: TeamState | null, entity: string, stack: StackServer | undefined, stackUser: string | undefined, user: string, now: number): Promise<PlanAnswer> => {
  const team = state?.team ?? null
  const limit = memberLimit(state, user).limit_usd
  const read = (fetch: (s: StackServer) => Promise<PlanRead>) =>
    readPlan(sql, now, async () => {
      if (!stack) throw new Error("stack server not configured")
      return fetch(stack)
    })
  if (stackUser !== undefined) {
    // A personal team may not be mirrored here yet; the Worker checked the id is the caller's own.
    if (team && (team.id !== entity || team.kind !== "personal")) return { ok: true, paid: false, user_limit_usd: limit }
    const r = await read(async (s) => {
      // One read of the owner's user record for every field; a server without getUserPlans has no next_plan, chief_addon or term.
      if (s.getUserPlans) {
        const plans = await s.getUserPlans(stackUser)
        return plans === "user_gone" ? { plan: null, next_plan: null, chief_addon: null, next_plan_started_at: null, next_plan_ends_at: null } : plans
      }
      const plan = await s.getUserPlan(stackUser)
      return { plan: plan === "user_gone" ? null : plan, next_plan: null, chief_addon: null, next_plan_started_at: null, next_plan_ends_at: null }
    })
    return r.ok ? { ok: true, paid: personalPlanPaid(r.plan), user_limit_usd: limit, plan: r.plan, next_plan: r.next_plan, chief_addon: r.chief_addon, next_plan_started_at: r.next_plan_started_at, next_plan_ends_at: r.next_plan_ends_at } : { ok: false, reason: "unavailable" }
  }
  if (!team || team.id !== entity || team.deleted_at !== undefined || team.kind !== "stack" || !team.stack_team) return { ok: true, paid: false, user_limit_usd: limit }
  const stackTeam = team.stack_team
  // The one shared-team read (cloud-vm-plan.ts readStackTeam): the grant it sees also refreshes the grant copy a delete carries.
  const r = await read(async (s) => {
    const t = await readStackTeam(sql, s, stackTeam, now)
    return { plan: t?.plan ?? null, next_plan: t?.next_plan ?? null, chief_addon: t?.chief_addon ?? null, next_plan_started_at: t?.next_plan_started_at ?? null, next_plan_ends_at: t?.next_plan_ends_at ?? null }
  })
  return r.ok ? { ok: true, paid: teamPlanPaid(r.plan), user_limit_usd: limit, plan: r.plan, next_plan: r.next_plan, chief_addon: r.chief_addon, next_plan_started_at: r.next_plan_started_at, next_plan_ends_at: r.next_plan_ends_at } : { ok: false, reason: "unavailable" }
}

/** The stored plan copy, without a Stack read (team.ai_limit.get's team line); null when there is none yet. */
export const storedPlan = (sql: SqlStorage): string | null => {
  // A read: no table create (review P3); a team that never had a plan check has no copy.
  if (sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'inference_plan'`).one().n === 0) return null
  return sql.exec<{ plan: string | null }>(`SELECT plan FROM inference_plan WHERE id = 1`).toArray()[0]?.plan ?? null
}
