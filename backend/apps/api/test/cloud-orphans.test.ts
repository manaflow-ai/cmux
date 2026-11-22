import { env } from "cloudflare:workers"
import type { OwnerFrame, Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import type { SubmitResult } from "../src/owner-do.ts"
import { providerName } from "../src/cloud-driver.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { cloudTestUser } from "./setup/cloud-teams.ts"

/**
 * Security re-review N1-N5: the orphan report flags every VM whose machine is gone or failed,
 * a cancelled create keeps an hourly lookup for 24 h and deletes a late VM only by its recorded
 * ledger name and only when its metadata matches, then the row is abandoned and reported; a failed
 * delete counts in the quota again; a failed list never fails the wake; the sweep runs only while
 * the team has rows.
 */

type Frame = { t: "op"; op: string; params: unknown; idempotency_key: string; origin: "user" }
interface Counters {
  creates: number
  deletes: number
  vms: Array<{ name: string; id: string }>
  pending: number
  suspects: Array<{ name: string; provider_id: string; reason: string }>
  sweep_at: number | null
  now: number
}
interface CloudStub {
  submit(entity: string, principal: Principal, frame: Frame): Promise<SubmitResult>
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<any>
  fakeControl(cmd: { fail_next?: number; advance_ms?: number; fail_list?: boolean; add_vm?: { name: string; team: string; machine: string } }): Promise<Counters>
}
const namespace = (env as unknown as { CLOUD_DO: DurableObjectNamespace }).CLOUD_DO
const PREFIX = "cmuxnp-test-cld-"
const HOUR = 3600_000
// Users 100..149 of the allowlisted test users (cloud-do.test.ts counts up from 1, cloud-provider from 151).
let seq = 100
const person = () => {
  const user = cloudTestUser(++seq)
  const team = personalTeamIdFor(user)
  const p: Principal = { identity: `user:${user}`, user, team, kind: "session" }
  return { team, p, stub: namespace.get(namespace.idFromName(team)) as unknown as CloudStub }
}
const frame = (op: string, params: unknown, key: string = crypto.randomUUID()): Frame => ({ t: "op", op, params, idempotency_key: key, origin: "user" })
const reply = (r: SubmitResult) => r.frames.find((x: OwnerFrame) => x.t === "result" || x.t === "reject") as { t: string; value?: any; code?: string }
const SIZE = { cpu: 2, memory_mb: 4096, disk_mb: 16384 }
const tick = async (stub: CloudStub, ms = 10 * 60_000) => {
  await stub.fakeControl({ advance_ms: ms })
  await fireAlarm(stub)
}

/** Probe 1 setup: a create cut off, then a delete whose five lookups give up; the client gets {deleted: true}. */
const cancelledCreate = async () => {
  const x = person()
  await x.stub.fakeControl({ fail_next: 1 })
  expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE })))).toMatchObject({ code: "mutation.indeterminate" })
  const id = (await x.stub.readOp(x.team, x.p, "cloud.machine.list", {})).value.machines[0].id as string
  reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.delete", { machine: id }, "del")))
  for (let i = 0; i < 7; i++) await tick(x.stub)
  expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.delete", { machine: id }, "del")))).toMatchObject({ t: "result", value: { deleted: true } })
  return { ...x, id, name: providerName(PREFIX, id) }
}

describe("N1: late VMs of a cancelled create", { timeout: 120_000 }, () => {
  it("probe 1: a VM that appears within 24 h is deleted by the recorded ledger name", async () => {
    const { team, stub, id, name } = await cancelledCreate()
    await stub.fakeControl({ add_vm: { name, team, machine: id } })
    await tick(stub, 2 * HOUR)
    expect(await stub.fakeControl({})).toMatchObject({ deletes: 1, vms: [] })
  })

  it("never deletes a late VM whose metadata does not match the ledger row; it is reported metadata_mismatch", async () => {
    const { team, stub, name } = await cancelledCreate()
    await stub.fakeControl({ add_vm: { name, team, machine: "vm_ffffffffffffffffffff" } })
    await tick(stub, 2 * HOUR)
    await tick(stub, 2 * HOUR)
    const c = await stub.fakeControl({})
    expect(c.deletes).toBe(0)
    expect(c.vms.map((v) => v.name)).toEqual([name])
    expect(c.suspects).toEqual([expect.objectContaining({ name, reason: "metadata_mismatch" })])
  })

  it("probe 1 after the window: the row is abandoned (kept past pruning) and a VM that appears later is reported, never deleted", async () => {
    const { team, stub, id, name } = await cancelledCreate()
    await tick(stub, 25 * HOUR)
    await tick(stub, 8 * 24 * HOUR)
    await stub.fakeControl({ add_vm: { name, team, machine: id } })
    await tick(stub, 2 * HOUR)
    const c = await stub.fakeControl({})
    expect(c.deletes).toBe(0)
    expect(c.suspects).toEqual([expect.objectContaining({ name, reason: "abandoned_create" })])
  })
})

