import { isDevice, isVm, LEASE_MS, liveStandby, MAX_STANDBY, PARKED, pendingInbox, vmHolder, type AssignmentKind, type AutoCaller, type AutoFail, type AutoMachine, type AutoRecord, type AutoRepo, type InboxState, type RefusalExtra, type Standby } from "./model.ts"

/**
 * The rules that move an Auto chat's record (DESIGN.md "Lease", "Handback", "A laptop that cannot reach the Cloud
 * stops by itself"). Every function here is pure: it takes the record, the caller's words and the time, and answers
 * the next record or a refusal. session-do.ts runs one of them inside one storage transaction and writes what it
 * answers, so no check can go stale before its write.
 *
 * The moves:
 * - A laptop's lease runs out with work waiting (`needsRun`, or a message nobody acked): the chat goes to the
 *   owner's Auto machine with a `takeover` assignment. With nothing waiting it is parked. No machine set: parked
 *   and `blocked: "no_machine"`.
 * - A machine's lease never runs out to someone else: a paused machine is not a lost one.
 * - A message for a parked chat gives it to the Auto machine.
 * - A laptop renewing on a parked chat takes it: as it is when it was the last to hold it (nobody ran it since),
 *   else by renewing as standby, the path on which it imports the Cloud copy first.
 * - A laptop renewing as standby while a machine holds the chat is remembered. When the machine releases, or renews
 *   with nothing left to run, the chat goes to that laptop unless it is kept in the Cloud. A machine that had
 *   nothing left to run and stopped renewing (it is paused) gives the chat to the standby at the standby's renewal.
 * - A chat waiting for an Auto machine, or given to one that never picked it up, goes to the machine the owner sets.
 *
 * Every move keeps one rule: the epoch grows by exactly one when the holder changes, and never otherwise
 * (test/auto-sessions-lease.test.ts walks every move to check it).
 */
export type Refuse = { readonly fail: AutoFail; readonly message: string; readonly extra?: RefusalExtra }
/** A decision: a refusal, or an answer with the record to write (`loud` when a viewer can see the change). */
export type Step<T> = Refuse | { readonly out: T; readonly rec?: AutoRecord; readonly loud?: boolean }
export type LeaseRole = "holder" | "standby" | "lost"

const refuse = (fail: AutoFail, message: string): Refuse => ({ fail, message })
const CLOSED = refuse("auto.closed", "Auto is off for this chat")

/**
 * Whether `by` may write as `holder` at `epoch` now. An owner's credential speaks for laptops only and a machine's
 * only for itself; then the epoch must be the current one and the holder the current holder.
 */
export const fence = (r: AutoRecord, by: AutoCaller, holder: string, epoch: number): Refuse | null => {
  if (!r.auto) return CLOSED
  if (by.kind === "machine" ? holder !== vmHolder(by.machine) : !isDevice(holder)) return refuse("auto.not_holder", `this caller cannot write as ${holder}`)
  if (epoch !== r.epoch) return refuse("auto.stale_epoch", `epoch ${epoch} is over; the current epoch is ${r.epoch}`)
  if (holder !== r.holder) return refuse("auto.not_holder", `the chat is held by ${r.holder}`)
  return null
}

const park = (r: AutoRecord, from: string | null): AutoRecord => ({ ...r, holder: PARKED, epoch: r.epoch + 1, parkedFrom: from, resumedEpoch: 0, assignment: null, needsRun: false, leaseExpiresAt: 0 })
/** The chat goes to a Cloud machine, which has to pick it up (`kind`) before it shows as running there. */
const assign = (r: AutoRecord, m: AutoMachine, kind: AssignmentKind): AutoRecord => ({ ...r, holder: vmHolder(m.machine), epoch: r.epoch + 1, team: m.team, machine: m.machine, assignment: kind, blocked: null, parkedFrom: null, resumedEpoch: 0, needsRun: true, leaseExpiresAt: 0 })
/** A parked chat with a message waiting goes to the Auto machine, or is marked as waiting for one. */
const settle = (r: AutoRecord, machine: AutoMachine | null): AutoRecord => {
  if (r.holder !== PARKED || !pendingInbox(r)) return r
  return machine ? assign(r, machine, "takeover") : { ...r, blocked: "no_machine" }
}

const takenBy = (r: AutoRecord, holder: string, needsRun: boolean, now: number): AutoRecord => ({
  ...r,
  holder,
  epoch: r.epoch + 1,
  needsRun,
  assignment: null,
  blocked: null,
  parkedFrom: null,
  resumedEpoch: 0,
  leaseExpiresAt: now + LEASE_MS,
  standby: r.standby.filter((s) => s.holder !== holder)
})

