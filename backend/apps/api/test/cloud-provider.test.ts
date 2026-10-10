import { env } from "cloudflare:workers"
import type { OwnerFrame, Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import type { SubmitResult } from "../src/owner-do.ts"
import { FreestyleCloudDriver, providerName } from "../src/cloud-driver.ts"
import { STUB_PLAN } from "../src/domains/cloud-plan.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { cloudTestUser } from "./setup/cloud-teams.ts"

/**
 * Review findings P1-2 (uncertain create then delete; orphan report) and P2-6 (provider settings:
 * idle, persistence, firewall, size). The fake provider lives in the object's SQLite.
 */

type Frame = { t: "op"; op: string; params: unknown; idempotency_key: string; origin: "user" }
interface FakeVm {
  name: string
  id: string
  idle: number | null
}
interface Counters {
  creates: number
  deletes: number
  vms: Array<FakeVm>
  pending: number
  suspects: Array<{ name: string; provider_id: string; reason: string }>
}
interface CloudStub {
  submit(entity: string, principal: Principal, frame: Frame): Promise<SubmitResult>
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<any>
  fakeControl(cmd: { fail_next?: number; drop_results?: number; advance_ms?: number; add_vm?: { name: string; team: string; machine: string } }): Promise<Counters>
}
const namespace = (env as unknown as { CLOUD_DO: DurableObjectNamespace }).CLOUD_DO
const PREFIX = "cmuxnp-test-cld-"
// Users 150..199 of the allowlisted test users (cloud-do.test.ts counts up from 1).
let seq = 150
const person = () => {
  const user = cloudTestUser(++seq)
  const team = personalTeamIdFor(user)
  const p: Principal = { identity: `user:${user}`, user, team, kind: "session" }
  return { team, p, stub: namespace.get(namespace.idFromName(team)) as unknown as CloudStub }
}
const frame = (op: string, params: unknown, key: string = crypto.randomUUID()): Frame => ({ t: "op", op, params, idempotency_key: key, origin: "user" })
const reply = (r: SubmitResult) => r.frames.find((x: OwnerFrame) => x.t === "result" || x.t === "reject") as { t: string; value?: any; code?: string; details?: any }
const SIZE = { cpu: 2, memory_mb: 4096, disk_mb: 16384 }
const create = async (s: CloudStub, team: string, p: Principal, key?: string) => reply(await s.submit(team, p, frame("cloud.machine.create", { size: SIZE }, key)))
const tick = async (stub: CloudStub) => {
  await stub.fakeControl({ advance_ms: 10 * 60_000 })
  await fireAlarm(stub)
}

describe("P1-2: a delete never finishes while a cancelled create is uncertain", { timeout: 60_000 }, () => {

  it("gives up after bounded finds with backoff when no VM appears, then finishes the delete", async () => {
    const { team, p, stub } = person()
    await stub.fakeControl({ fail_next: 1 })
    await create(stub, team, p)
    const id = (await stub.readOp(team, p, "cloud.machine.list", {})).value.machines[0].id as string
    expect(reply(await stub.submit(team, p, frame("cloud.machine.delete", { machine: id }, "del-gone")))).toMatchObject({ code: "mutation.indeterminate" })
    // A same-key retry right away does not spend the bounded finds (they wait for their backoff).
    expect(reply(await stub.submit(team, p, frame("cloud.machine.delete", { machine: id }, "del-gone")))).toMatchObject({ code: "mutation.indeterminate" })
    for (let i = 0; i < 3; i++) await tick(stub)
    expect(await stub.readOp(team, p, "cloud.machine.get", { machine: id })).toMatchObject({ ok: true, value: { status: "deleting" } })
    for (let i = 0; i < 4; i++) await tick(stub)
    expect(await stub.fakeControl({})).toMatchObject({ pending: 0, creates: 0, deletes: 0 })
    expect(await stub.readOp(team, p, "cloud.machine.get", { machine: id })).toMatchObject({ ok: false, code: "cloud.machine.not_found" })
  })
})

