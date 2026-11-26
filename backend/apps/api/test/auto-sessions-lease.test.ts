import { describe, expect, it } from "vitest"
import { ackAssignment, ackedInbox, close, deliver, edit, fence, keep, machineSet, openRecord, release, renew, tick, type Step } from "../src/auto-sessions/lease.ts"
import { isDevice, isVm, LEASE_MS, MOVE_MS, PARKED, stateOf, type AutoCaller, type AutoMachine, type AutoRecord } from "../src/auto-sessions/model.ts"
import { give, move as moveNow } from "../src/auto-sessions/move.ts"

/** The pure rules of an Auto chat's lease (src/auto-sessions/lease.ts): no storage, no clock but the one passed in. */
const OWNER = "user_1"
const MACHINE: AutoMachine = { team: "team_1", machine: "vm_1" }
const OTHER: AutoMachine = { team: "team_1", machine: "vm_2" }
const VM = "vm:vm_1"
const A = "device:a"
const B = "device:b"
const owner: AutoCaller = { kind: "owner", owner: OWNER }
const machine: AutoCaller = { kind: "machine", owner: OWNER, machine: MACHINE.machine }
const fresh = (now = 0): AutoRecord => openRecord("chat", OWNER, "team_1", { title: "t", harness: "claude", device: "a" }, now)
const next = <T>(r: AutoRecord, step: Step<T>): AutoRecord => ("fail" in step ? r : (step.rec ?? r))