/** The laptop a machine's chat goes home to: the standby that renewed last, unless the chat is kept in the Cloud. */
const handbackTo = (r: AutoRecord, now: number): Standby | null =>
  r.keepInCloud ? null : liveStandby(r, now).reduce<Standby | null>((best, s) => (!best || s.expiresAt > best.expiresAt ? s : best), null)

/**
 * Whether a machine's renewal ends its hold: nothing left to run, nothing unread, its assignment acked, and its
 * newest snapshot taken after its last event, so the laptop imports everything the machine did.
 */
const idleForHandback = (r: AutoRecord): boolean => !r.needsRun && !pendingInbox(r) && r.assignment === null && r.snapshotSeq >= r.lastSeq

/** A first `PUT`: the chat as the laptop that made it holds it, epoch 1. */
export const openRecord = (id: string, owner: string, team: string | null, input: OpenInput, now: number): AutoRecord => ({
  id,
  owner,
  team,
  title: input.title,
  harness: input.harness,
  auto: true,
  keepInCloud: input.keepInCloud ?? false,
  holder: `device:${input.device}`,
  epoch: 1,
  needsRun: false,
  standby: [],
  blocked: null,
  assignment: null,
  machine: null,
  parkedFrom: null,
  resumedEpoch: 0,
  lastSeq: 0,
  snapshot: 0,
  snapshotSeq: 0,
  inbox: 0,
  inboxAcked: 0,
  repo: input.repo ?? null,
  eventBytes: 0,
  version: 1,
  createdAt: now,
  updatedAt: now,
  leaseExpiresAt: now + LEASE_MS
})
export type OpenInput = { readonly title: string; readonly harness: string; readonly device: string; readonly keepInCloud?: boolean; readonly repo?: AutoRepo | null }

/** A chat started with no laptop: the Auto machine holds it from the start and has to create it. Its first message is inbox message 1. */
export const cloudRecord = (id: string, owner: string, machine: AutoMachine, input: { readonly title: string; readonly harness: string; readonly repo: AutoRepo }, now: number): AutoRecord => ({
  ...openRecord(id, owner, machine.team, { title: input.title, harness: input.harness, device: "", repo: input.repo }, now),
  holder: vmHolder(machine.machine),
  machine: machine.machine,
  needsRun: true,
  assignment: "create",
  inbox: 1,
  leaseExpiresAt: 0
})

/** A later `PUT` with Auto on: the chat's title, harness, keep-in-Cloud and repository follow; a closed chat opens again, empty, at the next epoch. */
export const edit = (r: AutoRecord, input: OpenInput, now: number): Step<null> => {
  const named = { title: input.title, harness: input.harness, keepInCloud: input.keepInCloud ?? r.keepInCloud, repo: input.repo === undefined ? r.repo : input.repo }
  if (!r.auto) return { out: null, loud: true, rec: { ...takenBy(r, `device:${input.device}`, false, now), ...named, auto: true, keepInCloud: input.keepInCloud ?? false } }
  const same = named.title === r.title && named.harness === r.harness && named.keepInCloud === r.keepInCloud && named.repo?.remote === r.repo?.remote && named.repo?.branch === r.repo?.branch
  return same ? { out: null } : { out: null, loud: true, rec: { ...r, ...named } }
}

/**
 * Auto off: the chat closes and its Cloud copy goes. Refused while the Cloud has something no laptop has: a machine
 * holds the chat, a machine was the last to run a parked one, or a parked one has a message nobody read. A laptop
 * takes the chat first (a standby's renewal), then turns Auto off.
 */
export const close = (r: AutoRecord): Step<null> => {
  if (!r.auto) return { out: null }
  if (isVm(r.holder)) return refuse("auto.held_in_cloud", "the chat is running in the Cloud; bring it back before turning Auto off")
  if (r.holder === PARKED && (r.parkedFrom === null || pendingInbox(r))) return refuse("auto.held_in_cloud", "the Cloud has the only copy of this chat; bring it back to a laptop before turning Auto off")
  const parked = r.holder === PARKED ? r : park(r, null)
  return { out: null, loud: true, rec: { ...parked, auto: false, parkedFrom: null, standby: [], blocked: null, lastSeq: 0, snapshot: 0, snapshotSeq: 0, inboxAcked: r.inbox, eventBytes: 0 } }
}

