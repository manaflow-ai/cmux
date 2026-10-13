import { INFERENCE_PERSONAL_PLAN_IDS, INFERENCE_TEAM_PLAN_IDS } from "@cmux/protocol"
import type { TeamState } from "../domains/team.ts"
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
 * A Stack failure keeps a copy up to PLAN_STALE_MS; with no usable copy the answer is
 * "unavailable" (503, retryable), never "unpaid", so an outage does not lock out a paying team.
 */
export const PLAN_FRESH_MS = 10 * 60_000
export const PLAN_STALE_MS = 24 * 60 * 60_000

export type PlanAnswer = { readonly ok: true; readonly paid: boolean } | { readonly ok: false; readonly reason: "unavailable" }

const ensure = (sql: SqlStorage) =>
  sql.exec(`CREATE TABLE IF NOT EXISTS inference_plan (id INTEGER PRIMARY KEY CHECK (id = 1), plan TEXT, checked_at INTEGER NOT NULL)`)

/** Stores what Stack answered now (null = no plan). */
export const storePlan = (sql: SqlStorage, plan: string | null, now: number) => {
  ensure(sql)
  sql.exec(`INSERT INTO inference_plan (id, plan, checked_at) VALUES (1, ?, ?) ON CONFLICT (id) DO UPDATE SET plan = excluded.plan, checked_at = excluded.checked_at`, plan, now)
}

/**
 * The stored plan when fresh, else Stack's answer (stored), else a stale copy within
 * PLAN_STALE_MS, else unavailable. `read` throws on a Stack failure.
 */
export const readPlan = async (sql: SqlStorage, now: number, read: () => Promise<string | null>): Promise<{ ok: true; plan: string | null } | { ok: false }> => {
  ensure(sql)
  const row = sql.exec<{ plan: string | null; checked_at: number }>(`SELECT plan, checked_at FROM inference_plan WHERE id = 1`).toArray()[0]
  if (row && now - Number(row.checked_at) < PLAN_FRESH_MS) return { ok: true, plan: row.plan }
  try {
    const plan = await read()
    storePlan(sql, plan, now)
    return { ok: true, plan }
  } catch (e) {
    console.warn(JSON.stringify({ msg: "inference.plan.read_failed", error: String(e).slice(0, 160), stale: Boolean(row) }))
    if (row && now - Number(row.checked_at) < PLAN_STALE_MS) return { ok: true, plan: row.plan }
    return { ok: false }
  }
}

export const teamPlanPaid = (plan: string | null) => plan !== null && INFERENCE_TEAM_PLAN_IDS.has(plan)
export const personalPlanPaid = (plan: string | null) => plan !== null && INFERENCE_PERSONAL_PLAN_IDS.has(plan)

/**
 * TeamDO.inferencePlan: the answer for `entity`. `stackUser` is set only for the caller's own
 * personal team (route.ts); a shared team needs its live mirrored Stack team.
 */
export const inferencePlanOf = async (sql: SqlStorage, team: TeamState["team"], entity: string, stack: StackServer | undefined, stackUser: string | undefined, now = Date.now()): Promise<PlanAnswer> => {
  const read = (fetch: (s: StackServer) => Promise<string | null>) =>
    readPlan(sql, now, async () => {
      if (!stack) throw new Error("stack server not configured")
      return fetch(stack)
    })
  if (stackUser !== undefined) {
    // A personal team may not be mirrored here yet; the Worker checked the id is the caller's own.
    if (team && (team.id !== entity || team.kind !== "personal")) return { ok: true, paid: false }
    const r = await read(async (s) => {
      const plan = await s.getUserPlan(stackUser)
      return plan === "user_gone" ? null : plan
    })
    return r.ok ? { ok: true, paid: personalPlanPaid(r.plan) } : { ok: false, reason: "unavailable" }
  }
  if (!team || team.id !== entity || team.deleted_at !== undefined || team.kind !== "stack" || !team.stack_team) return { ok: true, paid: false }
  const stackTeam = team.stack_team
  const r = await read(async (s) => (await s.getTeam(stackTeam))?.plan ?? null)
  return r.ok ? { ok: true, paid: teamPlanPaid(r.plan) } : { ok: false, reason: "unavailable" }
}
