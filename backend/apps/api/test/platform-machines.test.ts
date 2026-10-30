import { env, exports } from "cloudflare:workers"
import { createExecutionContext, runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { PlatformMachines } from "../src/platform-machines.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { bindBody, bindFile, cloudStub, frame, reply, SIZE } from "./cloud-bind-support.ts"
import { ALLOWED_USERS, cloudTestUser, SHARED_TEAM } from "./setup/cloud-teams.ts"

/** PlatformMachines (platform-machines.ts): the service-binding entrypoint for the platform Worker's environment setups. */
type Reply = { ok: boolean; value?: any; code?: string; message?: string; retryable?: boolean }
interface Rpc {
  boot(c: unknown, name: string, snapshot?: string | null): Promise<Reply>
  find(c: unknown, name: string): Promise<Reply>
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
    expect(((await cloudStub(c.team).fakeControl({})) as any).creates).toBe(0)
  })

  it("refuses every call where PLATFORM_MACHINES is not on", async () => {
    const off = new PlatformMachines(createExecutionContext(), { ...(env as object), PLATFORM_MACHINES: undefined } as never)
    const c = caller()
    expect(await off.boot(c, nameOf())).toMatchObject({ ok: false, code: "platform.machines_off", retryable: false })
    expect(await off.destroy(c, `vm_${"a".repeat(20)}`)).toMatchObject({ ok: false, code: "platform.machines_off" })
  })

  it("is not reachable over HTTP", async () => {
    const worker = (exports as unknown as { default: Fetcher }).default
    for (const path of ["/PlatformMachines", "/v1/PlatformMachines/boot", "/platform-machines"]) {
      const res = await worker.fetch(`https://api.test${path}`, { method: "POST", body: "{}" })
      expect(res.status).toBeGreaterThanOrEqual(400)
    }
  })
})
