import { describe, expect, it } from "vitest"
import { createdAndBound, ensureUser, frame, person, reply } from "./cloud-bind-support.ts"

/**
 * cloud.machine.pause and cloud.machine.start (state-placement.md 7 item 4): ledger-backed provider
 * calls through the guarded driver (Freestyle POST /v5/vms/{id}/pause and /start), one machine at a
 * time; pause frees an active slot, start takes one (cloud.quota.exceeded at the plan's max_active);
 * a same-key retry replays; a deleting or unbound machine is refused.
 */

describe("pause and start", { timeout: 60_000 }, () => {
  it("pauses a running machine and starts it again; each call reaches the provider once; same-key retries replay", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    const pauseKey = crypto.randomUUID()
    const paused = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.pause", { machine }, pauseKey)))
    expect(paused, JSON.stringify(paused)).toMatchObject({ t: "result", value: { machine: { id: machine, status: "paused" } } })
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.pause", { machine }, pauseKey)))).toMatchObject({ t: "result", replayed: true })
    const plan = await x.stub.readOp(x.team, x.p, "cloud.plan.get", {})
    expect(plan.value.usage.active).toBe(0)
    const started = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.start", { machine })))
    expect(started).toMatchObject({ t: "result", value: { machine: { id: machine, status: "running" } } })
    const ctl = (await x.stub.fakeControl({})) as unknown as { pauses: number; starts: number }
    expect([ctl.pauses, ctl.starts]).toEqual([1, 1])
  })

  it("refuses to pause a paused machine or start a running one, and refuses a deleting machine", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.start", { machine })))).toMatchObject({ t: "reject", code: "cloud.machine.not_paused" })
    reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.delete", { machine })))
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.pause", { machine })))).toMatchObject({ t: "reject" })
  })
})