describe("N1 + N2: a delete that fails for good", { timeout: 120_000 }, () => {
  it("probe 2: the machine is failed, counts in the quota again, and its running VM is reported delete_failed", async () => {
    const { team, p, stub } = person()
    const id = reply(await stub.submit(team, p, frame("cloud.machine.create", { size: SIZE }))).value.machine.id as string
    await stub.fakeControl({ fail_next: 5 })
    expect(reply(await stub.submit(team, p, frame("cloud.machine.delete", { machine: id })))).toMatchObject({ code: "mutation.indeterminate" })
    for (let i = 0; i < 6; i++) await tick(stub)
    expect(await stub.readOp(team, p, "cloud.machine.get", { machine: id })).toMatchObject({ ok: true, value: { status: "failed" } })
    expect((await stub.readOp(team, p, "cloud.plan.get", {})).value.usage.active).toBe(1)
    await tick(stub, 2 * HOUR)
    const c = await stub.fakeControl({})
    expect(c.vms.map((v) => v.name)).toEqual([providerName(PREFIX, id)])
    expect(c.suspects).toEqual([expect.objectContaining({ name: providerName(PREFIX, id), reason: "delete_failed" })])
    // Deleting the failed machine again releases the quota once.
    expect(reply(await stub.submit(team, p, frame("cloud.machine.delete", { machine: id })))).toMatchObject({ t: "result", value: { deleted: true } })
    expect((await stub.readOp(team, p, "cloud.plan.get", {})).value.usage.active).toBe(0)
  })
})

describe("N3 + N5: sweep scheduling", { timeout: 120_000 }, () => {
  it("N3: a failed provider list is logged and the next report comes an hour later; the wake does not fail", async () => {
    const { team, p, stub } = person()
    reply(await stub.submit(team, p, frame("cloud.machine.create", { size: SIZE })))
    await tick(stub)
    await stub.fakeControl({ fail_list: true })
    await tick(stub, 2 * HOUR)
    const c = await stub.fakeControl({})
    expect(c.sweep_at).not.toBeNull()
    expect(Math.abs(c.sweep_at! - c.now)).toBeLessThan(60_000)
    // Fired again at once: no new attempt before the hour.
    await fireAlarm(stub)
    expect((await stub.fakeControl({})).sweep_at).toBe(c.sweep_at)
  })

  it("N5: no sweep once the team has no machine, ledger or tombstone rows", async () => {
    const { team, p, stub } = person()
    const id = reply(await stub.submit(team, p, frame("cloud.machine.create", { size: SIZE }))).value.machine.id as string
    reply(await stub.submit(team, p, frame("cloud.machine.delete", { machine: id })))
    await tick(stub)
    // Tombstones go after 30 days, finished ledger rows after 7.
    await tick(stub, 31 * 24 * HOUR)
    const before = (await stub.fakeControl({})).sweep_at
    expect(typeof before).toBe("number")
    await tick(stub, 2 * HOUR)
    expect((await stub.fakeControl({})).sweep_at).toBe(before)
  })
})

describe("cloud.admin.abandoned.clear (CloudDO side)", { timeout: 120_000 }, () => {
  const abandoned = async () => {
    const x = await cancelledCreate()
    await tick(x.stub, 25 * HOUR)
    return x
  }
  const who = (x: { p: Principal }) => ({ user: x.p.user!, email: "ops@example.com" })

  it("refuses while a VM exists under the recorded name, and the row stays", async () => {
    const x = await abandoned()
    await x.stub.fakeControl({ add_vm: { name: x.name, team: x.team, machine: x.id } })
    const r = await (x.stub as any).clearAbandoned(x.team, x.id, who(x), "checked the console by hand")
    expect(r).toMatchObject({ ok: false, code: "vm_present" })
    const again = await (x.stub as any).clearAbandoned(x.team, x.id, who(x), "checked the console by hand")
    expect(again).toMatchObject({ ok: false, code: "vm_present" })
    expect((await x.stub.fakeControl({})).deletes).toBe(0)
  })

  it("clears an abandoned row when no VM exists, records who/when/why, and a second clear finds nothing", async () => {
    const x = await abandoned()
    const r = await (x.stub as any).clearAbandoned(x.team, x.id, who(x), "VM gone in the provider console")
    expect(r).toMatchObject({ ok: true, audit: { machine: x.id, by: x.p.user, by_email: "ops@example.com", reason: "VM gone in the provider console" } })
    expect(typeof r.audit.at).toBe("number")
    expect(await (x.stub as any).clearAbandoned(x.team, x.id, who(x), "VM gone in the provider console")).toMatchObject({ ok: false, code: "not_abandoned" })
  })

  it("refuses a machine whose row is not abandoned", async () => {
    const x = person()
    const id = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE }))).value.machine.id as string
    expect(await (x.stub as any).clearAbandoned(x.team, id, { user: x.p.user!, email: "ops@example.com" }, "should not clear a live row")).toMatchObject({ ok: false, code: "not_abandoned" })
  })
})
