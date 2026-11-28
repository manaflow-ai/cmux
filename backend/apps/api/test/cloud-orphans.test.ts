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

  it("refuses a machine whose row is not abandoned", async () => {
    const x = person()
    const id = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE }))).value.machine.id as string
    expect(await (x.stub as any).clearAbandoned(x.team, id, { user: x.p.user!, email: "ops@example.com" }, "should not clear a live row")).toMatchObject({ ok: false, code: "not_abandoned" })
  })
})
