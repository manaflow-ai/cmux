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

  it("refuses shrinking, sizes outside the plan, disk growth while paused, and callers that are not a person", async () => {
    const x = person()
    await ensureUser(x)
    const { machine } = await createdAndBound(x)
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.resize", { machine, size: { cpu: 1 } })))).toMatchObject({ t: "reject", code: "cloud.size.grow_only" })
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.resize", { machine, size: { cpu: 64 } })))).toMatchObject({ t: "reject", code: "cloud.size.locked" })
    // An install's resize waits for the person's approval (G8, cx-wb5.65); an agent is refused.
    expect(reply(await x.stub.submit(x.team, installOf(x.p), frame("cloud.machine.resize", { machine, size: { cpu: 4 } })))).toMatchObject({ t: "reject", code: "approval.pending" })
    expect(reply(await x.stub.submit(x.team, { ...installOf(x.p), agent: "agent_00000000000000000001" }, frame("cloud.machine.resize", { machine, size: { cpu: 4 } })))).toMatchObject({ t: "reject", code: "auth.forbidden" })
    reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.pause", { machine })))
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.resize", { machine, size: { disk_mb: 32768 } })))).toMatchObject({ t: "reject", code: "cloud.machine.not_running" })
    // cpu and memory may grow while paused (they apply on resume).
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.resize", { machine, size: { memory_mb: 8192 } })))).toMatchObject({ t: "result" })
  })

})