describe("auto sessions: the lease rules", () => {
  it("whatever happens to a chat, its epoch grows by exactly one when its holder changes and never otherwise", () => {
    // A fixed pseudo-random walk over every move, so a failure repeats.
    let seed = 20261122
    const rand = (n: number) => {
      // The high bits: the low bits of this generator repeat after a few draws.
      seed = (Math.imul(seed, 1103515245) + 12345) & 0x7fffffff
      return (seed >>> 16) % n
    }
    const pick = <T>(items: ReadonlyArray<T>): T => items[rand(items.length)]!
    let r = fresh()
    let now = 0
    const seen = new Set<string>()
    for (let i = 0; i < 6000; i++) {
      const before = r
      const has: AutoMachine | null = rand(8) === 0 ? null : MACHINE
      const epoch = r.epoch - rand(3)
      const move = rand(14)
      now += pick([0, 1_000, 10_000, 50_000])
      if (move === 0) r = next(r, renew(r, owner, { holder: pick([A, B]), epoch, needsRun: rand(2) === 0, standby: rand(2) === 0 }, now))
      else if (move === 1) r = next(r, renew(r, machine, { holder: VM, epoch, needsRun: rand(2) === 0, standby: false }, now))
      else if (move === 2) r = next(r, release(r, r.holder === VM ? machine : owner, r.holder === PARKED ? A : r.holder, epoch, has, now))
      else if (move === 3) r = next(r, ackAssignment(r, machine, VM, epoch, now))
      else if (move === 4) r = r.auto ? deliver({ ...r, inbox: r.inbox + 1 }, has, now).rec : r
      else if (move === 5) r = fence(r, r.holder === VM ? machine : owner, r.holder, r.epoch) ? r : (ackedInbox(r, r.inbox, now) ?? r)
      else if (move === 6) r = tick(r, has, now) ?? r
      else if (move === 7) r = next(r, keep(r, rand(2) === 0))
      else if (move === 8) r = rand(6) === 0 ? next(r, close(r)) : r
      else if (move === 9) r = next(r, edit(r, { title: "t", harness: "claude", device: pick(["a", "b"]) }, now))
      else if (move === 10) r = machineSet(r, rand(4) === 0 ? OTHER : MACHINE) ?? r
      // The person moves the chat by hand, and its holder gives it.
      else if (move === 12) r = next(r, moveNow(r, pick(["cloud", "local"] as const), rand(3) === 0 ? pick([A, B]) : null, has, now))
      else if (move === 13) r = next(r, give(r, r.holder === VM ? machine : owner, r.holder === PARKED ? A : r.holder, epoch, has, now))
      else if (!fence(r, r.holder === VM ? machine : owner, r.holder, r.epoch)) {
        // An event, and half the time the snapshot that covers it.
        const stored = rand(2) === 0
        r = { ...r, lastSeq: r.lastSeq + 1, snapshotSeq: stored ? r.lastSeq + 1 : r.snapshotSeq, snapshot: stored ? r.snapshot + 1 : r.snapshot, owesImport: stored ? false : r.owesImport }
      }
      expect(r.epoch - before.epoch, `move ${move} at step ${i}: ${before.holder} -> ${r.holder}`).toBe(r.holder === before.holder ? 0 : 1)
      // Only a machine has something to pick up, and only a parked chat waits for a machine.
      if (r.assignment !== null) expect(isVm(r.holder)).toBe(true)
      if (r.blocked !== null) expect(r.holder).toBe(PARKED)
      if (r.holder === PARKED) expect(r.leaseExpiresAt).toBe(0)
      // Only a laptop owes an import, and Auto off never closes a chat whose holder owes one.
      if (r.owesImport) expect(r.auto && r.holder !== PARKED && !isVm(r.holder)).toBe(true)
      // A wish waits on a holder: a parked chat has none, only a laptop is asked to give to the Cloud, and a wish
      // never outlives the change of holder it asked for or any other.
      if (r.move) expect(r.auto && r.holder !== PARKED && (r.move.to === "local" || isDevice(r.holder))).toBe(true)
      if (r.move && r.holder !== before.holder) throw new Error(`move ${move} at step ${i} changed the holder and kept the wish`)
      seen.add(`${r.holder === PARKED ? "parked" : isVm(r.holder) ? "vm" : "device"}:${stateOf(r, now)}`)
    }
    // The walk reached every kind of holder and every state a client can show.
    expect([...seen].sort()).toEqual(["device:local", "parked:parked", "vm:cloud", "vm:coming_back", "vm:resuming"])
  })

  it("a lease that runs out goes to the machine only when work waits, and a machine's never runs out", () => {
    const idle = tick(fresh(), MACHINE, LEASE_MS)!
    expect([idle.holder, idle.epoch, idle.assignment, idle.blocked]).toEqual([PARKED, 2, null, null])
    const busy = tick({ ...fresh(), needsRun: true }, MACHINE, LEASE_MS)!
    expect([busy.holder, busy.epoch, busy.assignment, busy.machine, busy.team]).toEqual([VM, 2, "takeover", "vm_1", "team_1"])
    // A message nobody took is work too, once the store has a snapshot a machine can start from: it must not be
    // left in a parked chat.
    expect(tick({ ...fresh(), inbox: 1, snapshot: 1 }, MACHINE, LEASE_MS)!.holder).toBe(VM)
    // Before the first snapshot the laptop has the only chat there is: parked and not blocked, the message waits
    // for that laptop, and no machine is given a chat it cannot import.
    const early = tick({ ...fresh(), inbox: 1 }, MACHINE, LEASE_MS)!
    expect([early.holder, early.epoch, early.blocked, early.needsRun, early.parkedFrom]).toEqual([PARKED, 2, null, false, A])
    expect(deliver({ ...early, inbox: 2 }, MACHINE, LEASE_MS)).toMatchObject({ state: "queued", rec: { holder: PARKED, epoch: 2 } })
    expect(machineSet(early, MACHINE)).toBeNull()
    expect(renew(early, owner, { holder: A, epoch: 1, needsRun: false, standby: false }, LEASE_MS + 1)).toMatchObject({ out: { role: "holder" }, rec: { holder: A, epoch: 3, inbox: 1, inboxAcked: 0 } })
    expect(release({ ...fresh(), inbox: 1 }, owner, A, 1, MACHINE, 1)).toMatchObject({ rec: { holder: PARKED, epoch: 2, blocked: null, parkedFrom: A } })
    expect(release({ ...fresh(), inbox: 1, snapshot: 1 }, owner, A, 1, MACHINE, 1)).toMatchObject({ rec: { holder: VM, epoch: 2, assignment: "takeover" } })
    const blocked = tick({ ...fresh(), needsRun: true }, null, LEASE_MS)!
    expect([blocked.holder, blocked.epoch, blocked.blocked, blocked.needsRun]).toEqual([PARKED, 2, "no_machine", true])
    expect(machineSet(blocked, MACHINE)).toMatchObject({ holder: VM, epoch: 3, assignment: "takeover", blocked: null })
    expect(machineSet(idle, MACHINE)).toBeNull()
    expect(tick(fresh(), MACHINE, LEASE_MS - 1)).toBeNull()
    expect(tick(busy, MACHINE, 10 * LEASE_MS)).toBeNull()
    // A chat given to a machine that never picked it up goes to the machine the owner sets next; one a machine
    // picked up stays with it.
    expect(machineSet(busy, OTHER)).toMatchObject({ holder: "vm:vm_2", epoch: 3, assignment: "takeover", machine: "vm_2", needsRun: true })
    expect(machineSet({ ...busy, assignment: "create" }, OTHER)).toMatchObject({ holder: "vm:vm_2", epoch: 3, assignment: "create" })
    // A machine that was heard from since (a renewal, or a message it acked into its own log) keeps the chat:
    // moving it would give the next machine an inbox without that message.
    expect(machineSet({ ...busy, leaseExpiresAt: LEASE_MS }, OTHER)).toBeNull()
    const took = ackedInbox({ ...busy, inbox: 1 }, 1, 7)!
    expect([took.inboxAcked, took.leaseExpiresAt]).toEqual([1, 7 + LEASE_MS])
    expect(machineSet(took, OTHER)).toBeNull()
    expect(ackedInbox(took, 1, 9)).toBeNull()
    // A laptop's ack moves no lease, and an ack past the newest message is one of the newest.
    expect(ackedInbox({ ...fresh(), inbox: 2 }, 9, 7)).toMatchObject({ inboxAcked: 2, leaseExpiresAt: LEASE_MS })
    expect(machineSet(busy, MACHINE)).toBeNull()
    expect(machineSet({ ...busy, assignment: null }, OTHER)).toBeNull()
    expect(machineSet({ ...busy, assignment: "deliver" }, OTHER)).toBeNull()
  })

  it("a laptop given the chat owes an import until its own snapshot; Auto off waits, and its lapsed lease parks the chat as the Cloud's", () => {
    const held: AutoRecord = { ...fresh(), holder: VM, epoch: 2, machine: "vm_1", lastSeq: 5, snapshotSeq: 5, leaseExpiresAt: 50_000, standby: [{ holder: A, expiresAt: 60_000 }] }
    const handed = renew(held, machine, { holder: VM, epoch: 2, needsRun: false, standby: false }, 1_000)
    if ("fail" in handed || !handed.rec) throw new Error("the machine's idle renewal hands the chat back")
    const home = handed.rec
    expect(home).toMatchObject({ holder: A, epoch: 3, owesImport: true })
    expect(close(home)).toMatchObject({ fail: "auto.held_in_cloud" })
    expect(close({ ...home, owesImport: false })).toMatchObject({ rec: { auto: false } })
    expect(release(held, machine, VM, 2, MACHINE, 1_000)).toMatchObject({ rec: { holder: A, epoch: 3, owesImport: true } })
    // Its lease runs out before the import: parked as the Cloud's, so only a standby's renewal takes it, owing again.
    const lapsed = tick(home, MACHINE, 1_000 + LEASE_MS)!
    expect(lapsed).toMatchObject({ holder: PARKED, epoch: 4, parkedFrom: null, owesImport: false })
    expect(close(lapsed)).toMatchObject({ fail: "auto.held_in_cloud" })
    expect(renew(lapsed, owner, { holder: A, epoch: 3, needsRun: false, standby: false }, 60_000)).toMatchObject({ out: { role: "lost" } })
    expect(renew(lapsed, owner, { holder: A, epoch: 3, needsRun: false, standby: true }, 60_000)).toMatchObject({ out: { role: "holder" }, rec: { holder: A, epoch: 5, owesImport: true } })
    // A laptop that takes its own parked chat back as a standby has it already.
    const own = tick(fresh(), MACHINE, LEASE_MS)!
    expect(renew(own, owner, { holder: A, epoch: 1, needsRun: false, standby: true }, LEASE_MS + 1)).toMatchObject({ out: { role: "holder" }, rec: { holder: A, epoch: 3, owesImport: false } })
    // A machine never owes one, and a PUT from the holder moves the lease and nothing a viewer sees.
    expect(tick({ ...fresh(), needsRun: true }, MACHINE, LEASE_MS)).toMatchObject({ holder: VM, owesImport: false })
    expect(edit(fresh(), { title: "t", harness: "claude", device: "a" }, 30_000)).toMatchObject({ loud: false, rec: { leaseExpiresAt: 30_000 + LEASE_MS, epoch: 1, version: 1 } })
    expect(edit(fresh(), { title: "t", harness: "claude", device: "b" }, 30_000)).toEqual({ out: null })
  })

  it("Auto off is refused while the Cloud has what no laptop has", () => {
    const parked = tick(fresh(), MACHINE, LEASE_MS)!
    // Parked from its own laptop, which still has the chat: it closes.
    expect(close(parked)).toMatchObject({ rec: { auto: false, holder: PARKED, epoch: 2 } })
    expect(close({ ...fresh(), inbox: 1 })).toMatchObject({ rec: { auto: false, holder: PARKED, epoch: 2 } })
    // A machine was the last to run it, or a message waits that nobody read.
    expect(close({ ...parked, parkedFrom: null })).toMatchObject({ fail: "auto.held_in_cloud" })
    expect(close({ ...parked, inbox: 1 })).toMatchObject({ fail: "auto.held_in_cloud" })
    expect(close({ ...parked, holder: VM })).toMatchObject({ fail: "auto.held_in_cloud" })
  })

  it("a machine that went quiet with nothing left to run gives the chat to a laptop that waits; one at work, or one told to keep the chat, does not", () => {
    const held: AutoRecord = { ...fresh(), holder: VM, epoch: 2, machine: "vm_1", lastSeq: 5, snapshotSeq: 5, leaseExpiresAt: 50_000 }
    const wait = { holder: A, epoch: 1, needsRun: false, standby: true }
    // While the machine renews it hands the chat back itself, at its own renewal.
    expect(renew(held, owner, wait, 49_999)).toMatchObject({ out: { role: "standby" }, rec: { holder: VM, epoch: 2 } })
    expect(renew(held, owner, wait, 50_000)).toMatchObject({ out: { role: "holder" }, rec: { holder: A, epoch: 3, needsRun: false, standby: [] } })
    for (const not of [{ needsRun: true }, { assignment: "deliver" as const }, { inbox: 1 }, { snapshotSeq: 4 }, { keepInCloud: true }, { leaseExpiresAt: 0 }]) {
      expect(renew({ ...held, ...not }, owner, wait, 50_000), JSON.stringify(not)).toMatchObject({ out: { role: "standby" }, rec: { holder: VM, epoch: 2 } })
    }
  })

  it("a laptop takes back only a chat nobody ran since it held it; after a machine ran it, it has to come back as a standby", () => {
    const parked = tick(fresh(), MACHINE, LEASE_MS)!
    const own = renew(parked, owner, { holder: A, epoch: 1, needsRun: true, standby: false }, LEASE_MS + 1)
    expect(own).toMatchObject({ out: { role: "holder" }, rec: { holder: A, epoch: 3, needsRun: true } })
    // A message sent the parked chat to the machine, which ran it and let it go: the laptop's copy is behind now.
    const ran = next(parked, release(deliver({ ...parked, inbox: 1, snapshot: 1 }, MACHINE, LEASE_MS).rec, machine, VM, 3, null, LEASE_MS))
    expect([ran.holder, ran.epoch, ran.parkedFrom]).toEqual([PARKED, 4, null])
    expect(renew(ran, owner, { holder: A, epoch: 1, needsRun: true, standby: false }, LEASE_MS + 1)).toEqual({ out: { role: "lost" } })
    expect(renew(ran, owner, { holder: A, epoch: 1, needsRun: true, standby: true }, LEASE_MS + 1)).toMatchObject({ out: { role: "holder" }, rec: { holder: A, epoch: 5, needsRun: false } })
    // Another laptop never takes a parked chat by naming an epoch.
    expect(renew(parked, owner, { holder: B, epoch: 1, needsRun: false, standby: false }, LEASE_MS + 1)).toEqual({ out: { role: "lost" } })
  })

  it("a PUT from the laptop a parked chat was parked from takes it back as it is; from any other laptop, or after a machine ran it, it only edits", () => {
    // A registration whose first answer was lost, sent again after the lease ran out: the laptop is the holder,
    // not a laptop that lost its chat.
    const parked = tick(fresh(), MACHINE, LEASE_MS)!
    const back = edit(parked, { title: "t", harness: "claude", device: "a" }, LEASE_MS + 1)
    expect(back).toMatchObject({ rec: { holder: A, epoch: 3, resumedEpoch: 1, parkedFrom: null, leaseExpiresAt: 2 * LEASE_MS + 1 } })
    // Its renewal at the epoch it held before is that same holder's.
    expect(renew(next(parked, back), owner, { holder: A, epoch: 1, needsRun: false, standby: false }, LEASE_MS + 2)).toMatchObject({ out: { role: "holder" }, rec: { holder: A, epoch: 3 } })
    expect(edit(parked, { title: "t", harness: "claude", device: "b" }, LEASE_MS + 1)).toEqual({ out: null })
    expect(edit({ ...parked, parkedFrom: null }, { title: "t", harness: "claude", device: "a" }, LEASE_MS + 1)).toEqual({ out: null })
  })

  it("a move writes a wish its holder answers with a give; a parked chat goes at once; every other change of holder, and MOVE_MS, end the wish", () => {
    const copied: AutoRecord = { ...fresh(), snapshot: 1 }
    // To the Cloud from a laptop: the wish and keepInCloud in one record, the machine named for its start.
    const asked = next(copied, moveNow(copied, "cloud", null, MACHINE, 1_000))
    expect(asked).toMatchObject({ holder: A, epoch: 1, keepInCloud: true, move: { to: "cloud", device: null, at: 1_000, machine: MACHINE } })
    expect(moveNow(copied, "cloud", null, null, 1_000)).toMatchObject({ fail: "auto.no_machine" })
    expect(moveNow({ ...copied, auto: false }, "cloud", null, MACHINE, 1_000)).toMatchObject({ fail: "auto.off" })
    expect(give(copied, owner, A, 1, MACHINE, 2_000)).toMatchObject({ fail: "auto.no_move" })
    // The copy has to cover the last event, and the give is fenced.
    expect(give({ ...asked, snapshot: 0 }, owner, A, 1, MACHINE, 2_000)).toMatchObject({ fail: "auto.not_copied" })
    expect(give({ ...asked, lastSeq: 3, snapshotSeq: 2 }, owner, A, 1, MACHINE, 2_000)).toMatchObject({ fail: "auto.not_copied" })
    expect(give(asked, owner, A, 0, MACHINE, 2_000)).toMatchObject({ fail: "auto.stale_epoch" })
    expect(give(asked, owner, B, 1, MACHINE, 2_000)).toMatchObject({ fail: "auto.not_holder" })
    expect(give(asked, owner, A, 1, null, 2_000)).toMatchObject({ fail: "auto.no_machine" })
    expect(give({ ...asked, lastSeq: 3, snapshotSeq: 3 }, owner, A, 1, MACHINE, 2_000)).toMatchObject({ rec: { holder: VM, epoch: 2, assignment: "takeover", keepInCloud: true, move: null, needsRun: true } })
    // Asked back to where it is: the wish goes and the mode follows; asked again, nothing is written.
    const stays = next(asked, moveNow(asked, "local", null, MACHINE, 2_000))
    expect(stays).toMatchObject({ holder: A, epoch: 1, keepInCloud: false, move: null })
    expect(moveNow(stays, "local", A, MACHINE, 2_000)).toEqual({ out: null })
    // The lease rules still cover a holder that is gone: the wish goes with the holder.
    expect(tick({ ...asked, needsRun: true }, MACHINE, LEASE_MS)).toMatchObject({ holder: VM, epoch: 2, move: null, keepInCloud: true })
    expect(tick(asked, MACHINE, LEASE_MS)).toMatchObject({ holder: PARKED, epoch: 2, move: null })
    // A holder that renews and does not give: the wish ends after MOVE_MS, and the chat stays.
    const renewing = { ...asked, leaseExpiresAt: 10 * MOVE_MS }
    expect(tick(renewing, MACHINE, 1_000 + MOVE_MS - 1)).toBeNull()
    expect(tick(renewing, MACHINE, 1_000 + MOVE_MS)).toMatchObject({ holder: A, epoch: 1, move: null, keepInCloud: true })

    // To a laptop from a machine: the laptop has to stand by; the one named wins over the one that renewed last.
    const held: AutoRecord = { ...copied, holder: VM, epoch: 2, team: "team_1", machine: "vm_1", keepInCloud: true, needsRun: true, leaseExpiresAt: 50_000 }
    expect(moveNow(held, "local", null, MACHINE, 1_000)).toMatchObject({ fail: "auto.no_laptop" })
    const two = { ...held, standby: [{ holder: A, expiresAt: 40_000 }, { holder: B, expiresAt: 45_000 }] }
    expect(moveNow(two, "local", "device:c", MACHINE, 1_000)).toMatchObject({ fail: "auto.no_laptop" })
    const home = next(two, moveNow(two, "local", A, MACHINE, 1_000))
    expect(home).toMatchObject({ holder: VM, epoch: 2, keepInCloud: false, move: { to: "local", device: A, machine: { team: "team_1", machine: "vm_1" } } })
    expect(give(home, machine, VM, 2, MACHINE, 2_000)).toMatchObject({ rec: { holder: A, epoch: 3, owesImport: true, needsRun: true, move: null, assignment: null } })
    expect(give(next(two, moveNow(two, "local", null, MACHINE, 1_000)), machine, VM, 2, MACHINE, 2_000)).toMatchObject({ rec: { holder: B, epoch: 3, owesImport: true } })
    // The laptop that was named stopped standing by: the give waits for one.
    expect(give(home, machine, VM, 2, MACHINE, 41_000)).toMatchObject({ fail: "auto.no_laptop" })
    // The machine's own idle renewal hands the chat to the laptop the wish names.
    expect(renew({ ...home, needsRun: false, snapshotSeq: 0 }, machine, { holder: VM, epoch: 2, needsRun: false, standby: false }, 2_000)).toMatchObject({ out: { role: "lost" }, rec: { holder: A, epoch: 3, move: null } })
    // A machine that already runs the chat is where a move to the Cloud asks for.
    expect(moveNow({ ...held, keepInCloud: false }, "cloud", null, null, 1_000)).toMatchObject({ rec: { holder: VM, epoch: 2, keepInCloud: true, move: null } })

    // A parked chat goes at once.
    const parked = tick(copied, MACHINE, LEASE_MS)!
    expect(moveNow(parked, "cloud", null, MACHINE, LEASE_MS)).toMatchObject({ rec: { holder: VM, epoch: 3, assignment: "takeover", keepInCloud: true, move: null } })
    expect(moveNow({ ...parked, snapshot: 0 }, "cloud", null, MACHINE, LEASE_MS)).toMatchObject({ fail: "auto.not_copied" })
    expect(moveNow(parked, "local", null, MACHINE, LEASE_MS)).toMatchObject({ fail: "auto.no_laptop" })
    const waited = { ...parked, keepInCloud: true, standby: [{ holder: B, expiresAt: 2 * LEASE_MS }] }
    expect(moveNow(waited, "local", null, MACHINE, LEASE_MS)).toMatchObject({ rec: { holder: B, epoch: 3, owesImport: true, keepInCloud: false, move: null } })
    // The laptop it was parked from has it already.
    expect(moveNow({ ...waited, standby: [{ holder: A, expiresAt: 2 * LEASE_MS }] }, "local", null, MACHINE, LEASE_MS)).toMatchObject({ rec: { holder: A, epoch: 3, owesImport: false } })
  })

  it("a parked chat that is kept in the Cloud and has a snapshot is not taken back by its laptop's renewal or PUT", () => {
    const parked = tick({ ...fresh(), keepInCloud: true, snapshot: 1 }, MACHINE, LEASE_MS)!
    expect(parked).toMatchObject({ holder: PARKED, epoch: 2, parkedFrom: A, keepInCloud: true })
    const mine = { holder: A, epoch: 1, needsRun: false, standby: false }
    expect(renew(parked, owner, mine, LEASE_MS + 1)).toEqual({ out: { role: "lost" } })
    expect(renew(parked, owner, { ...mine, standby: true }, LEASE_MS + 1)).toMatchObject({ out: { role: "standby" }, rec: { holder: PARKED, epoch: 2 } })
    expect(edit(parked, { title: "t", harness: "claude", device: "a" }, LEASE_MS + 1)).toEqual({ out: null })
    // Work starts the machine.
    expect(deliver({ ...parked, inbox: 1 }, MACHINE, LEASE_MS + 1)).toMatchObject({ state: "resuming", rec: { holder: VM, epoch: 3 } })
    // Not kept, or with no snapshot (the laptop has the only chat there is), the laptop takes it back as before.
    expect(renew({ ...parked, keepInCloud: false }, owner, mine, LEASE_MS + 1)).toMatchObject({ out: { role: "holder" }, rec: { holder: A, epoch: 3 } })
    expect(renew({ ...parked, snapshot: 0 }, owner, mine, LEASE_MS + 1)).toMatchObject({ out: { role: "holder" }, rec: { holder: A, epoch: 3 } })
    expect(edit({ ...parked, snapshot: 0 }, { title: "t", harness: "claude", device: "a" }, LEASE_MS + 1)).toMatchObject({ rec: { holder: A, epoch: 3 } })
    // A PUT that stops keeping the chat in the Cloud takes it back in the same write.
    expect(edit(parked, { title: "t", harness: "claude", device: "a", keepInCloud: false }, LEASE_MS + 1)).toMatchObject({ rec: { holder: A, epoch: 3, keepInCloud: false } })
  })

  it("a machine's chat goes home at its renewal only when everything it did is in the Cloud copy", () => {
    const held: AutoRecord = { ...fresh(), holder: VM, epoch: 2, machine: "vm_1", standby: [{ holder: A, expiresAt: 100_000 }], lastSeq: 5, snapshotSeq: 5 }
    const idle = { holder: VM, epoch: 2, needsRun: false, standby: false }
    expect(renew(held, machine, idle, 1_000)).toMatchObject({ out: { role: "lost" }, rec: { holder: A, epoch: 3 } })
    for (const not of [{ needsRun: true }, { assignment: "takeover" as const }, { inbox: 1 }, { snapshotSeq: 4 }, { keepInCloud: true }, { standby: [{ holder: A, expiresAt: 500 }] }]) {
      const still = renew({ ...held, ...not }, machine, "needsRun" in not ? { ...idle, needsRun: true } : idle, 1_000)
      expect(still, JSON.stringify(not)).toMatchObject({ out: { role: "holder" }, rec: { holder: VM, epoch: 2 } })
    }
    // Of two laptops waiting, the one that renewed last gets it.
    const two = { ...held, standby: [{ holder: A, expiresAt: 40_000 }, { holder: B, expiresAt: 45_000 }] }
    expect(next(two, release(two, machine, VM, 2, MACHINE, 1_000)).holder).toBe(B)
  })
})
