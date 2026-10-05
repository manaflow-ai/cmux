import { describe, expect, it } from "vitest"
import { createdAndBound, ensureUser, frame, installOf, person, reply } from "./cloud-bind-support.ts"

/**
 * cloud.machine.resize (state-placement.md 7 item 4; coordinator 2026-10-05): grow only on every axis
 * (Freestyle POST /v5/vms/{id}/resize), within the plan (cloud.size.locked), disk growth only while
 * running; a money op on the same path as pause and start (a signed-in person, ledger first, prefix
 * guard, per-team limit). The answer carries the target size; a final failure restores the old size.
 */

const SIZE = { cpu: 2, memory_mb: 4096, disk_mb: 16384 }

describe("resize", { timeout: 60_000 }, () => {
  it("grows a running machine through the provider once; the VM ends at the new size", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    const key = crypto.randomUUID()
    const r = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.resize", { machine, size: { cpu: 4, memory_mb: 8192 } }, key)))
    expect(r, JSON.stringify(r)).toMatchObject({ t: "result", value: { machine: { id: machine, size: { cpu: 4, memory_mb: 8192, disk_mb: SIZE.disk_mb } } } })
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.resize", { machine, size: { cpu: 4, memory_mb: 8192 } }, key)))).toMatchObject({ t: "result", replayed: true })
    const ctl = (await x.stub.fakeControl({})) as unknown as { resizes: number; vms: Array<{ name: string; cpu: number; memory: number }> }
    expect(ctl.resizes).toBe(1)
    expect(ctl.vms.find((v) => v.name.endsWith(machine.replace(/_/g, "-")))).toMatchObject({ cpu: 4, memory: 8192 })
    expect(await x.stub.readOp(x.team, x.p, "cloud.machine.get", { machine })).toMatchObject({ value: { size: { cpu: 4, memory_mb: 8192 }, status: "running" } })
  })

  it("refuses shrinking, sizes outside the plan, disk growth while paused, and callers that are not a person", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.resize", { machine, size: { cpu: 1 } })))).toMatchObject({ t: "reject", code: "cloud.size.grow_only" })
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.resize", { machine, size: { cpu: 64 } })))).toMatchObject({ t: "reject", code: "cloud.size.locked" })
    expect(reply(await x.stub.submit(x.team, installOf(x.p), frame("cloud.machine.resize", { machine, size: { cpu: 4 } })))).toMatchObject({ t: "reject", code: "auth.forbidden" })
    reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.pause", { machine })))
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.resize", { machine, size: { disk_mb: 32768 } })))).toMatchObject({ t: "reject", code: "cloud.machine.not_running" })
    // cpu and memory may grow while paused (they apply on resume).
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.resize", { machine, size: { memory_mb: 8192 } })))).toMatchObject({ t: "result" })
  })

  it("a final provider failure restores the old size with the error", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    await x.stub.fakeControl({ resize_refuse: 1 } as never)
    reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.resize", { machine, size: { cpu: 4 } })))
    const got = await x.stub.readOp(x.team, x.p, "cloud.machine.get", { machine })
    expect(got.value.size.cpu).toBe(SIZE.cpu)
    expect(got.value.error).toMatchObject({ code: expect.any(String) })
  })

  it("a delete settles a resize still retrying (review P3)", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    await x.stub.fakeControl({ fail_next: 1 } as never)
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.resize", { machine, size: { cpu: 4 } })))).toMatchObject({ t: "reject", code: "mutation.indeterminate" })
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.delete", { machine })))).toMatchObject({ t: "result", value: { deleted: true } })
    expect((await x.stub.readOp(x.team, x.p, "cloud.machine.get", { machine })).ok).toBe(false)
  })

  it("create records the VM's real size, not the requested one (Freestyle has no size at create)", async () => {
    const x = person()
    await ensureUser(x)
    await x.stub.fakeControl({ image_size: { cpu: 4, memory: 8192, storage: 32768 } } as never)
    const { machine } = await createdAndBound(x)
    expect(await x.stub.readOp(x.team, x.p, "cloud.machine.get", { machine })).toMatchObject({ value: { size: { cpu: 4, memory_mb: 8192, disk_mb: 32768 } } })
  })

  it("after a final resize failure the record takes the VM's real size (a partial resize), not the old size (review P3)", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    // The provider grows vCPU, then refuses the memory: the VM ends at 4 vCPU / 4096 MiB.
    await x.stub.fakeControl({ resize_partial: 1 } as never)
    reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.resize", { machine, size: { cpu: 4, memory_mb: 8192 } })))
    const got = await x.stub.readOp(x.team, x.p, "cloud.machine.get", { machine })
    expect(got.value.size).toMatchObject({ cpu: 4, memory_mb: 4096 })
    expect(got.value.error).toMatchObject({ code: expect.any(String) })
  })
})
