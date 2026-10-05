import { describe, expect, it } from "vitest"
import { createdAndBound, ensureUser, frame, installOf, person, reply } from "./cloud-bind-support.ts"

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
    // The answer is the intent (pausing, like create answers provisioning); the call's outcome lands as cloud.machine.upsert.
    expect(paused, JSON.stringify(paused)).toMatchObject({ t: "result", value: { machine: { id: machine, status: "pausing" } } })
    expect(await x.stub.readOp(x.team, x.p, "cloud.machine.get", { machine })).toMatchObject({ value: { status: "paused" } })
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.pause", { machine }, pauseKey)))).toMatchObject({ t: "result", replayed: true })
    const plan = await x.stub.readOp(x.team, x.p, "cloud.plan.get", {})
    expect(plan.value.usage.active).toBe(0)
    const started = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.start", { machine })))
    expect(started).toMatchObject({ t: "result", value: { machine: { id: machine, status: "starting" } } })
    expect(await x.stub.readOp(x.team, x.p, "cloud.machine.get", { machine })).toMatchObject({ value: { status: "running" } })
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

  it("a paused machine answers connect_info with state paused, and link_token refuses with cloud.machine.paused (coordinator decision)", async () => {
    const x = person()
    await ensureUser(x)
    const { machine, host } = await createdAndBound(x)
    reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.pause", { machine })))
    expect(await x.stub.readOp(x.team, installOf(x.p), "cloud.machine.connect_info", { machine })).toMatchObject({ ok: true, value: { state: "paused" } })
    expect(await x.stub.mintLinkToken(x.team, installOf(x.p), { host, services: ["ssh"] })).toMatchObject({ ok: false, code: "cloud.machine.paused", details: { machine, state: "paused" } })
  })

  it("pause and start need a signed-in person (money ops): an install is refused", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    expect(reply(await x.stub.submit(x.team, installOf(x.p), frame("cloud.machine.pause", { machine })))).toMatchObject({ t: "reject", code: "auth.forbidden" })
  })

  it("a call that failed after the VM changed settles from the VM's real state (review P2)", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.pause", { machine })))
    // The provider starts the VM, then the answer is lost and the retry hears "already running" (409).
    await x.stub.fakeControl({ power_then_fail: 1 } as never)
    reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.start", { machine })))
    expect(await x.stub.readOp(x.team, x.p, "cloud.machine.get", { machine })).toMatchObject({ value: { status: "running" } })
    expect((await x.stub.readOp(x.team, x.p, "cloud.plan.get", {})).value.usage.active).toBe(1)
  })

  it("a start whose VM is gone marks the machine failed, not paused forever (review P3)", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.pause", { machine })))
    const vm = ((await x.stub.fakeControl({})) as unknown as { vms: Array<{ name: string }> }).vms.find((v) => v.name.endsWith(machine.replace(/_/g, "-")))!
    await x.stub.fakeControl({ delete_vm: vm.name } as never)
    reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.start", { machine })))
    expect(await x.stub.readOp(x.team, x.p, "cloud.machine.get", { machine })).toMatchObject({ value: { status: "failed" } })
  })
})
