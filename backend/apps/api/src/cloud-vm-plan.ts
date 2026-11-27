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
  // undefined = the team is gone at the sign-in service: the last copy stands (a delete carries it, team-grant-carry.ts).
  let read: (s: StackServer) => Promise<string | null | undefined>
  if (stackUser !== undefined) {
    // A personal team may not be mirrored here yet; the Worker checked the id is the caller's own.
    if (team && (team.id !== entity || team.kind !== "personal")) return { ok: true, vm_plan: null }
    read = async (s) => {
      const v = await s.getUserVmPlan(stackUser)
      const own = "gone" in v ? null : v.vm_plan
      // A grant carried here from a deleted shared team (team-grant-carry.ts) is compared, never written to the record.
      const carried = carriedVmPlan(sql)
      if (carried === null || (own !== null && grantRank(own) === 0)) return own
      // An override the carried grant cannot exceed is the answer: no paid-plan read, so its failure can't lose it (review F2).
      if (own !== null && grantRank(own) >= grantRank(carried)) return own
      let paid: string | null | "user_gone"
      try {
        paid = await s.getUserPlan(stackUser)
      } catch (e) {
        // The override was read and is confirmed; only the paid plan is unknown (review F2 at f2d36575). The answer is
        // the higher of that override and the last answer (the carried grant may still apply), never unavailable.
        if (own === null) throw e
        console.warn(JSON.stringify({ msg: "cloud.vm_plan.paid_read_failed", error: String(e).slice(0, 160), stale: Boolean(row) }))
        throw new OverrideOnly(own)
      }
      return higherGrant(own, paid === "user_gone" ? null : paid, carried)
    }
  } else {
    if (!team || team.id !== entity || team.deleted_at !== undefined || team.kind !== "stack" || !team.stack_team) return { ok: true, vm_plan: null }
    const stackTeam = team.stack_team
    // The one shared-team read (readStackTeam): it stores the grant copy under this read's ticket itself.
    read = async (s) => {
      const t = await readStackTeam(sql, s, stackTeam, now, seen)
      return t === null ? undefined : (t.vm_plan ?? null)
    }
  }
  ensure(sql)
  const row = sql.exec<{ vm_plan: string | null; checked_at: number }>(`SELECT vm_plan, checked_at FROM cloud_vm_plan WHERE id = 1`).toArray()[0]
  // A person holding a carried grant is read fresh every time (review F2 at 28f85c71): the answer depends on their
  // paid plan, and a cached comparison would hide a paid upgrade (cloudPlanId("max", "go") is go). Only such people
  // pay the extra reads; the cached copy stays the answer when the service fails.
  const carrying = stackUser !== undefined && carriedVmPlan(sql) !== null
  if (row && !carrying && now - Number(row.checked_at) < VM_PLAN_FRESH_MS) return { ok: true, vm_plan: row.vm_plan }
  const seen = stackUser === undefined ? nextReadTicket(sql) : undefined
  try {
    if (!stack) throw new Error("stack server not configured")
    const vm_plan = await read(stack)
    // TEAM_NOT_FOUND before the delete event is processed (review F3): keep the snapshot, never overwrite it with null.
    if (vm_plan === undefined) return { ok: true, vm_plan: row ? row.vm_plan : null }
    storeVmPlan(sql, vm_plan, now, seen)
    return { ok: true, vm_plan }
  } catch (e) {
    if (e instanceof OverrideOnly) {
      // Not stored: the next read compares the paid plan again.
      const last = row?.vm_plan ?? null
      return { ok: true, vm_plan: last !== null && grantRank(last) > grantRank(e.own) ? last : e.own }
    }
    // A failed read keeps the last copy (as CloudDO keeps the last known plan); with none it is unavailable.
    console.warn(JSON.stringify({ msg: "cloud.vm_plan.read_failed", error: String(e).slice(0, 160), stale: Boolean(row) }))
    return row ? { ok: true, vm_plan: row.vm_plan } : { ok: false }
  }
}

/** A personal grant read whose override was read but whose paid-plan read failed: the override is still an answer. */
class OverrideOnly extends Error {
  constructor(readonly own: string) {
    super("paid plan read failed")
  }
}

