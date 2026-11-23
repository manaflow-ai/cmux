import { describe, expect, it } from "vitest"
import { ackAssignment, close, deliver, edit, fence, keep, machineSet, openRecord, release, renew, tick, type Step } from "../src/auto-sessions/lease.ts"
import { isVm, LEASE_MS, PARKED, stateOf, type AutoCaller, type AutoMachine, type AutoRecord } from "../src/auto-sessions/model.ts"

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
      const move = rand(12)
      now += pick([0, 1_000, 10_000, 50_000])
      if (move === 0) r = next(r, renew(r, owner, { holder: pick([A, B]), epoch, needsRun: rand(2) === 0, standby: rand(2) === 0 }, now))
      else if (move === 1) r = next(r, renew(r, machine, { holder: VM, epoch, needsRun: rand(2) === 0, standby: false }, now))
      else if (move === 2) r = next(r, release(r, r.holder === VM ? machine : owner, r.holder === PARKED ? A : r.holder, epoch, has, now))
      else if (move === 3) r = next(r, ackAssignment(r, machine, VM, epoch, now))
      else if (move === 4) r = r.auto ? deliver({ ...r, inbox: r.inbox + 1 }, has, now).rec : r
      else if (move === 5) r = fence(r, r.holder === VM ? machine : owner, r.holder, r.epoch) ? r : { ...r, inboxAcked: r.inbox }
      else if (move === 6) r = tick(r, has, now) ?? r
      else if (move === 7) r = next(r, keep(r, rand(2) === 0))
      else if (move === 8) r = rand(6) === 0 ? next(r, close(r)) : r
      else if (move === 9) r = next(r, edit(r, { title: "t", harness: "claude", device: pick(["a", "b"]) }, now))
      else if (move === 10) r = machineSet(r, rand(4) === 0 ? OTHER : MACHINE) ?? r
      else r = fence(r, r.holder === VM ? machine : owner, r.holder, r.epoch) ? r : { ...r, lastSeq: r.lastSeq + 1, snapshotSeq: rand(2) === 0 ? r.lastSeq + 1 : r.snapshotSeq }
      expect(r.epoch - before.epoch, `move ${move} at step ${i}: ${before.holder} -> ${r.holder}`).toBe(r.holder === before.holder ? 0 : 1)
      // Only a machine has something to pick up, and only a parked chat waits for a machine.
      if (r.assignment !== null) expect(isVm(r.holder)).toBe(true)
      if (r.blocked !== null) expect(r.holder).toBe(PARKED)
      if (r.holder === PARKED) expect(r.leaseExpiresAt).toBe(0)
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
    // A message nobody took is work too: it must not be left in a parked chat.
    expect(tick({ ...fresh(), inbox: 1 }, MACHINE, LEASE_MS)!.holder).toBe(VM)
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
    expect(machineSet(busy, MACHINE)).toBeNull()
    expect(machineSet({ ...busy, assignment: null }, OTHER)).toBeNull()
    expect(machineSet({ ...busy, assignment: "deliver" }, OTHER)).toBeNull()
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
    const ran = next(parked, release(deliver({ ...parked, inbox: 1 }, MACHINE, LEASE_MS).rec, machine, VM, 3, null, LEASE_MS))
    expect([ran.holder, ran.epoch, ran.parkedFrom]).toEqual([PARKED, 4, null])
    expect(renew(ran, owner, { holder: A, epoch: 1, needsRun: true, standby: false }, LEASE_MS + 1)).toEqual({ out: { role: "lost" } })
    expect(renew(ran, owner, { holder: A, epoch: 1, needsRun: true, standby: true }, LEASE_MS + 1)).toMatchObject({ out: { role: "holder" }, rec: { holder: A, epoch: 5, needsRun: false } })
    // Another laptop never takes a parked chat by naming an epoch.
    expect(renew(parked, owner, { holder: B, epoch: 1, needsRun: false, standby: false }, LEASE_MS + 1)).toEqual({ out: { role: "lost" } })
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