export const keep = (r: AutoRecord, keepInCloud: boolean): Step<null> => {
  if (!r.auto) return CLOSED
  return r.keepInCloud === keepInCloud ? { out: null } : { out: null, loud: true, rec: { ...r, keepInCloud } }
}

export type RenewInput = { readonly holder: string; readonly epoch: number; readonly needsRun: boolean; readonly standby: boolean }

/**
 * `POST lease`: the holder renews, a laptop takes a parked chat, or a laptop waits as standby. The answer is a role,
 * never a stale-epoch refusal, beside the chat with its current epoch:
 * - `holder` to a renewal that is not a standby's: go on as you are, at the answer's epoch.
 * - `holder` to a standby's renewal: the chat is yours now. Import the Cloud copy, then go on at the answer's epoch.
 * - `standby`: remembered as waiting.
 * - `lost`: what you were running is not the chat any more. Stop it, then renew as a standby.
 */
export const renew = (r: AutoRecord, by: AutoCaller, input: RenewInput, now: number): Step<{ role: LeaseRole }> => {
  if (!r.auto) return CLOSED
  const { holder, epoch, needsRun } = input
  if (by.kind === "machine" ? holder !== vmHolder(by.machine) : !isDevice(holder)) return refuse("auto.not_holder", `this caller cannot renew as ${holder}`)
  if (holder === r.holder) {
    // The renewal that took a parked chat back, sent again because its answer was lost, is that renewal again.
    const current = epoch === r.epoch || (r.resumedEpoch > 0 && epoch === r.resumedEpoch)
    // The holder at an older epoch. A standby that was handed the chat learns it here, and its lease runs on while
    // it imports the Cloud copy. Anything else it still runs from that epoch may be behind what another holder did
    // since, so it is told to stop, and nothing is written.
    if (!current) return input.standby && by.kind === "owner" ? { out: { role: "holder" }, rec: { ...r, leaseExpiresAt: now + LEASE_MS } } : { out: { role: "lost" } }
    const standby = r.standby.filter((s) => s.holder !== holder)
    const next: AutoRecord = { ...r, needsRun, leaseExpiresAt: now + LEASE_MS, standby }
    const home = isVm(holder) && idleForHandback(next) ? handbackTo(next, now) : null
    if (home) return { out: { role: "lost" }, loud: true, rec: takenBy(next, home.holder, false, now) }
    return { out: { role: "holder" }, rec: next, loud: needsRun !== r.needsRun || standby.length !== r.standby.length }
  }
  // A machine that no longer holds the chat, or a laptop whose chat a machine or another laptop holds.
  if (by.kind === "machine") return { out: { role: "lost" } }
  if (r.holder === PARKED) {
    // Nobody ran the chat since this laptop's own lease ran out: it goes on as it is.
    if (!input.standby && r.parkedFrom === holder && epoch === r.epoch - 1) return { out: { role: "holder" }, loud: true, rec: { ...takenBy(r, holder, needsRun, now), resumedEpoch: epoch } }
    // A standby takes a parked chat too (it imports the Cloud copy first), unless the chat is kept in the Cloud.
    if (input.standby && !r.keepInCloud) return { out: { role: "holder" }, loud: true, rec: takenBy(r, holder, false, now) }
  }
  if (!input.standby) return { out: { role: "lost" } }
  // A machine that said it had nothing left to run, has all it did in the Cloud copy and then stopped renewing is
  // paused. It has no turn end left to hand the chat back at, so the chat goes home to this laptop now. A machine
  // at work renews, and one that is idle and awake hands the chat back at its own next renewal.
  if (isVm(r.holder) && !r.keepInCloud && r.leaseExpiresAt > 0 && r.leaseExpiresAt <= now && idleForHandback(r)) return { out: { role: "holder" }, loud: true, rec: takenBy(r, holder, false, now) }
  const live = liveStandby(r, now)
  const at = live.findIndex((s) => s.holder === holder)
  const mine: Standby = { holder, expiresAt: now + LEASE_MS }
  const standby = at >= 0 ? live.map((s, i) => (i === at ? mine : s)) : [...live, mine].slice(-MAX_STANDBY)
  return { out: { role: "standby" }, rec: { ...r, standby }, loud: at < 0 || live.length !== r.standby.length }
}

/**
 * `POST release`: a machine's chat goes home to its standby laptop, else the chat is parked. With a message still
 * unread it is not left with nobody: it goes to the Auto machine, and when the Auto machine is the one releasing,
 * the chat stays with it (same epoch) with a `deliver` to pick up, so the answer still names it as the holder.
 */