/**
 * The one read of a shared team's sign-in service record, for every caller that reads it (the grant read here, the
 * model router's plan read in inference/plan.ts, every team sync in team-stack-sync.ts). The grant it sees is stored
 * at once under a read ticket taken before the read (review F1 at f2d36575: a plan refresh saw an upgrade that the
 * grant copy, and so a delete's carry, never did). `ticket` is the caller's own when it already took one.
 */
export const readStackTeam = async (sql: SqlStorage, stack: StackServer, stackTeam: string, at: number, ticket: number = nextReadTicket(sql)) => {
  const team = await stack.getTeam(stackTeam)
  if (team !== null && team.vm_personal_tenant !== true && team.vm_plan !== undefined) storeVmPlan(sql, team.vm_plan, at, ticket)
  return team
}

const tableReady = new WeakSet<SqlStorage>()
const ensure = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS cloud_vm_plan (id INTEGER PRIMARY KEY CHECK (id = 1), vm_plan TEXT, checked_at INTEGER NOT NULL)`)
  if (tableReady.has(sql)) return
  // The read ticket (grantTicket) of the read the copy came from; 0 for a copy from before tickets.
  if (!sql.exec<{ name: string }>(`PRAGMA table_info(cloud_vm_plan)`).toArray().some((c) => c.name === "ticket")) sql.exec(`ALTER TABLE cloud_vm_plan ADD COLUMN ticket INTEGER NOT NULL DEFAULT 0`)
  tableReady.add(sql)
}

/**
 * One strictly increasing counter per team (durable, never a clock), shared by the two things the grant carry
 * orders (team-grant-carry.ts): a team event's arrival, and the start of a read of the team. `last_event` is the
 * ticket of the latest event; `confirmed` is the ticket of the latest read after which every event was reconciled
 * successfully (the owner and the grant both read and committed: team-stack-sync.ts runRow). A fact is only as new
 * as the ticket of the read that saw it, so two reads in the same millisecond still order.
 */
const ensureSeq = (sql: SqlStorage) => sql.exec(`CREATE TABLE IF NOT EXISTS cloud_vm_plan_ticket (id INTEGER PRIMARY KEY CHECK (id = 1), seq INTEGER NOT NULL, last_event INTEGER NOT NULL, confirmed INTEGER NOT NULL)`)
const ticketRow = (sql: SqlStorage) => {
  ensureSeq(sql)
  return sql.exec<{ seq: number; last_event: number; confirmed: number }>(`SELECT seq, last_event, confirmed FROM cloud_vm_plan_ticket WHERE id = 1`).toArray()[0] ?? { seq: 0, last_event: 0, confirmed: 0 }
}
const writeTickets = (sql: SqlStorage, r: { seq: number; last_event: number; confirmed: number }) =>
  sql.exec(`INSERT INTO cloud_vm_plan_ticket (id, seq, last_event, confirmed) VALUES (1, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET seq = excluded.seq, last_event = excluded.last_event, confirmed = excluded.confirmed`, r.seq, r.last_event, r.confirmed)

/** A read of the team starts: its ticket, greater than every event and read before it. */
export const nextReadTicket = (sql: SqlStorage): number => {
  const r = ticketRow(sql)
  writeTickets(sql, { ...r, seq: r.seq + 1 })
  return r.seq + 1
}
/** A team event (not a delete) arrived: the team's grant, owner or members may have changed since every earlier read. */
export const noteTeamEvent = (sql: SqlStorage): number => {
  const r = ticketRow(sql)
  writeTickets(sql, { ...r, seq: r.seq + 1, last_event: r.seq + 1 })
  return r.seq + 1
}
/** Every event up to the read `ticket` started was reconciled successfully by that read's run (team-stack-sync.ts). */
export const confirmTeamFacts = (sql: SqlStorage, ticket: number) => {
  const r = ticketRow(sql)
  if (ticket > r.confirmed) writeTickets(sql, { ...r, confirmed: ticket })
}
/**
 * The local owner and the grant copy both come from reads that started after the latest event: a fully reconciled
 * read confirmed the owner, and the grant copy is from that read or a later one. Otherwise a carry would be decided
 * from a fact that may be stale (a revocation, a downgrade or an ownership change not read yet).
 */
export const teamFactsCurrent = (sql: SqlStorage): boolean => {
  const r = ticketRow(sql)
  ensure(sql)
  const grant = sql.exec<{ ticket: number }>(`SELECT ticket FROM cloud_vm_plan WHERE id = 1`).toArray()[0]?.ticket ?? 0
  return r.confirmed > r.last_event && grant > r.last_event && grant >= r.confirmed
}

/**
 * Stores what the sign-in service answered (null = no grant). With `ticket` (a shared team's read, nextReadTicket),
 * the answer applies only when its read started after the read of the current copy: strictly greater, so an older
 * read finishing last never restores what a newer read replaced. Without one (a personal team's cache), the time rule.
 */
export const storeVmPlan = (sql: SqlStorage, vmPlan: string | null, at: number, ticket?: number) => {
  ensure(sql)
  if (ticket === undefined) {
    sql.exec(`INSERT INTO cloud_vm_plan (id, vm_plan, checked_at) VALUES (1, ?, ?) ON CONFLICT (id) DO UPDATE SET vm_plan = excluded.vm_plan, checked_at = excluded.checked_at WHERE excluded.checked_at >= cloud_vm_plan.checked_at`, vmPlan, at)
    return
  }
  sql.exec(`INSERT INTO cloud_vm_plan (id, vm_plan, checked_at, ticket) VALUES (1, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET vm_plan = excluded.vm_plan, checked_at = excluded.checked_at, ticket = excluded.ticket WHERE excluded.ticket > cloud_vm_plan.ticket`, vmPlan, at, ticket)
}

/** TeamDO's last copy of the team's grant: the grant (null = none), or undefined when it was never read here. */
export const storedVmPlan = (sql: SqlStorage): string | null | undefined => {
  ensure(sql)
  const row = sql.exec<{ vm_plan: string | null }>(`SELECT vm_plan FROM cloud_vm_plan WHERE id = 1`).toArray()[0]
  return row ? row.vm_plan : undefined
}

/** Paid grants by their machine limits (domains/cloud-plan.ts PAID_PLAN_LIMITS): Plus, then Pro, Founders and Team, then Max. */
const RANK: Readonly<Record<string, number>> = { go: 1, pro: 2, founders: 2, team: 2, max: 3 }
/** A grant's rank; 0 for anything that grants no paid limits (blank, "free", unknown: a restriction when set). */
export const grantRank = (vmPlan: string): number => RANK[vmPlan.trim().toLowerCase()] ?? 0

/**
 * The person's grant read with a carried grant: their own override when it is a restriction (an operator's
 * "free" or blank still wins), else the carried grant only when it is higher than both their paid cmuxPlan and
 * their override (CloudDO's cloudPlanId lets the answer win over cmuxPlan, so a lower one would lower them),
 * else their own override unchanged.
 */
export const higherGrant = (own: string | null, paid: string | null, carried: string | null): string | null => {
  if (carried === null || (own !== null && grantRank(own) === 0)) return own
  const mine = Math.max(paid === null ? 0 : grantRank(paid), own === null ? 0 : grantRank(own))
  return grantRank(carried) > mine ? carried : own
}

const ensureCarried = (sql: SqlStorage) => sql.exec(`CREATE TABLE IF NOT EXISTS cloud_vm_plan_carried_in (from_team TEXT PRIMARY KEY, vm_plan TEXT NOT NULL, at INTEGER NOT NULL)`)

/** The highest grant carried into this personal team from deleted shared teams, or null. */
export const carriedVmPlan = (sql: SqlStorage): string | null => {
  ensureCarried(sql)
  let best: string | null = null
  for (const r of sql.exec<{ vm_plan: string }>(`SELECT vm_plan FROM cloud_vm_plan_carried_in`).toArray()) if (best === null || grantRank(r.vm_plan) > grantRank(best)) best = r.vm_plan
  return best
}

/** Records a deleted team's grant in its owner's personal TeamDO (once per team) and drops the cached answer, so the next read compares it. */
export const storeCarriedVmPlan = (sql: SqlStorage, fromTeam: string, vmPlan: string, at: number) => {
  ensureCarried(sql)
  sql.exec(`INSERT OR IGNORE INTO cloud_vm_plan_carried_in (from_team, vm_plan, at) VALUES (?, ?, ?)`, fromTeam, vmPlan, at)
  ensure(sql)
  sql.exec(`DELETE FROM cloud_vm_plan`)
}
