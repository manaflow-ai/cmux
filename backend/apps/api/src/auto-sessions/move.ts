import { assign, fence, hasCopy, laptopFor, refuse, takenBy, type Step } from "./lease.ts"
import { isDevice, isVm, PARKED, type AutoCaller, type AutoMachine, type AutoRecord, type MoveTo } from "./model.ts"

/**
 * Moving a chat by hand (DESIGN.md "Move now"): the person sends a chat to the Cloud machine or to a laptop at any
 * moment, also in the middle of a turn. Pure like the rules of lease.ts, and run the same way (one transaction in
 * session-do.ts).
 *
 * A move is two steps, because only the holder can stop its agent and store the last copy:
 *
 * - `move` (the owner) writes a wish on the record and, in the same write, whether the chat is kept in the Cloud
 *   (`true` to the Cloud, `false` to a laptop). The holder reads the wish in its lease answer and in the chat's view.
 * - `give` (the holder) hands the chat over once its copy is whole: epoch + 1, the wish gone, and the chat with the
 *   Auto machine as a `takeover`, or with the laptop, which owes an import.
 *
 * A parked chat has no holder to give it, so `move` hands it over itself. A chat that is already where it is asked
 * to go only has its wish dropped. Every other change of holder drops the wish (lease.ts), and so does the alarm
 * once the holder has not acted on it for MOVE_MS.
 */
const kept = (r: AutoRecord, keepInCloud: boolean): Step<null> => (r.move === null && r.keepInCloud === keepInCloud ? { out: null } : { out: null, loud: true, rec: { ...r, keepInCloud, move: null } })

const toCloud = (r: AutoRecord, machine: AutoMachine | null, now: number): Step<null> => {
  // A machine runs it already, whichever of the owner's machines that is.
  if (isVm(r.holder)) return kept(r, true)
  if (!machine) return refuse("auto.no_machine", "the owner has no Cloud machine to move this chat to")
  if (r.holder === PARKED) {
    // A machine imports a snapshot: without one the laptop has the only chat there is.
    if (!hasCopy(r)) return refuse("auto.not_copied", "the Cloud has no copy of this chat to start from; open it on its laptop first")
    return { out: null, loud: true, rec: { ...assign(r, machine, "takeover"), keepInCloud: true } }
  }
  // The machine is started now, so it is up when the laptop gives the chat.
  return { out: null, loud: true, rec: { ...r, keepInCloud: true, move: { to: "cloud", device: null, at: now, machine } } }
}

const toLaptop = (r: AutoRecord, device: string | null, now: number): Step<null> => {
  if (isDevice(r.holder) && (device === null || device === r.holder)) return kept(r, false)
  const target = laptopFor(r, device, now)
  if (!target) return refuse("auto.no_laptop", device === null ? "no laptop is standing by for this chat" : `${device} is not standing by for this chat`)
  // As a standby's renewal takes a parked chat (lease.ts `renew`): the laptop imports the Cloud copy first, unless
  // it is the one the chat was parked from, since nobody ran it after that.
  if (r.holder === PARKED) return { out: null, loud: true, rec: { ...takenBy(r, target.holder, false, now, r.parkedFrom !== target.holder), keepInCloud: false } }
  // A machine that holds the chat may be paused: it is started, so it reads the wish at its next renewal.
  const wake = isVm(r.holder) && r.machine !== null && r.team !== null ? { team: r.team, machine: r.machine } : null
  return { out: null, loud: true, rec: { ...r, keepInCloud: false, move: { to: "local", device, at: now, machine: wake } } }
}

/**
 * `POST move`: the person asks for the chat to run in the Cloud (`machine`: the owner's Auto machine, found by the
 * lookup a takeover uses) or on a laptop (`device`: the one named, as `device:<id>`; null: the one that stands by).
 * Asking again for a move that still waits starts its time again.
 */
export const move = (r: AutoRecord, to: MoveTo, device: string | null, machine: AutoMachine | null, now: number): Step<null> => {
  if (!r.auto) return refuse("auto.off", "this chat is not an Auto chat; set its mode before moving it")
  return to === "cloud" ? toCloud(r, machine, now) : toLaptop(r, device, now)
}

/**
 * `POST give`: the holder hands the chat over as the wish says. Fenced like every holder write. A chat never
 * changes hands ahead of its copy: the store must have a snapshot that covers the last event, so the holder stores
 * its events and its snapshot first and gives again when told `auto.not_copied`.
 */
export const give = (r: AutoRecord, by: AutoCaller, holder: string, epoch: number, machine: AutoMachine | null, now: number): Step<null> => {
  const refused = fence(r, by, holder, epoch)
  if (refused) return refused
  if (!r.move) return refuse("auto.no_move", "nobody asked to move this chat")
  if (!hasCopy(r) || r.snapshotSeq < r.lastSeq) return refuse("auto.not_copied", "the Cloud copy is behind the chat; store its events and a snapshot, then give it again")
  if (r.move.to === "cloud") return machine ? { out: null, loud: true, rec: assign(r, machine, "takeover") } : refuse("auto.no_machine", "the owner has no Cloud machine to move this chat to")
  const target = laptopFor(r, r.move.device, now)
  if (!target) return refuse("auto.no_laptop", r.move.device === null ? "no laptop is standing by for this chat" : `${r.move.device} is not standing by for this chat`)
  // What the holder stopped for the move is still to run (`needsRun` as it last said): a laptop that never renews
  // after this leaves the chat to the lease rules, which give work to the Auto machine.
  return { out: null, loud: true, rec: takenBy(r, target.holder, r.needsRun, now, true) }
}
