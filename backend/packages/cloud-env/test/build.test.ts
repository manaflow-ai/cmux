import { describe, expect, test } from "vitest"
import { buildEnvironmentSnapshot, environmentBootPlan, environmentBuildDigest, EnvironmentBuildError, execKind, MemorySandbox, type CloudSandbox } from "../src/index.ts"
import { BASE, spec } from "./fixtures.ts"

const options = { baseImage: BASE, builderName: "env-build-1", snapshotName: "env-snap-1", readyTimeoutMs: 1_000, readyIntervalMs: 1, sleep: async () => {} }

describe("buildEnvironmentSnapshot", () => {
  test("boots the base image, waits for the guest, builds, snapshots, and deletes the builder", async () => {
    const box = new MemorySandbox("freestyle")
    let probes = 0
    let polls = 0
    box.onExec = (cmd) => {
      const kind = execKind(cmd)
      if (kind === "probe") return ++probes < 3 ? Promise.reject(new Error("not ready")) : { exitCode: 0, stdout: "", stderr: "" }
      if (kind === "poll") return { exitCode: 0, stdout: ++polls < 3 ? "running\ncloning" : "exit 0\ndone", stderr: "" }
      return { exitCode: 0, stdout: "started", stderr: "" }
    }
    const out = await buildEnvironmentSnapshot(box, spec(), options)
    const snap = out.snapshotId
    expect(box.calls).toEqual(["boot:base", "exec:probe", "exec:probe", "exec:probe", "exec:start", "exec:poll", "exec:poll", "exec:poll", "snapshot", `boot:${snap}`, "destroy", "destroy"])
    expect(box.snapshots.get(out.snapshotId)?.name).toBe("env-snap-1")
    expect(box.machines.size).toBe(0)
    expect(out.digest).toBe(await environmentBuildDigest(spec(), BASE))
    for (const v of Object.values(out.timings)) expect(v).toBeGreaterThanOrEqual(0)
  })

  test("a failed setup reports a bounded log tail, takes no snapshot, and deletes the builder", async () => {
    const box = new MemorySandbox()
    box.onExec = (cmd) => (execKind(cmd) === "poll" ? { exitCode: 0, stdout: "exit 3\n" + "installing\n".repeat(1000) + "boom", stderr: "" } : { exitCode: 0, stdout: "", stderr: "" })
    const err = await buildEnvironmentSnapshot(box, spec(), options).catch((e: unknown) => e)
    expect(err).toBeInstanceOf(EnvironmentBuildError)
    expect((err as EnvironmentBuildError).stage).toBe("setup")
    expect(new TextEncoder().encode((err as EnvironmentBuildError).logTail).byteLength).toBeLessThanOrEqual(4096)
    expect((err as EnvironmentBuildError).logTail.endsWith("boom")).toBe(true)
    expect(box.calls).not.toContain("snapshot")
    expect(box.calls.at(-1)).toBe("destroy")
  })

  test("a setup that outlives its deadline fails at setup with the log so far", async () => {
    const box = new MemorySandbox()
    box.onExec = (cmd) => ({ exitCode: 0, stdout: execKind(cmd) === "poll" ? "running\nstill installing" : "", stderr: "" })
    let t = 0
    const err = await buildEnvironmentSnapshot(box, spec(), { ...options, setupTimeoutMs: 50, now: () => (t += 10) }).catch((e: unknown) => e)
    expect((err as EnvironmentBuildError).stage).toBe("setup")
    expect((err as EnvironmentBuildError).logTail).toBe("still installing")
    expect(box.machines.size).toBe(0)
  })

  test("warmName null skips the warm-up boot", async () => {
    const box = new MemorySandbox()
    await buildEnvironmentSnapshot(box, spec(), { ...options, warmName: null })
    expect(box.calls.filter((c) => c.startsWith("boot:"))).toEqual(["boot:base"])
  })

  test("a guest that never answers fails at ready and is deleted", async () => {
    const box = new MemorySandbox()
    box.onExec = () => Promise.reject(new Error("down"))
    let t = 0
    const err = await buildEnvironmentSnapshot(box, spec(), { ...options, readyTimeoutMs: 10, now: () => (t += 5) }).catch((e: unknown) => e)
    expect((err as EnvironmentBuildError).stage).toBe("ready")
    expect(box.machines.size).toBe(0)
  })

  test("a boot failure leaves nothing to delete", async () => {
    const box: CloudSandbox = { provider: "x", boot: async () => { throw new Error("capacity") }, exec: async () => ({ exitCode: 0, stdout: "", stderr: "" }), snapshot: async () => ({ id: "s" }), destroy: async () => { throw new Error("must not be called") } }
    const err = await buildEnvironmentSnapshot(box, spec(), options).catch((e: unknown) => e)
    expect((err as EnvironmentBuildError).stage).toBe("boot")
  })
})

describe("environmentBootPlan", () => {
  test("snapshot when the digest and provider match; cold and stale after a build-input edit or rebake", async () => {
    const box = new MemorySandbox("freestyle")
    const built = await buildEnvironmentSnapshot(box, spec(), options)
    const record = { snapshotId: built.snapshotId, digest: built.digest, provider: "freestyle" }
    expect(await environmentBootPlan(spec(), record, BASE, "freestyle")).toEqual({ kind: "snapshot", snapshotId: built.snapshotId, digest: built.digest })
    expect(await environmentBootPlan(spec({ name: "renamed" }), record, BASE, "freestyle")).toMatchObject({ kind: "snapshot" })
    expect(await environmentBootPlan(spec({ setupScript: "bun i" }), record, BASE, "freestyle")).toMatchObject({ kind: "cold", reason: "stale" })
    expect(await environmentBootPlan(spec(), record, "sc-newer", "freestyle")).toMatchObject({ kind: "cold", reason: "stale" })
    expect(await environmentBootPlan(spec(), record, BASE, "firecracker")).toMatchObject({ kind: "cold", reason: "stale" })
    const unbuilt = await environmentBootPlan(spec(), null, BASE, "freestyle")
    expect(unbuilt).toMatchObject({ kind: "cold", reason: "unbuilt" })
    if (unbuilt.kind === "cold") expect(unbuilt.setupExec).toContain("bash -c")
  })

  test("a snapshot boot runs no setup: the new machine comes straight from the snapshot", async () => {
    const box = new MemorySandbox("freestyle")
    const built = await buildEnvironmentSnapshot(box, spec(), options)
    box.calls.length = 0
    const plan = await environmentBootPlan(spec(), { snapshotId: built.snapshotId, digest: built.digest, provider: "freestyle" }, BASE, "freestyle")
    if (plan.kind !== "snapshot") throw new Error("expected snapshot")
    const vm = await box.boot({ name: "ws-1", snapshot: plan.snapshotId })
    expect(box.calls).toEqual([`boot:${built.snapshotId}`])
    expect(box.machines.get(vm.id)?.from).toBe(built.snapshotId)
  })
})
