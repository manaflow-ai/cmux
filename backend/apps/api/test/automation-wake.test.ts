import { describe, expect, it } from "vitest"
import { awaitMachine, stepFailureReport, wakeOnce, WAKE_POLL_MS, WAKE_POLLS, type MachinePower, type StepLike } from "../src/automation-machine.ts"

/** Spec section 12 (models-scout): wake a stopped machine before a run; a run that cannot run only because the machine is stopped is skipped `machine_not_running`, never a failure. */

const VM = "vm_aaaaaaaaaaaaaaaaaaaa"
const RUN = "run_bbbbbbbbbbbbbbbbbbbb"

/** A machine whose status follows a script; start() moves a paused machine to starting. */
const fakePower = (statuses: Array<string>) => {
  const starts: Array<string> = []
  let i = 0
  const power: MachinePower = {
    get: async () => ({ ok: true, status: statuses[Math.min(i++, statuses.length - 1)]!, revision: `rev${i}` }),
    start: async (_m, key) => {
      starts.push(key)
      return { ok: true }
    }
  }
  return { power, starts }
}

/** A Workflow step stand-in that journals names (a replay would read them) and records sleeps. */
const fakeStep = () => {
  const names: Array<string> = []
  const sleeps: Array<number> = []
  const step: StepLike = {
    do: async (name, fn) => {
      names.push(name)
      return fn()
    },
    sleep: async (name, ms) => {
      names.push(name)
      sleeps.push(ms)
    }
  }
  return { step, names, sleeps }
}

describe("wakeOnce", () => {
  it("a running machine needs nothing", async () => {
    const { power, starts } = fakePower(["running"])
    expect(await wakeOnce(power, VM, RUN)).toBe("running")
    expect(starts).toEqual([])
  })

  it("a paused machine is started once, with a key bound to the run, machine and revision", async () => {
    const { power, starts } = fakePower(["paused"])
    expect(await wakeOnce(power, VM, RUN)).toBe("starting")
    expect(starts).toEqual([`automation-wake:${RUN}:${VM}:rev1`])
  })

  it("starting, pausing and provisioning wait; a deleted or failed machine cannot run", async () => {
    for (const s of ["starting", "pausing", "provisioning"]) expect(await wakeOnce(fakePower([s]).power, VM, RUN)).toBe("starting")
    for (const s of ["deleting", "failed"]) expect(await wakeOnce(fakePower([s]).power, VM, RUN)).toBe("unavailable")
    const gone: MachinePower = { get: async () => ({ ok: false, code: "cloud.machine.not_found" }), start: async () => ({ ok: true }) }
    expect(await wakeOnce(gone, VM, RUN)).toBe("unavailable")
  })

  it("a refused start (quota, not a person) cannot run", async () => {
    const power: MachinePower = { get: async () => ({ ok: true, status: "paused", revision: "r" }), start: async () => ({ ok: false, code: "cloud.quota.exceeded" }) }
    expect(await wakeOnce(power, VM, RUN)).toBe("unavailable")
  })
})

describe("awaitMachine", () => {
  it("starts a paused machine and waits in journaled sleeps until it runs", async () => {
    const { power, starts } = fakePower(["paused", "starting", "starting", "running"])
    const { step, names, sleeps } = fakeStep()
    expect(await awaitMachine(step, power, VM, RUN)).toBe(true)
    expect(starts).toHaveLength(1)
    expect(sleeps).toEqual([WAKE_POLL_MS, WAKE_POLL_MS, WAKE_POLL_MS])
    expect(names[0]).toBe(`cmux:wake-${VM}-0`)
  })

  it("gives up after WAKE_POLLS checks (about 5 min)", async () => {
    const { step, sleeps } = fakeStep()
    expect(await awaitMachine(step, fakePower(["starting"]).power, VM, RUN)).toBe(false)
    expect(sleeps).toHaveLength(WAKE_POLLS)
    expect(WAKE_POLLS * WAKE_POLL_MS).toBeGreaterThanOrEqual(5 * 60_000)
  })

  it("with no person to start it as (no creator), it cannot run", async () => {
    expect(await awaitMachine(fakeStep().step, null, VM, RUN)).toBe(false)
  })
})

describe("stepFailureReport", () => {
  it("a stopped machine skips the run as machine_not_running; every other failure fails it", () => {
    expect(stepFailureReport({ ok: false, code: "machine.not_running", message: "step 0: vm is not running" })).toEqual({ state: "skipped", error: { code: "machine_not_running", message: "step 0: vm is not running" } })
    expect(stepFailureReport({ ok: false, code: "machine.exit", message: "step 1: exit 3: 2 checks failed" })).toEqual({ state: "failed", error: { code: "machine.exit", message: "step 1: exit 3: 2 checks failed" } })
  })
})