export const release = (r: AutoRecord, by: AutoCaller, holder: string, epoch: number, machine: AutoMachine | null, now: number): Step<null> => {
  const refused = fence(r, by, holder, epoch)
  if (refused) return refused
  const home = isVm(r.holder) ? handbackTo(r, now) : null
  if (home) return { out: null, loud: true, rec: takenBy(r, home.holder, false, now) }
  const unread = pendingInbox(r)
  if (unread && machine) {
    if (vmHolder(machine.machine) !== r.holder) return { out: null, loud: true, rec: assign(r, machine, "takeover") }
    return r.assignment !== null ? { out: null } : { out: null, loud: true, rec: { ...r, assignment: "deliver" } }
  }
  const parked = park(r, isDevice(r.holder) ? r.holder : null)
  return { out: null, loud: true, rec: unread ? { ...parked, blocked: "no_machine" } : parked }
}

/**
 * `POST assignment/ack`: the machine picked up what it was given, so the chat shows as running in the Cloud. While
 * a message is still unread the machine keeps a `deliver` to pick up: a message that arrived between its read of
 * the inbox and this ack is never left waiting on a machine that thinks it has nothing to do.
 */
export const ackAssignment = (r: AutoRecord, by: AutoCaller, holder: string, epoch: number, now: number): Step<null> => {
  const refused = fence(r, by, holder, epoch)
  if (refused) return refused
  const left: AssignmentKind | null = pendingInbox(r) ? "deliver" : null
  if (r.assignment === null || r.assignment === left) return { out: null, rec: { ...r, leaseExpiresAt: now + LEASE_MS } }
  return { out: null, loud: true, rec: { ...r, assignment: left, leaseExpiresAt: now + LEASE_MS } }
}

/**
 * A new inbox message (already counted in `r.inbox`): who gets it, and what the sender is told. `delivered`: a
 * holder that is running reads it; `resuming`: a machine is being started for it; `queued`: nobody can run the
 * chat until the owner has an Auto machine or a laptop comes back.
 */
export const deliver = (r: AutoRecord, machine: AutoMachine | null, now: number): { readonly rec: AutoRecord; readonly state: InboxState } => {
  if (isDevice(r.holder)) return { rec: r, state: "delivered" }
  if (isVm(r.holder)) return { rec: { ...r, assignment: r.assignment ?? "deliver" }, state: r.assignment === null && r.leaseExpiresAt > now ? "delivered" : "resuming" }
  const rec = settle(r, machine)
  return { rec, state: isVm(rec.holder) ? "resuming" : "queued" }
}

export const leaseDue = (r: AutoRecord, now: number): boolean => r.auto && isDevice(r.holder) && r.leaseExpiresAt <= now

/**
 * The alarm's move: a laptop's lease that ran out gives the chat to the Auto machine when work waits, parks it
 * otherwise; standbys that stopped renewing are dropped. Null when nothing is due.
 */
export const tick = (r: AutoRecord, machine: AutoMachine | null, now: number): AutoRecord | null => {
  let next = r
  if (leaseDue(r, now)) {
    const work = r.needsRun || pendingInbox(r)
    next = work && machine ? assign(r, machine, "takeover") : { ...park(r, r.holder), needsRun: work, blocked: work ? "no_machine" : null }
  }
  const live = liveStandby(next, now)
  if (live.length !== next.standby.length) next = { ...next, standby: live }
  return next === r ? null : next
}

/**
 * The owner set their Auto machine: a chat that was waiting for one goes to it. So does a chat given to another
 * machine that never picked it up (nothing ran there, so nothing is lost): a machine that was deleted or cannot
 * start does not keep the chat for good. Null when the chat stays as it is.
 */
export const machineSet = (r: AutoRecord, machine: AutoMachine): AutoRecord | null => {
  if (!r.auto) return null
  if (r.holder === PARKED) return r.blocked === "no_machine" ? assign(r, machine, "takeover") : null
  if (isVm(r.holder) && r.holder !== vmHolder(machine.machine) && (r.assignment === "takeover" || r.assignment === "create")) return assign(r, machine, r.assignment)
  return null
}

/** When the alarm has to look again: a laptop's lease end, or the first standby to lapse. */
export const nextDue = (r: AutoRecord): number | null => {
  const times = r.standby.map((s) => s.expiresAt)
  if (r.auto && isDevice(r.holder)) times.push(r.leaseExpiresAt)
  return times.length > 0 ? Math.min(...times) : null
}
