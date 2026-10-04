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
  suspects: Array<{ name: string; provider_id: string }>
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
  it("keeps the machine deleting until the VM a lost create made appears, then deletes it by its recorded name", async () => {
    const { team, p, stub } = person()
    await stub.fakeControl({ fail_next: 1 })
    const cut = await create(stub, team, p, "uncertain")
    expect(cut).toMatchObject({ code: "mutation.indeterminate" })
    // The create call failed for now (it may still land): a delete must wait for a definite answer.
    const id = (await stub.readOp(team, p, "cloud.machine.list", {})).value.machines[0].id as string
    const del = reply(await stub.submit(team, p, frame("cloud.machine.delete", { machine: id }, "del-uncertain")))
    expect(del).toMatchObject({ t: "reject", code: "mutation.indeterminate" })
    expect(await stub.readOp(team, p, "cloud.machine.get", { machine: id })).toMatchObject({ ok: true, value: { status: "deleting" } })
    expect(await stub.fakeControl({})).toMatchObject({ pending: 2, creates: 0 })
    // The lost create lands after all.
    await stub.fakeControl({ add_vm: { name: providerName(PREFIX, id), team, machine: id } })
    await tick(stub)
    expect(await stub.fakeControl({})).toMatchObject({ pending: 0, deletes: 1, vms: [] })
    expect(await stub.readOp(team, p, "cloud.machine.get", { machine: id })).toMatchObject({ ok: false, code: "cloud.machine.not_found" })
    expect(reply(await stub.submit(team, p, frame("cloud.machine.delete", { machine: id }, "del-uncertain")))).toMatchObject({ t: "result", value: { deleted: true } })
  })

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

describe("P1-2: hourly orphan report (never a delete)", { timeout: 60_000 }, () => {
  it("reports a VM with our prefix and this team's tag that no machine or ledger row names, and deletes nothing", async () => {
    const { team, p, stub } = person()
    const live = (await create(stub, team, p)).value.machine.id as string
    const orphan = "vm_0123456789abcdef0123"
    await stub.fakeControl({ add_vm: { name: providerName(PREFIX, orphan), team, machine: orphan } })
    // Another team's VM under our prefix and a VM with a foreign name are not this object's to report.
    await stub.fakeControl({ add_vm: { name: providerName(PREFIX, "vm_aaaaaaaaaaaaaaaaaaaa"), team: "team_00000000000000000099", machine: "vm_aaaaaaaaaaaaaaaaaaaa" } })
    await stub.fakeControl({ add_vm: { name: "cmuxnp-test-tvm-team-x-e1", team, machine: orphan } })
    for (let i = 0; i < 8; i++) await tick(stub)
    const c = await stub.fakeControl({})
    expect(c.suspects.map((s) => s.name)).toEqual([providerName(PREFIX, orphan)])
    expect(c.vms.map((v) => v.name).sort()).toEqual([providerName(PREFIX, live), providerName(PREFIX, orphan), providerName(PREFIX, "vm_aaaaaaaaaaaaaaaaaaaa"), "cmuxnp-test-tvm-team-x-e1"].sort())
    expect(c.deletes).toBe(0)
  })
})

describe("P2-6: provider settings", { timeout: 60_000 }, () => {
  it("sends the machine's idle policy (0 = never pause, -1 at Freestyle) at create", async () => {
    const { team, p, stub } = person()
    expect((await create(stub, team, p)).t).toBe("result")
    expect((await stub.fakeControl({})).vms[0]!.idle).toBe(1800)
    const b = person()
    await b.stub.fakeControl({ fail_next: 1 })
    await create(b.stub, b.team, b.p, "idle-key")
    const id = (await b.stub.readOp(b.team, b.p, "cloud.machine.list", {})).value.machines[0].id as string
    reply(await b.stub.submit(b.team, b.p, frame("cloud.machine.idle_policy.set", { machine: id, idle_seconds: 0 })))
    expect(await create(b.stub, b.team, b.p, "idle-key")).toMatchObject({ t: "result" })
    expect((await b.stub.fakeControl({})).vms[0]!.idle).toBe(-1)
  })

  it("checks cpu and disk against the plan before any provider call", async () => {
    const { team, p, stub } = person()
    expect(reply(await stub.submit(team, p, frame("cloud.machine.create", { size: { cpu: STUB_PLAN.max_cpu + 1 } })))).toMatchObject({ code: "cloud.size.locked", details: { cpu: STUB_PLAN.max_cpu + 1 } })
    expect(reply(await stub.submit(team, p, frame("cloud.machine.create", { size: { disk_mb: STUB_PLAN.max_disk_mb + 1024 } })))).toMatchObject({ code: "cloud.size.locked", details: { disk_mb: STUB_PLAN.max_disk_mb + 1024 } })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 0 })
  })

  it("the Freestyle create asks for a persistent machine with public egress and the idle policy", async () => {
    const sent: Array<{ method: string; url: string; body: any }> = []
    const fetchFn = (async (url: string, init: RequestInit) => {
      sent.push({ method: init.method ?? "GET", url, body: init.body ? JSON.parse(init.body as string) : undefined })
      return init.method === "POST" ? Response.json({ id: "fs-1" }, { status: 201 }) : Response.json({ code: "NOT_FOUND" }, { status: 404 })
    }) as unknown as typeof fetch
    const driver = new FreestyleCloudDriver("key", "https://fs.test", "cmuxnp-test-vmimg-1", fetchFn)
    const tag = { team: "team_00000000000000000001", machine: "vm_00000000000000000001" }
    await driver.create("cmuxnp-test-cld-vm-00000000000000000001", tag, { idleSeconds: 0 })
    await driver.create("cmuxnp-test-cld-vm-00000000000000000002", tag, { idleSeconds: 3600 })
    const [a, b] = sent.filter((s) => s.method === "POST")
    expect(a!.body).toMatchObject({
      slug: "cmuxnp-test-cld-vm-00000000000000000001",
      snapshotId: "cmuxnp-test-vmimg-1",
      idleTimeoutSeconds: -1,
      autoDeleteSeconds: -1,
      metadata: { cmux_next_team: tag.team, cmux_next_machine: tag.machine },
      firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] }
    })
    expect(b!.body.idleTimeoutSeconds).toBe(3600)
    // The list used by the orphan report filters by this team's tag.
    await driver.list("cmux_next_team:team_00000000000000000001", 0)
    expect(sent.at(-1)!.url).toBe("https://fs.test/v5/vms?metadata=cmux_next_team%3Ateam_00000000000000000001&limit=100&offset=0")
  })
})
