import { grantRank, storedVmPlan, teamFactsCurrent } from "./cloud-vm-plan.ts"
import { listMembers, type RowsWithScan } from "./domains/team-members.ts"
import type { TeamState } from "./domains/team.ts"
import { personalTeamIdFor } from "./domains/user.ts"

/**
 * A shared team's operator Cloud grant (`cmuxVmPlan` on its sign-in service record) outlives the team
 * (ask-7b9075082b; Leo deleted a team that carried one and it was gone). The service's team.deleted
 * names only the team id and the record is gone by then, so the grant comes from TeamDO's own copy,
 * which every team sync refreshes (team-stack-sync.ts). On a confirmed delete the transfer is first
 * recorded here, durably, as pending (planCarryOnDelete); the tombstone commits right after, so the
 * members' access ends whatever happens to the transfer. The pending transfer is then delivered to the
 * single owner's personal TeamDO (deliverPendingCarry), now and from the alarm with backoff until it
 * lands; a failed delivery never blocks or undoes the delete. That TeamDO's grant read (cloud-vm-plan.ts,
 * the read CloudDO makes) answers the higher of the person's own plan and the carried grant, with an
 * operator restriction on the person still on top. The sign-in service is never written. A team without
 * a single owner keeps the grant on record here, logged for an operator, and never guessed.
 */
export type GrantCarryOutcome = "pending" | "moved" | "no_single_owner" | "unverified"

export interface GrantCarryDeps {
  readonly sql: SqlStorage
  readonly state: TeamState
  readonly rows: RowsWithScan | undefined
  /** Records the grant in the personal TeamDO `personalTeam` (TeamDO.receiveCarriedVmPlan). */
  readonly carryTo: (personalTeam: string, fromTeam: string, vmPlan: string) => Promise<void>
  readonly now: number
}

/** A failed delivery waits 1 min doubling to 1 h (no cap on tries: the grant is kept until it lands). */
const CARRY_BACKOFF_MS = { first: 60_000, max: 60 * 60_000 } as const
const backoffMs = (fails: number) => Math.min(CARRY_BACKOFF_MS.max, CARRY_BACKOFF_MS.first * 2 ** Math.max(0, fails - 1))

type CarryRow = { stack_team: string; vm_plan: string; outcome: GrantCarryOutcome; owner: string | null; to_team: string | null; due_at: number; fails: number }

const migrated = new WeakSet<SqlStorage>()
const ensure = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS cloud_vm_plan_carried (id INTEGER PRIMARY KEY CHECK (id = 1), stack_team TEXT NOT NULL, vm_plan TEXT NOT NULL, outcome TEXT NOT NULL, owner TEXT, to_team TEXT, at INTEGER NOT NULL)`)
  if (migrated.has(sql)) return
  const have = new Set(sql.exec<{ name: string }>(`PRAGMA table_info(cloud_vm_plan_carried)`).toArray().map((c) => c.name))
  for (const c of ["due_at", "fails"]) if (!have.has(c)) sql.exec(`ALTER TABLE cloud_vm_plan_carried ADD COLUMN ${c} INTEGER NOT NULL DEFAULT 0`)
  migrated.add(sql)
}
const readCarry = (sql: SqlStorage): CarryRow | undefined => {
  ensure(sql)
  return sql.exec<CarryRow>(`SELECT stack_team, vm_plan, outcome, owner, to_team, due_at, fails FROM cloud_vm_plan_carried WHERE id = 1`).toArray()[0]
}

/**
 * Before the tombstone (synchronous, no remote call): records the deleted team's grant transfer once, as
 * pending for its single owner or no_single_owner. Returns the outcome, or null when there is nothing to carry.
 */
export const planCarryOnDelete = (d: Omit<GrantCarryDeps, "carryTo">, stackTeam: string): GrantCarryOutcome | null => {
  const team = d.state.team
  if (team?.kind !== "stack" || team.deleted_at !== undefined) return null
  const done = readCarry(d.sql)
  if (done) return done.outcome
  const vmPlan = storedVmPlan(d.sql)
  if (vmPlan === undefined) console.warn(JSON.stringify({ msg: "deleted team's cloud grant was never read here; nothing to carry", team: team.id }))
  // A team-level restriction ("free", blank) or a value with no paid limits restricted only that team: nothing to carry.
  if (vmPlan == null || grantRank(vmPlan) === 0) return null
  // The owner and the grant must both be confirmed by reads after the latest team event (cloud-vm-plan.ts tickets): an
  // event not reconciled yet may be a revocation, a downgrade or an ownership change, and the record is gone now, so
  // nothing can confirm it any more. Nothing is carried; an operator decides. The delete itself proceeds as always.
  if (!teamFactsCurrent(d.sql)) {
    d.sql.exec(`INSERT OR IGNORE INTO cloud_vm_plan_carried (id, stack_team, vm_plan, outcome, owner, to_team, at, due_at, fails) VALUES (1, ?, ?, 'unverified', NULL, NULL, ?, ?, 0)`, stackTeam, vmPlan, d.now, d.now)
    console.error(JSON.stringify({ msg: "cloud grant of a deleted team not carried: its owner or grant was not confirmed after the latest team event; an operator must assign it", team: team.id, vm_plan: vmPlan, outcome: "unverified" }))
    return "unverified"
  }
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
  const outcome: GrantCarryOutcome = to === null ? "no_single_owner" : "pending"
  d.sql.exec(`INSERT OR IGNORE INTO cloud_vm_plan_carried (id, stack_team, vm_plan, outcome, owner, to_team, at, due_at, fails) VALUES (1, ?, ?, ?, ?, ?, ?, ?, 0)`, stackTeam, vmPlan, outcome, owner, to, d.now, d.now)
  if (to === null) console.error(JSON.stringify({ msg: "cloud grant of a deleted team not carried; an operator must assign it", team: team.id, vm_plan: vmPlan, outcome }))
  return outcome
}

/** When a pending transfer is due next, or null when there is none. */
export const pendingCarryAt = (sql: SqlStorage): number | null => {
  const row = readCarry(sql)
  return row?.outcome === "pending" ? row.due_at : null
}

/**
 * After the tombstone: delivers a due pending transfer to the owner's personal TeamDO. Never throws: a
 * failure is logged and waits with backoff (the alarm tries again), and the delete stays as committed.
 */
export const deliverPendingCarry = async (d: GrantCarryDeps, team: string): Promise<GrantCarryOutcome | null> => {
  const row = readCarry(d.sql)
  if (!row || row.outcome !== "pending" || row.to_team === null) return row?.outcome ?? null
  if (row.due_at > d.now) return "pending"
  try {
    await d.carryTo(row.to_team, team, row.vm_plan)
  } catch (e) {
    const fails = row.fails + 1
    d.sql.exec(`UPDATE cloud_vm_plan_carried SET fails = ?, due_at = ? WHERE id = 1 AND outcome = 'pending'`, fails, d.now + backoffMs(fails))
    console.error(JSON.stringify({ msg: "cloud grant carry to the owner's personal team failed; retrying", team, fails, error: String(e).slice(0, 160) }))
    return "pending"
  }
  d.sql.exec(`UPDATE cloud_vm_plan_carried SET outcome = 'moved' WHERE id = 1 AND outcome = 'pending'`)
  console.log(JSON.stringify({ msg: "cloud grant of a deleted team carried", team, vm_plan: row.vm_plan, outcome: "moved", to_team: row.to_team }))
  return "moved"
}
