import { env, exports } from "cloudflare:workers"
import { createExecutionContext, runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { PlatformOperations } from "../src/cloud-platform-operations.ts"
import { PlatformMachines } from "../src/platform-machines.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { bindBody, bindFile, cloudStub, frame, reply, SIZE } from "./cloud-bind-support.ts"
import { ALLOWED_USERS, cloudTestUser, SHARED_TEAM } from "./setup/cloud-teams.ts"

/** PlatformMachines (platform-machines.ts): the service-binding entrypoint for the platform Worker's environment setups. */
type Reply = { ok: boolean; value?: any; code?: string; message?: string; retryable?: boolean }
interface Rpc {
  boot(c: unknown, name: string, snapshot?: string | null): Promise<Reply>
  create(c: unknown, name: string, shape: { vcpu: number; memGiB: number; diskGiB: number }, snapshot?: string | null, labels?: Record<string, string>): Promise<Reply>
  providerInfo(c: unknown): Promise<Reply>
  find(c: unknown, name: string): Promise<Reply>
  get(c: unknown, machine: string): Promise<Reply>
  shape(c: unknown, machine: string): Promise<Reply>
  pause(c: unknown, machine: string): Promise<Reply>
  resume(c: unknown, machine: string): Promise<Reply>
  fork(c: unknown, machine: string, name: string): Promise<Reply>
  exec(c: unknown, machine: string, command: string, stdin: string | null, timeoutMs: number): Promise<Reply>
  snapshot(c: unknown, machine: string, name: string): Promise<Reply>
  destroy(c: unknown, machine: string): Promise<Reply>
}
const rpc = (exports as unknown as { PlatformMachines: Rpc }).PlatformMachines
const inDO = runInDurableObject as unknown as <T>(stub: unknown, cb: (instance: any) => Promise<T>) => Promise<T>

// Users 160..179 of the allowlisted test users (other cloud test files use other ranges).
let seq = 160
const caller = () => {
  const user = cloudTestUser(++seq)
  return { user, team: personalTeamIdFor(user) }
}
const nameOf = () => `denv_${crypto.randomUUID().replace(/-/g, "").slice(0, 24)}-a1`

/** The platform's builder for `c`, bound the way its VM agent binds it. */
const bootAndBind = async (c: { user: string; team: string }, name = nameOf()) => {
  const booted = await rpc.boot(c, name)
  expect(booted).toMatchObject({ ok: true, value: { id: expect.stringMatching(/^vm_[a-z0-9]{20}$/) } })
  const machine = booted.value.id as string
  const stub = cloudStub(c.team)
  const file = await bindFile(stub, machine)
  const { body } = await bindBody(c, machine, file.json.bind_token)
  expect(await stub.bindMachine(c.team, body)).toMatchObject({ ok: true })
  return { machine, name, stub }
}

describe("PlatformMachines (workerd)", { timeout: 60_000 }, () => {
  it("boots one machine per name as the person's own create, found again by name", async () => {
    const c = caller()
    const name = nameOf()
    const a = await rpc.boot(c, name)
    const b = await rpc.boot(c, name)
    expect(a).toMatchObject({ ok: true })
    // A retried boot reaches the same machine: no second create.
    expect(b.value.id).toBe(a.value.id)
    const ctl = await cloudStub(c.team).fakeControl({})
    expect((ctl as any).creates).toBe(1)
    expect(await rpc.find(c, name)).toEqual({ ok: true, value: { id: a.value.id } })
    expect(await rpc.find(c, nameOf())).toEqual({ ok: true, value: null })
    expect(await rpc.get(c, a.value.id)).toMatchObject({ ok: true, value: { id: a.value.id, state: "starting", region: "global" } })
    expect(await rpc.shape(c, a.value.id)).toMatchObject({ ok: true, value: { vcpu: expect.any(Number), memGiB: expect.any(Number), diskGiB: expect.any(Number) } })
    // The team sees it like any machine of theirs, labelled; the platform flag stays private.
    const listed = await cloudStub(c.team).readOp(c.team, { identity: `user:${c.user}`, kind: "session", user: c.user, team: c.team }, "cloud.machine.list", {})
    const row = listed.value.machines.find((m: { id: string }) => m.id === a.value.id)
    expect(row).toMatchObject({ creator: c.user, name: "Environment setup", status: "provisioning" })
    expect(row.platform).toBeUndefined()
  })

  it("execs as the work user only once the machine is bound, and only on its own machines", async () => {
    const c = caller()
    const booted = await rpc.boot(c, nameOf())
    // Still binding: retryable.
    expect(await rpc.exec(c, booted.value.id, "true", null, 10_000)).toMatchObject({ ok: false, code: "cloud.machine.not_running", retryable: true })
    const { machine, stub } = await bootAndBind(c)
    const r = await rpc.exec(c, machine, "true", null, 10_000)
    expect(r).toEqual({ ok: true, value: { exitCode: 0, stdout: "", stderr: "" } })
    const ctl = (await stub.fakeControl({})) as any
    expect(ctl.execs.at(-1)).toMatchObject({ kind: "probe" })
    expect(ctl.audit.at(-1)).toMatchObject({ action: "platform.exec", machine, who: `platform:${c.user}`, outcome: "exit 0" })
    // The person's own machine is never reachable through the binding.
    const own = reply(await stub.submit(c.team, { identity: `user:${c.user}`, kind: "session", user: c.user, team: c.team }, frame("cloud.machine.create", { size: SIZE })))
    expect(await rpc.exec(c, own.value.machine.id, "true", null, 10_000)).toMatchObject({ ok: false, code: "cloud.machine.not_found" })
    expect(await rpc.destroy(c, own.value.machine.id)).toMatchObject({ ok: false, code: "cloud.machine.not_found" })
    // Nor another user's platform machine in a team they share.
    const other = caller()
    expect(await rpc.exec({ user: other.user, team: c.team }, machine, "true", null, 10_000)).toMatchObject({ ok: false, code: "auth.forbidden" })
  })

  it("snapshots under a name once, and deletes its machine (gone is success)", async () => {
    const c = caller()
    const { machine, stub } = await bootAndBind(c)
    const name = nameOf()
    const s = await rpc.snapshot(c, machine, name)
    expect(s).toMatchObject({ ok: true, value: { id: expect.stringMatching(/^snap_[a-z0-9]{20}$/) } })
    expect(await rpc.snapshot(c, machine, name)).toEqual(s)
    expect(((await stub.fakeControl({})) as any).snapshots).toHaveLength(1)
    expect(await rpc.destroy(c, machine)).toEqual({ ok: true, value: { deleted: true } })
    expect(await rpc.destroy(c, machine)).toEqual({ ok: true, value: { deleted: true } })
    // The snapshot outlives its machine: the same name still answers it, and no second one is taken.
    expect(await rpc.snapshot(c, machine, name)).toEqual(s)
    expect(await rpc.snapshot(c, machine, nameOf())).toMatchObject({ ok: false, code: "cloud.machine.not_found" })
    expect(((await stub.fakeControl({})) as any).deletes).toBe(1)
    // A warm boot from the team's snapshot: a new machine, booted from it.
    const warm = await rpc.boot(c, nameOf(), s.value.id)
    expect(warm).toMatchObject({ ok: true })
    expect(warm.value.id).not.toBe(machine)
  })

  it("a delete that failed for good is started again by the next destroy, until the machine is gone", async () => {
    const c = caller()
    const { machine, stub } = await bootAndBind(c)
    // Every delete attempt fails until the provider recovers.
    await stub.fakeControl({ fail_next: 100 } as never)
    const first = await rpc.destroy(c, machine)
    expect(first).toMatchObject({ ok: false, retryable: true })
    // Run CloudDO's retries out (the alarm's backoff, moved forward), so the delete fails for good.
    for (let i = 0; i < 8; i++) {
      await stub.fakeControl({ advance_ms: 6 * 60_000 })
      await fireAlarm(stub)
    }
    const owner = { identity: `user:${c.user}`, kind: "session" as const, user: c.user, team: c.team }
    expect((await stub.readOp(c.team, owner, "cloud.machine.get", { machine })).value).toMatchObject({ status: "failed" })
    expect(await rpc.destroy(c, machine)).toMatchObject({ ok: false, retryable: true })
    await stub.fakeControl({ fail_next: 0 } as never)
    await stub.fakeControl({ advance_ms: 6 * 60_000 })
    await fireAlarm(stub)
    // The provider is back: a new delete runs, and the machine is gone.
    let r = await rpc.destroy(c, machine)
    for (let i = 0; i < 3 && !r.ok; i++) {
      await stub.fakeControl({ advance_ms: 6 * 60_000 })
      await fireAlarm(stub)
      r = await rpc.destroy(c, machine)
    }
    expect(r).toEqual({ ok: true, value: { deleted: true } })
    expect((await stub.readOp(c.team, owner, "cloud.machine.get", { machine })).ok).toBe(false)
  })

  it("a user who left the team can no longer boot, exec or snapshot, but its cleanup still deletes the builder", async () => {
    const c = { user: caller().user, team: SHARED_TEAM }
    const stub = cloudStub(SHARED_TEAM)
    await inDO(stub, async (instance) => {
      instance.creatorIsMember = async () => true
    })
    const name = nameOf()
    const booted = await rpc.boot(c, name)
    expect(booted).toMatchObject({ ok: true })
    await inDO(stub, async (instance) => {
      instance.creatorIsMember = async () => false
    })
    expect(await rpc.boot(c, nameOf())).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await rpc.exec(c, booted.value.id, "true", null, 1000)).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await rpc.find(c, name)).toEqual({ ok: true, value: { id: booted.value.id } })
    expect(await rpc.destroy(c, booted.value.id)).toEqual({ ok: true, value: { deleted: true } })
  })

  it("refuses a user who may not use the team's machines, and a team without a plan", async () => {
    const c = caller()
    const stub = cloudStub(SHARED_TEAM)
    await inDO(stub, async (instance) => {
      instance.creatorIsMember = async () => false
    })
    expect(await rpc.boot({ user: c.user, team: SHARED_TEAM }, nameOf())).toMatchObject({ ok: false, code: "auth.forbidden", retryable: false })
    const unplanned = cloudTestUser(ALLOWED_USERS + 600)
    expect(await rpc.boot({ user: unplanned, team: personalTeamIdFor(unplanned) }, nameOf())).toMatchObject({ ok: false, code: "cloud.plan.required" })
  })

  it("validates every argument before reaching any team", async () => {
    const c = caller()
    expect(await rpc.boot({ user: c.user, team: "nope" }, nameOf())).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await rpc.boot(c, "../x")).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await rpc.boot(c, nameOf(), "snap_bad")).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await rpc.exec(c, "vm_x", "true", null, 1000)).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await rpc.exec(c, `vm_${"a".repeat(20)}`, "", null, 1000)).toMatchObject({ ok: false, code: "validation.invalid" })
    // Only strings: an omitted or structured name never becomes "undefined" or "[object Object]".
    expect(await (rpc.boot as (...a: Array<unknown>) => Promise<Reply>)(c)).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await rpc.boot(c, { toString: null } as never)).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await rpc.exec(c, `vm_${"a".repeat(20)}`, "true", null, "5" as never)).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await rpc.get(c, "vm_x")).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await rpc.pause(c, "vm_x")).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await rpc.resume(c, "vm_x")).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await rpc.fork(c, "vm_x", nameOf())).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await rpc.create(c, nameOf(), { vcpu: 0, memGiB: 4, diskGiB: 16 })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await rpc.create(c, nameOf(), { vcpu: 2, memGiB: 4, diskGiB: 16 }, null, { bad: 1 } as never)).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(((await cloudStub(c.team).fakeControl({})) as any).creates).toBe(0)
  })

  it("keeps owned cleanup available after disabling development and stays inert elsewhere", async () => {
    const off = new PlatformMachines(createExecutionContext(), { ...(env as object), PLATFORM_MACHINES: undefined } as never)
    const c = caller()
    expect(await off.boot(c, nameOf())).toMatchObject({ ok: false, code: "platform.machines_off", retryable: false })
    expect(await off.providerInfo(c)).toMatchObject({ ok: false, code: "platform.machines_off" })
    expect(await off.create(c, nameOf(), { vcpu: 2, memGiB: 4, diskGiB: 16 })).toMatchObject({ ok: false, code: "platform.machines_off" })
    const { machine, name, stub } = await bootAndBind(c)
    expect(await off.find(c, name)).toEqual({ ok: true, value: { id: machine } })
    expect(await off.destroy(c, machine)).toEqual({ ok: true, value: { deleted: true } })
    const own = reply(await stub.submit(c.team, { identity: `user:${c.user}`, kind: "session", user: c.user, team: c.team }, frame("cloud.machine.create", { size: SIZE })))
    expect(await off.destroy(c, own.value.machine.id)).toMatchObject({ ok: false, code: "cloud.machine.not_found" })
    for (const environment of ["staging", "production"]) {
      const inert = new PlatformMachines(createExecutionContext(), { ...(env as object), ENVIRONMENT: environment, PLATFORM_MACHINES: "on" } as never)
      expect(await inert.boot(c, nameOf())).toMatchObject({ ok: false, code: "platform.machines_off" })
      expect(await inert.find(c, name)).toMatchObject({ ok: false, code: "platform.machines_off" })
      expect(await inert.destroy(c, machine)).toMatchObject({ ok: false, code: "platform.machines_off" })
    }
  })

  it("grows the snapshot-sized VM only after bind, then returns the exact shape and memory power state", async () => {
    const c = caller()
    expect(await rpc.providerInfo(c)).toMatchObject({ ok: true, value: { protocolVersion: 1, provider: "freestyle", available: true, minimumShape: null, shapeSelection: "grow-to-fit", memoryPause: true, fork: true } })
    const target = { vcpu: 4, memGiB: 8, diskGiB: 32 }
    const name = nameOf()
    const labels = { leaseId: "lease1", runId: "run1" }
    const created = await rpc.create(c, name, target, null, labels)
    expect(created).toMatchObject({ ok: true, value: { state: "starting", shape: { vcpu: 2, memGiB: 4, diskGiB: 16 }, targetShape: target } })
    const stub = cloudStub(c.team)
    const id = created.value.id as string
    const file = await bindFile(stub, id)
    const { body } = await bindBody(c, id, file.json.bind_token)
    expect(await stub.bindMachine(c.team, body)).toMatchObject({ ok: true })
    // Binding alone does not publish the smaller VM as running or allow a premature exec.
    expect(await rpc.get(c, id)).toMatchObject({ ok: true, value: { state: "starting" } })
    expect(await rpc.exec(c, id, "true", null, 1000)).toMatchObject({ ok: false, retryable: true })
    await stub.fakeControl({ advance_ms: 10_000 })
    await fireAlarm(stub)
    expect(await rpc.get(c, id)).toEqual({ ok: true, value: { id, region: "global", state: "running", shape: target } })
    expect(await rpc.create(c, name, target, null, { runId: "run1", leaseId: "lease1" })).toMatchObject({ ok: true, value: { id, shape: target } })
    expect(await rpc.create(c, name, target, null, { ...labels, runId: "run2" })).toMatchObject({ ok: false, code: "idempotency.conflict" })
    expect(await rpc.create(c, name, { ...target, vcpu: 2 }, null, labels)).toMatchObject({ ok: false, code: "idempotency.conflict" })
    expect(await rpc.pause(c, id)).toMatchObject({ ok: true, value: { id, state: "paused", shape: target } })
    expect(await rpc.pause(c, id)).toMatchObject({ ok: true, value: { state: "paused" } })
    expect(await rpc.resume(c, id)).toMatchObject({ ok: true, value: { id, state: "running", shape: target } })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1, resizes: 1, pauses: 1, starts: 1 })
  })

  it("refuses an image larger than the offer and durably removes its VM", async () => {
    const c = caller()
    const stub = cloudStub(c.team)
    await stub.fakeControl({ image_size: { cpu: 8, memory: 16384, storage: 65536 } })
    const name = nameOf()
    const target = { vcpu: 2, memGiB: 4, diskGiB: 16 }
    expect(await rpc.create(c, name, target)).toMatchObject({ ok: false, code: "cloud.platform.provision_failed", retryable: false })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1, deletes: 1, vms: [] })
    expect(await rpc.create(c, name, target)).toMatchObject({ ok: false, retryable: false })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1 })
  })

  it("recovers a lost fork capture answer without its source and retires the snapshot after restore", async () => {
    const c = caller()
    const { machine, stub } = await bootAndBind(c)
    const name = nameOf()
    await inDO(stub, async instance => {
      const original = instance.submit.bind(instance)
      instance.submit = async (entity: string, principal: unknown, f: { op: string }) => {
        const r = await original(entity, principal, f)
        if (f.op === "cloud.snapshot.create") { instance.submit = original; throw new Error("lost answer after capture commit") }
        return r
      }
    })
    expect(await rpc.fork(c, machine, name)).toMatchObject({ ok: false, code: "owner.unreachable" })
    expect(await rpc.destroy(c, machine)).toMatchObject({ ok: true })
    // A fresh orchestrator has no in-memory request state. The alarm recovers its snapshot ID
    // from the ledger; no caller retry and no surviving source is needed to finish the fork.
    await inDO(stub, async instance => { instance.platformOperations = new PlatformOperations(instance.sqlStore) })
    await stub.fakeControl({ advance_ms: 10_000 })
    await fireAlarm(stub)
    const forked = await rpc.fork(c, machine, name)
    expect(forked).toMatchObject({ ok: true, value: { state: "starting", shape: { vcpu: 2, memGiB: 4, diskGiB: 16 } } })
    expect(await rpc.fork(c, machine, name)).toEqual(forked)
    expect(await stub.fakeControl({})).toMatchObject({ creates: 2, snapshots: [] })
    expect(await rpc.destroy(c, forked.value.id)).toMatchObject({ ok: true })
    expect(await rpc.fork(c, machine, name)).toMatchObject({ ok: false, code: "cloud.machine.not_found", retryable: false })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 2 })
  })

  it("retries temporary snapshot retirement in the alarm after the caller disappears", async () => {
    const c = caller()
    const { machine, stub } = await bootAndBind(c)
    await stub.fakeControl({ snapshot_delete_refuse: 1 })
    const forked = await rpc.fork(c, machine, nameOf())
    expect(forked).toMatchObject({ ok: true, value: { state: "starting", targetShape: { vcpu: 2, memGiB: 4, diskGiB: 16 } } })
    expect(((await stub.fakeControl({})) as any).snapshots).toHaveLength(1)
    await stub.fakeControl({ advance_ms: 10_000 })
    await fireAlarm(stub)
    expect(await stub.fakeControl({})).toMatchObject({ creates: 2, snapshots: [] })
    expect((await rpc.get(c, forked.value.id)).value.targetShape).toBeUndefined()
  })

  it("times out an unbound resize reservation and cleans up without a client retry", async () => {
    const c = caller()
    const stub = cloudStub(c.team)
    const name = nameOf()
    const target = { vcpu: 4, memGiB: 8, diskGiB: 32 }
    const created = await rpc.create(c, name, target)
    expect(created).toMatchObject({ ok: true })
    await stub.fakeControl({ advance_ms: 16 * 60_000 })
    await fireAlarm(stub)
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1, deletes: 1, vms: [] })
    expect(await rpc.create(c, name, target)).toMatchObject({ ok: false, code: "cloud.platform.provision_failed", retryable: false })
  })

  it("retires a capture completed after its fork deadline without a client retry", async () => {
    const c = caller()
    const { machine, stub } = await bootAndBind(c)
    const name = nameOf()
    await inDO(stub, async instance => {
      const original = instance.driverFor.bind(instance)
      instance.driverFor = async (...args: Array<unknown>) => {
        const driver = await original(...args)
        if (driver) driver.snapshot = async () => { throw new Error("transient capture failure") }
        return driver
      }
      try {
        expect(await instance.platformMachine(c.team, c.user, { op: "fork", machine, name })).toMatchObject({ ok: false, retryable: true })
      } finally { instance.driverFor = original }
    })
    // The capture intent survives the failed provider call. On this alarm the ordinary Cloud
    // ledger finishes it first; the expired platform intent must then remove the saved snapshot,
    // without restoring a child or requiring the caller to retry the fork.
    await stub.fakeControl({ advance_ms: 16 * 60_000 })
    await fireAlarm(stub)
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1, snapshots: [] })
    expect(await rpc.fork(c, machine, name)).toMatchObject({ ok: false, code: "cloud.platform.provision_failed", retryable: false })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1, snapshots: [] })
  })

  it("finds and cancels a child while its committed create answer is still suspended", async () => {
    const c = caller()
    const stub = cloudStub(c.team)
    await inDO(stub, async instance => {
      const original = instance.submit.bind(instance)
      let release!: () => void
      let entered!: (id: string) => void
      const gate = new Promise<void>(resolve => { release = resolve })
      const committed = new Promise<string>(resolve => { entered = resolve })
      instance.submit = async (entity: string, principal: unknown, f: { op: string }) => {
        const r = await original(entity, principal, f)
        if (f.op === "cloud.machine.create") {
          const id = r.frames.find((frame: any) => frame.t === "result")?.value.machine.id
          entered(id)
          await gate
        }
        return r
      }
      const work = instance.platformMachine(c.team, c.user, { op: "create", name: nameOf(), shape: { vcpu: 4, memGiB: 8, diskGiB: 32 }, labels: {} })
      try {
        const id = await committed
        // Before the create answer returns, the journal must already own the ledger's child.
        expect(await instance.platformMachine(c.team, c.user, { op: "get", machine: id })).toMatchObject({ ok: true, value: { state: "starting", targetShape: { vcpu: 4, memGiB: 8, diskGiB: 32 } } })
        expect(await instance.platformMachine(c.team, c.user, { op: "destroy", machine: id })).toMatchObject({ ok: true })
      } finally {
        release()
        instance.submit = original
        await work
      }
    })
    await stub.fakeControl({ advance_ms: 10_000 })
    await fireAlarm(stub)
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1, deletes: 1, vms: [] })
  })

  it("revalidates same-name requests that race while installing their first alarm", async () => {
    const c = caller()
    const stub = cloudStub(c.team)
    await inDO(stub, async instance => {
      const originalHost = instance.platformHost(c.team)
      let entered!: () => void
      const bothArmed = new Promise<void>(resolve => { entered = resolve })
      const releases: Array<() => void> = []
      const gates = [0, 1].map(() => new Promise<void>(resolve => { releases.push(resolve) }))
      let calls = 0
      let ready = 0
      const host = { ...originalHost, arm: async (at: number) => {
        const slot = calls++
        await originalHost.arm(at)
        if (++ready === 2) entered()
        await gates[slot]
      } }
      const name = nameOf()
      // Both requests read absence before either one can install its operation record.
      const first = instance.platformOperations.request(host, c.user, { name, shape: { vcpu: 2, memGiB: 4, diskGiB: 16 }, labels: { runId: "first" } }, host.now)
      const second = instance.platformOperations.request(host, c.user, { name, shape: { vcpu: 4, memGiB: 8, diskGiB: 32 }, labels: { runId: "second" } }, host.now)
      try {
        await bothArmed
        releases[0]!()
        expect(await first).toMatchObject({ ok: true, value: { shape: { vcpu: 2, memGiB: 4, diskGiB: 16 } } })
        releases[1]!()
        expect(await second).toMatchObject({ ok: false, code: "idempotency.conflict", retryable: false })
      } finally {
        for (const release of releases) release()
        await Promise.allSettled([first, second])
      }
    })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1 })
  })

  it("confirms provider resources after failed create reads and after resize before reporting running", async () => {
    const c = caller()
    const stub = cloudStub(c.team)
    await inDO(stub, async instance => {
      const original = instance.driverFor.bind(instance)
      instance.platformTestOriginalDriver = original
      instance.driverFor = async (...args: Array<unknown>) => {
        const driver = await original(...args)
        if (driver) driver.resourcesOf = async () => { throw new Error("resource read unavailable") }
        return driver
      }
    })
    const target = { vcpu: 4, memGiB: 8, diskGiB: 32 }
    const created = await rpc.create(c, nameOf(), target)
    expect(created).toMatchObject({ ok: true, value: { state: "starting", targetShape: target } })
    const id = created.value.id as string
    const file = await bindFile(stub, id)
    const { body } = await bindBody(c, id, file.json.bind_token)
    expect(await stub.bindMachine(c.team, body)).toMatchObject({ ok: true })
    expect(await rpc.get(c, id)).toMatchObject({ ok: true, value: { state: "starting", targetShape: target } })
    await inDO(stub, async instance => {
      const original = instance.platformTestOriginalDriver
      let blocked = false
      instance.driverFor = async (...args: Array<unknown>) => {
        const driver = await original(...args)
        if (!driver) return driver
        const resources = driver.resourcesOf.bind(driver)
        const resize = driver.resize.bind(driver)
        driver.resourcesOf = async (...readArgs: Array<unknown>) => {
          if (blocked) throw new Error("post-resize resource read unavailable")
          return resources(...readArgs)
        }
        driver.resize = async (...resizeArgs: Array<unknown>) => { await resize(...resizeArgs); blocked = true }
        return driver
      }
    })
    await stub.fakeControl({ advance_ms: 10_000 })
    await fireAlarm(stub)
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1, resizes: 1 })
    // A successful resize ledger is insufficient while its resource confirmation is unavailable.
    expect(await rpc.get(c, id)).toMatchObject({ ok: true, value: { state: "starting", shape: { vcpu: 2, memGiB: 4, diskGiB: 16 }, targetShape: target } })
    await inDO(stub, async instance => { instance.driverFor = instance.platformTestOriginalDriver })
    await stub.fakeControl({ advance_ms: 10_000 })
    await fireAlarm(stub)
    expect(await rpc.get(c, id)).toEqual({ ok: true, value: { id, state: "running", region: "global", shape: target } })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1, resizes: 1 })
  })

  it("is not reachable over HTTP", async () => {
    const worker = (exports as unknown as { default: Fetcher }).default
    for (const path of ["/PlatformMachines", "/v1/PlatformMachines/boot", "/platform-machines"]) {
      const res = await worker.fetch(`https://api.test${path}`, { method: "POST", body: "{}" })
      expect(res.status).toBeGreaterThanOrEqual(400)
    }
  })
})
