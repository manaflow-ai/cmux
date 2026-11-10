import { storedVmPlan } from "./cloud-vm-plan.ts"
import { listMembers, type RowsWithScan } from "./domains/team-members.ts"
import type { TeamState } from "./domains/team.ts"
import { personalTeamIdFor } from "./domains/user.ts"

/**
 * A shared team's operator Cloud grant (`cmuxVmPlan` on its sign-in service record) outlives the team
 * (ask-7b9075082b; Leo deleted a team that carried one and it was gone). The service's team.deleted
 * names only the team id and the record is gone by then, so the grant comes from TeamDO's own copy,
 * which every team sync refreshes (team-stack-sync.ts). On a confirmed delete it is recorded in the
 * single owner's personal TeamDO (storeCarriedVmPlan), whose grant read (cloud-vm-plan.ts, the read
 * CloudDO makes) answers the higher of the person's own plan and the carried grant, with an operator
 * restriction on the person still on top. The sign-in service is never written, so no concurrent
 * billing or operator write can be lost. A team without a single owner keeps the grant on record here,
 * logged for an operator, and never guessed. The outcome is recorded once; a failed record throws, so
 * the delete waits and the sync tries again.
 */
export type GrantCarryOutcome = "moved" | "no_single_owner"

export interface GrantCarryDeps {
  readonly sql: SqlStorage
  readonly state: TeamState
  readonly rows: RowsWithScan | undefined
  /** Records the grant in the personal TeamDO `personalTeam` (TeamDO.receiveCarriedVmPlan). */
  readonly carryTo: (personalTeam: string, fromTeam: string, vmPlan: string) => Promise<void>
  readonly now: number
}

const ensure = (sql: SqlStorage) =>
  sql.exec(`CREATE TABLE IF NOT EXISTS cloud_vm_plan_carried (id INTEGER PRIMARY KEY CHECK (id = 1), stack_team TEXT NOT NULL, vm_plan TEXT NOT NULL, outcome TEXT NOT NULL, owner TEXT, to_team TEXT, at INTEGER NOT NULL)`)

/** Carries the deleted team's grant once; returns what happened, or null when there is no grant to carry. */
export const carryGrantOnDelete = async (d: GrantCarryDeps, stackTeam: string): Promise<GrantCarryOutcome | null> => {
  const team = d.state.team
  if (team?.kind !== "stack" || team.deleted_at !== undefined) return null
  ensure(d.sql)
  const done = d.sql.exec<{ outcome: GrantCarryOutcome }>(`SELECT outcome FROM cloud_vm_plan_carried WHERE id = 1`).toArray()[0]
  if (done) return done.outcome
  const vmPlan = storedVmPlan(d.sql)
  if (vmPlan === undefined) console.warn(JSON.stringify({ msg: "deleted team's cloud grant was never read here; nothing to carry", team: team.id }))
  // A team-level restriction ("free", blank) restricted only that team: nothing to carry to a person.
  if (vmPlan == null || vmPlan.trim() === "" || vmPlan.trim().toLowerCase() === "free") return null
  const owners: Array<string> = []
  let after: string | undefined
  for (;;) {
    const page = listMembers(d.state, d.rows, after, 200)
    for (const m of page.items) if (m.role === "owner") owners.push(m.user)
    if (!page.next || owners.length > 1) break
    after = page.next
  }
  const owner = owners.length === 1 ? owners[0]! : null
  const to = owner === null ? null : personalTeamIdFor(owner)
  if (to !== null) await d.carryTo(to, team.id, vmPlan)
  const outcome: GrantCarryOutcome = to === null ? "no_single_owner" : "moved"
  d.sql.exec(`INSERT OR IGNORE INTO cloud_vm_plan_carried (id, stack_team, vm_plan, outcome, owner, to_team, at) VALUES (1, ?, ?, ?, ?, ?, ?)`, stackTeam, vmPlan, outcome, owner, to, d.now)
  const line = JSON.stringify({ msg: to ? "cloud grant of a deleted team carried" : "cloud grant of a deleted team not carried; an operator must assign it", team: team.id, vm_plan: vmPlan, outcome, ...(to ? { to_team: to } : {}) })
  if (to) console.log(line)
  else console.error(line)
  return outcome
}
