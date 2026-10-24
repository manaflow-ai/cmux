import { describe, expect, it } from "vitest"
import { FakeMachineProvider, ProviderContractError, type MachineRequest } from "../src/cloud-provider-contract.ts"

const request = (idempotencyKey: string): MachineRequest => ({
  owner: "team-alpha",
  idempotencyKey,
  region: "us-central1",
  shape: { cpu: 2, memoryMb: 4096, diskGb: 32 },
  image: "cmux-next@sha256:demo",
  idleTimeoutSeconds: 60,
})

describe("provider-neutral cloud contract", () => {
  it("allocates once for a retry and fences a different request", async () => {
    const provider = new FakeMachineProvider()
    const first = await provider.allocate(request("alloc-1"))
    const retry = await provider.allocate(request("alloc-1"))
    expect(retry).toEqual(first)
    await expect(provider.allocate({ ...request("alloc-1"), region: "europe-west1" })).rejects.toMatchObject({ code: "provider.idempotency_conflict" })
    expect(first.machine.id).toBe("fake-machine-1")
    expect(first.machine.generation).toBe(1)
  })

  it("returns a new generation on stop/start and rejects stale operations", async () => {
    const provider = new FakeMachineProvider()
    const allocated = await provider.allocate(request("alloc-2"))
    const stopped = await provider.stop(allocated.machine, "stop-1")
    expect(stopped.state).toBe("stopped")
    expect(stopped.machine.generation).toBe(2)
    await expect(provider.start(allocated.machine, "start-stale")).rejects.toBeInstanceOf(ProviderContractError)
    const started = await provider.start(stopped.machine, "start-1")
    expect(started.state).toBe("running")
    expect(started.machine.generation).toBe(3)
  })

  it("idle-stops, prices, attaches and meters one usage window", async () => {
    let now = Date.parse("2026-10-24T00:00:00.000Z")
    const provider = new FakeMachineProvider(() => now)
    const allocated = await provider.allocate(request("alloc-3"))
    const early = await provider.idleStop(allocated.machine, "idle-early", "2026-10-23T23:59:30.000Z")
    expect(early).toBeNull()
    now += 61_000
    const idle = await provider.idleStop(allocated.machine, "idle-1", "2026-10-24T00:00:00.000Z")
    expect(idle?.operation).toBe("idle_stop")
    expect(idle?.state).toBe("stopped")
    const attached = await provider.attach(idle!.machine)
    expect(attached.endpoint).toBe("wss://fake.invalid/cloud/fake-machine-1")
    const estimate = provider.estimate(request("estimate").shape)
    expect(estimate.runningUsdMicrosPerHour).toBe(132_240)
    const usage = provider.usage(idle!.machine, "2026-10-24T00:00:00.000Z", "2026-10-24T01:00:00.000Z")
    expect(usage.runningSeconds).toBe(3600)
    expect(usage.amountUsdMicros).toBe(132_240)
  })

  it("snapshots and forks without exposing provider credentials", async () => {
    const provider = new FakeMachineProvider()
    const allocated = await provider.allocate(request("alloc-4"))
    const captured = await provider.snapshot(allocated.machine, "snapshot-1")
    expect(captured.snapshot.source).toEqual(allocated.machine)
    const forked = await provider.fork(captured.snapshot, { ...request("fork-1"), owner: "team-beta" })
    expect(forked.machine.owner).toBe("team-beta")
    expect(JSON.stringify(captured)).not.toContain("token")
    await expect(provider.fork({ ...captured.snapshot, id: "missing" }, request("fork-missing"))).rejects.toMatchObject({ code: "provider.not_found" })
  })
})
