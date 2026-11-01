import type { TeamState } from "./domains/team.ts"
import type { StackServer } from "./stack-server.ts"

/** TeamDO answers a team's operator Cloud grant from its copy for this long, then asks the sign-in service again. */
export const VM_PLAN_FRESH_MS = 10 * 60_000

/** The grant (null = none), or unavailable: the sign-in service failed and there is no fresh copy. */
export type VmPlanAnswer = { readonly ok: true; readonly vm_plan: string | null } | { readonly ok: false }

/**
 * TeamDO.cloudVmPlan: the team's operator Cloud grant, `cmuxVmPlan` on the same sign-in service
 * record whose `cmuxPlan` inference/plan.ts reads (the owner's user record for a personal team,
 * the Stack team's record for a shared one). CloudDO maps it to machine limits (cloud-plan.ts
 * cloudPlanId); nothing here reaches the model router or billing. `stackUser` is set only for the
 * caller's own personal team, as for inferencePlan.
 */
export const cloudVmPlanOf = async (sql: SqlStorage, state: TeamState | null, entity: string, stack: StackServer | undefined, stackUser: string | undefined, now: number): Promise<VmPlanAnswer> => {
  const team = state?.team ?? null
  let read: (s: StackServer) => Promise<string | null>
  if (stackUser !== undefined) {
    // A personal team may not be mirrored here yet; the Worker checked the id is the caller's own.
    if (team && (team.id !== entity || team.kind !== "personal")) return { ok: true, vm_plan: null }
    read = async (s) => ((v) => ("gone" in v ? null : v.vm_plan))(await s.getUserVmPlan(stackUser))
  } else {
    if (!team || team.id !== entity || team.deleted_at !== undefined || team.kind !== "stack" || !team.stack_team) return { ok: true, vm_plan: null }
    const stackTeam = team.stack_team
    read = async (s) => (await s.getTeam(stackTeam))?.vm_plan ?? null
  }
  ensure(sql)
  const row = sql.exec<{ vm_plan: string | null; checked_at: number }>(`SELECT vm_plan, checked_at FROM cloud_vm_plan WHERE id = 1`).toArray()[0]
  if (row && now - Number(row.checked_at) < VM_PLAN_FRESH_MS) return { ok: true, vm_plan: row.vm_plan }
  try {
    if (!stack) throw new Error("stack server not configured")
    const vm_plan = await read(stack)
    storeVmPlan(sql, vm_plan, now)
    return { ok: true, vm_plan }
  } catch (e) {
    // A failed read keeps the last copy (as CloudDO keeps the last known plan); with none it is unavailable.
    console.warn(JSON.stringify({ msg: "cloud.vm_plan.read_failed", error: String(e).slice(0, 160), stale: Boolean(row) }))
    return row ? { ok: true, vm_plan: row.vm_plan } : { ok: false }
  }
}

const ensure = (sql: SqlStorage) => sql.exec(`CREATE TABLE IF NOT EXISTS cloud_vm_plan (id INTEGER PRIMARY KEY CHECK (id = 1), vm_plan TEXT, checked_at INTEGER NOT NULL)`)

/** Stores what the sign-in service answered at `at` (null = no grant); a read that started before a newer one never overwrites it. */
export const storeVmPlan = (sql: SqlStorage, vmPlan: string | null, at: number) => {
  ensure(sql)
  sql.exec(`INSERT INTO cloud_vm_plan (id, vm_plan, checked_at) VALUES (1, ?, ?) ON CONFLICT (id) DO UPDATE SET vm_plan = excluded.vm_plan, checked_at = excluded.checked_at WHERE excluded.checked_at >= cloud_vm_plan.checked_at`, vmPlan, at)
}
