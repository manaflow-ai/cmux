import { storedVmPlan } from "./cloud-vm-plan.ts"
import { listMembers, type RowsWithScan } from "./domains/team-members.ts"
import type { TeamState } from "./domains/team.ts"
import { personalTeamIdFor } from "./domains/user.ts"
import type { StackServer } from "./stack-server.ts"

/**
 * A shared team's operator Cloud grant (`cmuxVmPlan` on its sign-in service record) outlives the team
 * (ask-7b9075082b; Leo deleted a team that carried one and it was gone). The service's team.deleted
 * names only the team id and the record is gone by then, so the grant comes from TeamDO's own copy,
 * which every team sync refreshes (team-stack-sync.ts). On a confirmed delete it moves to the team's
 * single owner's own record, the grant of their personal team (cloud-vm-plan.ts), unless they already
 * hold one as high or higher, or an operator restriction. Anything else is kept on record here, logged
 * for an operator, and never guessed. The outcome is recorded once; a failed write throws, so the
 * delete waits and the sync tries again.
 */
export type GrantCarryOutcome = "moved" | "kept_existing" | "no_single_owner" | "owner_unknown" | "owner_gone"

export interface GrantCarryDeps {
  readonly sql: SqlStorage
  readonly state: TeamState
  readonly rows: RowsWithScan | undefined
  readonly stack: StackServer
  /** The member's own sign-in service user id (UserDO.stackUserOf), or null when the API never saw them. */
  readonly stackUserOf: (user: string) => Promise<string | null>
  readonly now: number
}

/** Paid grants by their machine limits (domains/cloud-plan.ts PAID_PLAN_LIMITS): Plus, then Pro, Founders and Team, then Max. */
const RANK: Readonly<Record<string, number>> = { go: 1, pro: 2, founders: 2, team: 2, max: 3 }
/** A grant's rank; 0 for anything that grants no paid limits (blank, "free", unknown: a restriction). */
export const grantRank = (vmPlan: string): number => RANK[vmPlan.trim().toLowerCase()] ?? 0

const ensure = (sql: SqlStorage) =>
  sql.exec(`CREATE TABLE IF NOT EXISTS cloud_vm_plan_carried (id INTEGER PRIMARY KEY CHECK (id = 1), stack_team TEXT NOT NULL, vm_plan TEXT NOT NULL, outcome TEXT NOT NULL, owner TEXT, to_team TEXT, at INTEGER NOT NULL)`)

/** Carries the deleted team's grant once; returns what happened, or null when there is no paid grant to carry. */
export const carryGrantOnDelete = async (d: GrantCarryDeps, stackTeam: string): Promise<GrantCarryOutcome | null> => {
  const team = d.state.team
  if (team?.kind !== "stack" || team.deleted_at !== undefined) return null
  ensure(d.sql)
  const done = d.sql.exec<{ outcome: GrantCarryOutcome }>(`SELECT outcome FROM cloud_vm_plan_carried WHERE id = 1`).toArray()[0]
  if (done) return done.outcome
  const vmPlan = storedVmPlan(d.sql)
  if (vmPlan === undefined) console.warn(JSON.stringify({ msg: "deleted team's cloud grant was never read here; nothing to carry", team: team.id }))
  if (vmPlan == null || grantRank(vmPlan) === 0) return null
  const record = (outcome: GrantCarryOutcome, owner: string | null) => {
    const to = outcome === "moved" || outcome === "kept_existing" ? personalTeamIdFor(owner!) : null
    d.sql.exec(`INSERT OR IGNORE INTO cloud_vm_plan_carried (id, stack_team, vm_plan, outcome, owner, to_team, at) VALUES (1, ?, ?, ?, ?, ?, ?)`, stackTeam, vmPlan, outcome, owner, to, d.now)
    const line = JSON.stringify({ msg: outcome === "moved" || outcome === "kept_existing" ? "cloud grant of a deleted team carried" : "cloud grant of a deleted team not carried; an operator must assign it", team: team.id, vm_plan: vmPlan, outcome, ...(to ? { to_team: to } : {}) })
    if (to) console.log(line)
    else console.error(line)
    return outcome
  }
  const owners: Array<string> = []
  let after: string | undefined
  for (;;) {
    const page = listMembers(d.state, d.rows, after, 200)
    for (const m of page.items) if (m.role === "owner") owners.push(m.user)
    if (!page.next || owners.length > 1) break
    after = page.next
  }
  if (owners.length !== 1) return record("no_single_owner", null)
  const owner = owners[0]!
  const stackUser = await d.stackUserOf(owner)
  if (!stackUser) return record("owner_unknown", owner)
  const current = await d.stack.getUserVmPlan(stackUser)
  if ("gone" in current) return record("owner_gone", owner)
  // An operator restriction on the person stays theirs to lift.
  if (current.vm_plan !== null && grantRank(current.vm_plan) === 0) return record("kept_existing", owner)
  const paid = await d.stack.getUserPlan(stackUser)
  if (paid === "user_gone") return record("owner_gone", owner)
  // The person's effective plan is their paid cmuxPlan or their override, whichever is higher (review F1): an override
  // below a paid plan would lower them (domains/cloud-plan.ts cloudPlanId lets cmuxVmPlan win), so the team's grant
  // is written only when it is higher than both.
  const own = Math.max(paid === null ? 0 : grantRank(paid), current.vm_plan === null ? 0 : grantRank(current.vm_plan))
  if (own >= grantRank(vmPlan)) return record("kept_existing", owner)
  if ((await d.stack.setUserVmPlan(stackUser, vmPlan)) === "user_gone") return record("owner_gone", owner)
  // Done only when a read-back shows the grant (review F2); otherwise the delete waits and this decides again.
  const back = await d.stack.getUserVmPlan(stackUser)
  if ("gone" in back) return record("owner_gone", owner)
  if (back.vm_plan !== vmPlan) throw new Error("cloud grant carry: read-back shows another cmuxVmPlan; retrying")
  return record("moved", owner)
}
