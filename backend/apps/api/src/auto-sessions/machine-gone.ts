import { isVm, PARKED, vmHolder, type AutoRecord } from "./model.ts"

/**
 * The machine the store picked for a chat is gone (the owner deleted it, or left its team) and the owner has no
 * other there. A chat given to it and never picked up would stay with it for good: it is not `blocked`, so nothing
 * looks for a machine for it, and its start is answered `cloud.machine.not_found` until it gives up.
 *
 * So such a chat waits for a machine again: parked at the next epoch with `blocked: "no_machine"`, as a chat whose
 * owner had no machine when its lease ran out. A machine made later reaches it through the look that state opens
 * (machine-pick.ts). It is parked as the Cloud's (`parkedFrom` empty): its laptop comes back as a standby and
 * imports the copy, as it would have from the machine.
 *
 * Only a chat the machine was never heard from on (`leaseExpiresAt` still 0: no renewal, no ack of the assignment
 * or of a message), the test `machineSet` of lease.ts uses: nothing of the chat is only there. A machine that was
 * heard from keeps its chat, as it does when the owner names another. Pure like the rules of lease.ts, and run the
 * same way (one transaction in session-do.ts); it is here because only a pick is ever found gone, and a machine
 * the owner named keeps its chats whatever a read says. Null when the chat stays as it is.
 */
export const machineGone = (r: AutoRecord, machine: string): AutoRecord | null => {
  if (!r.auto || !isVm(r.holder) || r.holder !== vmHolder(machine) || r.leaseExpiresAt !== 0) return null
  if (r.assignment !== "takeover" && r.assignment !== "create") return null
  return { ...r, holder: PARKED, epoch: r.epoch + 1, assignment: null, blocked: "no_machine", parkedFrom: null, resumedEpoch: 0, needsRun: true, leaseExpiresAt: 0, owesImport: false, move: null }
}
