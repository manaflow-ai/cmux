import { env } from "cloudflare:workers"
import { MemoryRows, type OwnerFrame, type Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { CloudMachine, CloudPlan } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import type { SubmitResult } from "../src/owner-do.ts"
import { DriverError } from "../src/team-vm-driver.ts"
import { ENV_PREFIX, GuardedCloudDriver, providerName, type RawCloudDriver } from "../src/cloud-driver.ts"
import { STUB_PLAN } from "../src/domains/cloud-plan.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { ALLOWED_USERS, cloudTestUser } from "./setup/cloud-teams.ts"
import { cloudConfig } from "../src/cloud-driver.ts"
import { planFor } from "../src/domains/cloud-plan.ts"
import { cloudDomain, TABLE_MACHINE, TABLE_TOMBSTONE } from "../src/domains/cloud.ts"

/**
 * CloudDO skeleton (plans/cmux-next/state-placement.md 5.2 and 5.3): the provider-call ledger,
 * deterministic env-prefixed names, single flight, alarm repair by name, mutation.indeterminate
 * with a same-key resume, idempotent deletes with a tombstone, the prefix guard, plan checks
 * before any provider call, and agent refusal. The fake provider lives in the object's SQLite.
 */

type Frame = { t: "op"; op: string; params: unknown; idempotency_key: string; origin: "user" }
interface FakeCounters {
  creates: number
  deletes: number
  vms: Array<{ name: string; id: string }>
  pending: number
}
interface CloudStub {
  submit(entity: string, principal: Principal, frame: Frame): Promise<SubmitResult>
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<any>
  fakeControl(cmd: { fail_next?: number; drop_results?: number; advance_ms?: number; delete_vm?: string }): Promise<FakeCounters>
}
const namespace = (env as unknown as { CLOUD_DO: DurableObjectNamespace }).CLOUD_DO
const stubFor = (team: string) => namespace.get(namespace.idFromName(team)) as unknown as CloudStub

let seq = 0
/** Test users 1..ALLOWED_USERS have allowlisted personal teams (CLOUD_ALLOWED_TEAMS); others do not. */
const people = (allowed = true) => {
  const alice = allowed ? cloudTestUser(++seq) : cloudTestUser(ALLOWED_USERS + 100 + ++seq)
  const team = personalTeamIdFor(alice)
  const bob = cloudTestUser(ALLOWED_USERS + 1000 + ++seq)
  const a: Principal = { identity: `user:${alice}`, user: alice, team, kind: "session" }
  const b: Principal = { identity: `user:${bob}`, user: bob, team, kind: "session" }
  const agent: Principal = { identity: `install:inst_${"a".repeat(20)}`, user: alice, team, kind: "install", install: `inst_${"a".repeat(20)}`, agent: "agent_chief01", grant_classes: ["read", "mutate-own", "mutate-shared", "money", "destructive"] }
  return { team, alice: a, bob: b, agent, stub: stubFor(team) }
}
const frame = (op: string, params: unknown, key: string = crypto.randomUUID()): Frame => ({ t: "op", op, params, idempotency_key: key, origin: "user" })
const reply = (r: SubmitResult) => {
  const f = r.frames.find((x: OwnerFrame) => x.t === "result" || x.t === "reject")
  if (!f) throw new Error("no reply")
  return f as { t: "result" | "reject"; value?: any; code?: string; details?: any; replayed: boolean; revision?: string; retryable?: boolean }
}
const SIZE = { cpu: 2, memory_mb: 4096, disk_mb: 16384 }
const create = async (s: CloudStub, team: string, p: Principal, key?: string, name = "box") => reply(await s.submit(team, p, frame("cloud.machine.create", { name, size: SIZE }, key)))
const decodes = (schema: Schema.Top, v: unknown) => Exit.isSuccess(Schema.decodeUnknownExit(schema as Schema.Codec<unknown, unknown>)(v))

describe("CloudDO provider-call ledger", { timeout: 60_000 }, () => {
  it("create twice with the same key makes one provider VM under the deterministic name", async () => {
    const { team, alice, stub } = people()
    const first = await create(stub, team, alice, "same-key")
    expect(first.t, JSON.stringify(first)).toBe("result")
    expect(decodes(CloudMachine, first.value.machine)).toBe(true)
    expect(first.value.machine).toMatchObject({ team, creator: alice.user, status: "provisioning", host: null, classic: false })
    expect(first.value.machine.revision).toBe(first.revision)
    const again = await create(stub, team, alice, "same-key")
    expect(again).toMatchObject({ t: "result", replayed: true })
    expect(again.value.machine.id).toBe(first.value.machine.id)
    const c = await stub.fakeControl({})
    expect(c.creates).toBe(1)
    expect(c.vms.map((v) => v.name)).toEqual([providerName("cmuxnp-test-cld-", first.value.machine.id)])
    expect(c.vms[0]!.name).toBe(`cmuxnp-test-cld-${first.value.machine.id.replace("_", "-")}`)
    expect(c.pending).toBe(0)
  })

  it("a crash after the provider call is repaired by the alarm, which finds the VM by name and never creates twice", async () => {
    const { team, alice, stub } = people()
    await stub.fakeControl({ drop_results: 1 })
    const cut = await create(stub, team, alice, "crash-key")
    expect(cut).toMatchObject({ t: "reject", code: "mutation.indeterminate", retryable: true })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1, pending: 1 })
    // The alarm runs after the safety delay; move the object's clock past it, then fire the real alarm.
    await stub.fakeControl({ advance_ms: 10 * 60_000 })
    await fireAlarm(stub)
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1, pending: 0 })
    const retry = await create(stub, team, alice, "crash-key")
    expect(retry).toMatchObject({ t: "result", replayed: true })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1 })
  })

  it("a cut-off provider call answers mutation.indeterminate; the same-key retry resumes from the ledger", async () => {
    const { team, alice, stub } = people()
    await stub.fakeControl({ fail_next: 1 })
    const cut = await create(stub, team, alice, "cut-key")
    expect(cut).toMatchObject({ t: "reject", code: "mutation.indeterminate", retryable: true })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 0, pending: 1 })
    const retry = await create(stub, team, alice, "cut-key")
    expect(retry).toMatchObject({ t: "result", replayed: true })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1, pending: 0 })
    // A different key is a new intent (a second machine).
    expect(await create(stub, team, alice, "other-key")).toMatchObject({ t: "result", replayed: false })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 2 })
  })

  it("delete is idempotent: same-key replay, provider 404 is success, and the tombstone answers a new key", async () => {
    const { team, alice, stub } = people()
    const m = (await create(stub, team, alice)).value.machine
    const del = reply(await stub.submit(team, alice, frame("cloud.machine.delete", { machine: m.id }, "del-1")))
    expect(del).toMatchObject({ t: "result", value: { deleted: true }, replayed: false })
    expect(await stub.fakeControl({})).toMatchObject({ deletes: 1, vms: [], pending: 0 })
    expect(reply(await stub.submit(team, alice, frame("cloud.machine.delete", { machine: m.id }, "del-1")))).toMatchObject({ t: "result", value: { deleted: true }, replayed: true })
    expect(reply(await stub.submit(team, alice, frame("cloud.machine.delete", { machine: m.id }, "del-2")))).toMatchObject({ t: "result", value: { deleted: true } })
    expect(await stub.fakeControl({})).toMatchObject({ deletes: 1 })
    expect(await stub.readOp(team, alice, "cloud.machine.get", { machine: m.id })).toMatchObject({ ok: false, code: "cloud.machine.not_found" })
    // The VM was already gone at the provider (deleted out of band): the delete still succeeds.
    const gone = (await create(stub, team, alice)).value.machine
    await stub.fakeControl({ delete_vm: providerName("cmuxnp-test-cld-", gone.id) })
    expect(reply(await stub.submit(team, alice, frame("cloud.machine.delete", { machine: gone.id })))).toMatchObject({ t: "result", value: { deleted: true } })
    expect(await stub.readOp(team, alice, "cloud.machine.list", {})).toMatchObject({ ok: true, value: { machines: [] } })
  })

  it("a cut-off delete answers mutation.indeterminate and the same-key retry finishes it", async () => {
    const { team, alice, stub } = people()
    const m = (await create(stub, team, alice)).value.machine
    await stub.fakeControl({ fail_next: 1 })
    expect(reply(await stub.submit(team, alice, frame("cloud.machine.delete", { machine: m.id }, "del-cut")))).toMatchObject({ t: "reject", code: "mutation.indeterminate" })
    expect(reply(await stub.submit(team, alice, frame("cloud.machine.delete", { machine: m.id }, "del-cut")))).toMatchObject({ t: "result", value: { deleted: true }, replayed: true })
    expect(await stub.fakeControl({})).toMatchObject({ deletes: 1, vms: [] })
  })

  it("checks the plan before any provider call: quota and locked sizes make no VM", async () => {
    const { team, alice, stub } = people()
    for (let i = 0; i < STUB_PLAN.max_active; i++) expect((await create(stub, team, alice)).t).toBe("result")
    const over = await create(stub, team, alice)
    expect(over).toMatchObject({ t: "reject", code: "cloud.quota.exceeded", details: { limit: STUB_PLAN.max_active, used: STUB_PLAN.max_active } })
    const locked = reply(await stub.submit(team, alice, frame("cloud.machine.create", { size: { memory_mb: 65536 } })))
    expect(locked).toMatchObject({ t: "reject", code: "cloud.size.locked", details: { memory_mb: 65536 } })
    expect(await stub.fakeControl({})).toMatchObject({ creates: STUB_PLAN.max_active })
  })

  it("refuses an install for create and delete even when its grant has money and destructive (user principal only until ORIGIN)", async () => {
    const { team, alice, stub } = people()
    const inst = `inst_${"b".repeat(20)}`
    const install: Principal = { identity: `install:${inst}`, user: alice.user, team, kind: "install", install: inst, grant_classes: ["read", "mutate-own", "mutate-shared", "money", "destructive"] }
    expect(await create(stub, team, install)).toMatchObject({ t: "reject", code: "auth.forbidden" })
    const m = (await create(stub, team, alice)).value.machine
    expect(reply(await stub.submit(team, install, frame("cloud.machine.delete", { machine: m.id })))).toMatchObject({ t: "reject", code: "auth.forbidden" })
    // Reads and non-person mutations stay open to the install.
    expect(await stub.readOp(team, install, "cloud.machine.get", { machine: m.id })).toMatchObject({ ok: true, value: { id: m.id } })
  })

  it("refuses agent principals for create and delete, with no provider call", async () => {
    const { team, alice, agent, stub } = people()
    expect(await create(stub, team, agent)).toMatchObject({ t: "reject", code: "auth.forbidden" })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 0 })
    const m = (await create(stub, team, alice)).value.machine
    expect(reply(await stub.submit(team, agent, frame("cloud.machine.delete", { machine: m.id })))).toMatchObject({ t: "reject", code: "auth.forbidden" })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1, deletes: 0 })
    // An agent acts as its principal for reads.
    expect(await stub.readOp(team, agent, "cloud.machine.get", { machine: m.id })).toMatchObject({ ok: true, value: { id: m.id } })
  })

  it("only the creator or an admin renames, sets the idle policy or deletes; members read", async () => {
    const { team, alice, bob, stub } = people()
    const m = (await create(stub, team, alice)).value.machine
    expect(reply(await stub.submit(team, bob, frame("cloud.machine.rename", { machine: m.id, name: "mine" })))).toMatchObject({ t: "reject", code: "auth.forbidden" })
    expect(reply(await stub.submit(team, bob, frame("cloud.machine.idle_policy.set", { machine: m.id, idle_seconds: 60 })))).toMatchObject({ t: "reject", code: "auth.forbidden" })
    expect(reply(await stub.submit(team, bob, frame("cloud.machine.delete", { machine: m.id })))).toMatchObject({ t: "reject", code: "auth.forbidden" })
    expect(await stub.readOp(team, bob, "cloud.machine.get", { machine: m.id })).toMatchObject({ ok: true })
    const renamed = reply(await stub.submit(team, alice, frame("cloud.machine.rename", { machine: m.id, name: "renamed" })))
    expect(renamed).toMatchObject({ t: "result", value: { machine: { name: "renamed" } } })
    expect(Number(renamed.value.machine.revision)).toBeGreaterThan(Number(m.revision))
    const idle = reply(await stub.submit(team, alice, frame("cloud.machine.idle_policy.set", { machine: m.id, idle_seconds: 3600 })))
    expect(idle).toMatchObject({ t: "result", value: { machine: { idle_policy: { idle_seconds: 3600 } } } })
    expect(Number(idle.value.machine.revision)).toBeGreaterThan(Number(renamed.value.machine.revision))
    expect(reply(await stub.submit(team, alice, frame("cloud.machine.rename", { machine: "vm_00000000000000000009", name: "x" })))).toMatchObject({ t: "reject", code: "cloud.machine.not_found" })
    // Another team's principal is refused.
    const stranger = people().alice
    expect(await stub.readOp(team, stranger, "cloud.machine.get", { machine: m.id })).toMatchObject({ ok: false, code: "auth.forbidden" })
  })

  it("lists in stable keyset pages", async () => {
    const { team, alice, stub } = people()
    const ids: Array<string> = []
    for (let i = 0; i < 3; i++) ids.push((await create(stub, team, alice, undefined, `m${i}`)).value.machine.id)
    const p1 = await stub.readOp(team, alice, "cloud.machine.list", { limit: 2 })
    expect(p1.ok).toBe(true)
    expect(p1.value.machines.map((m: { id: string }) => m.id)).toEqual(ids.slice(0, 2))
    expect(typeof p1.value.next_cursor).toBe("string")
    // A new machine and a delete on page 1 do not shift page 2.
    ids.push((await create(stub, team, alice, undefined, "m3")).value.machine.id)
    reply(await stub.submit(team, alice, frame("cloud.machine.delete", { machine: ids[0] })))
    const p2 = await stub.readOp(team, alice, "cloud.machine.list", { limit: 2, cursor: p1.value.next_cursor })
    expect(p2.value.machines.map((m: { id: string }) => m.id)).toEqual(ids.slice(2, 4))
    expect(p2.value.next_cursor).toBeNull()
    expect(Number(p2.value.revision)).toBeGreaterThanOrEqual(Math.max(...p2.value.machines.map((m: { revision: string }) => Number(m.revision))))
    expect(await stub.readOp(team, alice, "cloud.machine.list", { cursor: "bogus" })).toMatchObject({ ok: false, code: "validation.invalid" })
  })

  it("answers the stub plan with this team's usage", async () => {
    const { team, alice, stub } = people()
    await create(stub, team, alice)
    const plan = await stub.readOp(team, alice, "cloud.plan.get", {})
    expect(plan.ok).toBe(true)
    expect(decodes(CloudPlan, plan.value)).toBe(true)
    expect(plan.value).toMatchObject({ plan_id: STUB_PLAN.plan_id, limits: { max_active: STUB_PLAN.max_active }, usage: { active: 1, saved: 0 } })
  })
})

describe("CloudDO review fixes (P2-3, P2-4, P3-8, P3-9)", { timeout: 60_000 }, () => {
  it("P2-3: a create whose machine id already has a row or a tombstone (a key re-sent after the ledger window) is refused, never upserted", () => {
    const { team, alice } = people()
    const id = "vm_0123456789abcdef0123"
    const config = { environment: "test", allowedTeams: new Set([team]), prefix: "cmuxnp-test-cld-", image: "cmuxnp-test-vmimg-fake" }
    const domain = cloudDomain(config)
    const ctx = (rows: MemoryRows) => ({ principal: alice, now: 1_000, tx: "tx-resent", newId: () => id, rows, idempotencyKey: "resent" })
    const live = new MemoryRows()
    live.apply([{ table: TABLE_MACHINE, op: "upsert", key: id, n: 1, row: { id, creator: alice.user } }])
    expect(domain.reduce({ ...domain.initial(), team }, "cloud.machine.create", { size: SIZE }, ctx(live))).toMatchObject({ ok: false, code: "idempotency.conflict" })
    const tomb = new MemoryRows()
    tomb.apply([{ table: TABLE_TOMBSTONE, op: "upsert", key: id, n: 2, row: { machine: id, deleted_at: 1, revision: "2" } }])
    expect(domain.reduce({ ...domain.initial(), team }, "cloud.machine.create", { size: SIZE }, ctx(tomb))).toMatchObject({ ok: false, code: "idempotency.conflict" })
  })

  it("P2-4: a delete while one is pending answers {deleted: true} and adds no ledger row", async () => {
    const { team, alice, stub } = people()
    const m = (await create(stub, team, alice)).value.machine
    await stub.fakeControl({ fail_next: 1 })
    expect(reply(await stub.submit(team, alice, frame("cloud.machine.delete", { machine: m.id }, "d-1")))).toMatchObject({ t: "reject", code: "mutation.indeterminate" })
    expect(await stub.fakeControl({})).toMatchObject({ pending: 1 })
    const second = await stub.submit(team, alice, frame("cloud.machine.delete", { machine: m.id }, "d-2"))
    expect(reply(second)).toMatchObject({ t: "result", value: { deleted: true } })
    expect(second.frames.find((f) => f.t === "request-settled")).toMatchObject({ sequence: 0 })
    expect(await stub.fakeControl({})).toMatchObject({ pending: 1 })
  })

  it("P2-4: create and delete are rate limited per team (cloud.rate_limited); a decided key still replays", async () => {
    const { team, alice, stub } = people()
    // A machine binds the object, so the refused delete below is recorded and replays.
    expect((await create(stub, team, alice)).t).toBe("result")
    const first = reply(await stub.submit(team, alice, frame("cloud.machine.delete", { machine: "vm_00000000000000000009" }, "rl-0")))
    expect(first).toMatchObject({ t: "reject", code: "cloud.machine.not_found" })
    let limited: ReturnType<typeof reply> | undefined
    for (let i = 1; i <= 40 && !limited; i++) {
      const r = reply(await stub.submit(team, alice, frame("cloud.machine.delete", { machine: "vm_00000000000000000009" }, `rl-${i}`)))
      if (r.code === "cloud.rate_limited") limited = r
    }
    expect(limited).toMatchObject({ t: "reject", code: "cloud.rate_limited", retryable: true })
    expect(reply(await stub.submit(team, alice, frame("cloud.machine.create", { size: SIZE })))).toMatchObject({ code: "cloud.rate_limited" })
    expect(reply(await stub.submit(team, alice, frame("cloud.machine.delete", { machine: "vm_00000000000000000009" }, "rl-0")))).toMatchObject({ code: "cloud.machine.not_found", replayed: true })
    // Reads and renames are not limited.
    expect(await stub.readOp(team, alice, "cloud.machine.list", {})).toMatchObject({ ok: true })
  })

  it("P3-8: an object bound while state.team is null still refuses another team, also before it is bound", async () => {
    const { team, alice, stub } = people()
    const stranger = people().alice
    expect(await stub.readOp(team, stranger, "cloud.machine.list", {})).toMatchObject({ ok: false, code: "auth.forbidden" })
    const res = await (stub as unknown as { fetch(r: Request): Promise<Response> }).fetch(
      new Request("https://cloud.test/wire", { headers: { Upgrade: "websocket", "x-cmux-entity": team, "x-cmux-principal": JSON.stringify(alice) } })
    )
    expect(res.status).toBe(101)
    res.webSocket?.accept()
    res.webSocket?.close()
    expect(await stub.readOp(team, stranger, "cloud.machine.list", {})).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(reply(await stub.submit(team, stranger, frame("cloud.machine.rename", { machine: "vm_00000000000000000009", name: "x" })))).toMatchObject({ code: "auth.forbidden" })
  })

  it("P3-9: a read needs an install grant that includes read", async () => {
    const { team, alice, stub } = people()
    const inst = "inst_0000000000000000009a"
    const noRead: Principal = { identity: `install:${inst}`, user: alice.user, team, kind: "install", install: inst, grant_classes: ["mutate-own"] }
    expect(await stub.readOp(team, noRead, "cloud.machine.list", {})).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await stub.readOp(team, noRead, "cloud.plan.get", {})).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await stub.readOp(team, { ...noRead, grant_classes: ["read"] }, "cloud.plan.get", {})).toMatchObject({ ok: true })
  })
})

describe("Cloud plan allowlist (P1-1)", { timeout: 60_000 }, () => {
  it("a team not on CLOUD_ALLOWED_TEAMS gets cloud.plan.required and no provider call; plan.get shows no plan", async () => {
    const { team, alice, stub } = people(false)
    expect(await create(stub, team, alice)).toMatchObject({ t: "reject", code: "cloud.plan.required" })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 0 })
    expect(await stub.readOp(team, alice, "cloud.plan.get", {})).toMatchObject({ ok: true, value: { plan_id: "none", limits: { max_active: 0 } } })
  })

  it("the stub plan exists only in development, staging and test, and only for listed teams", () => {
    for (const e of ["development", "staging", "test"]) expect(planFor(e, "team_a", new Set(["team_a"]))).not.toBeNull()
    for (const e of ["production", "local", "preview", ""]) expect(planFor(e, "team_a", new Set(["team_a"]))).toBeNull()
    expect(planFor("development", "team_b", new Set(["team_a"]))).toBeNull()
    expect(planFor("development", "team_a", new Set())).toBeNull()
    const base = { CLOUD_NAME_PREFIX: "cmuxnp-dev-cld-", CLOUD_FREESTYLE_API_KEY: "k", CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-dev-vmimg-1" }
    expect([...cloudConfig({ ENVIRONMENT: "development", ...base, CLOUD_ALLOWED_TEAMS: " team_a, team_b ,," } as never).allowedTeams]).toEqual(["team_a", "team_b"])
    expect(cloudConfig({ ENVIRONMENT: "development", ...base } as never).allowedTeams.size).toBe(0)
    // An unknown environment gets no provider either.
    expect(cloudConfig({ ENVIRONMENT: "preview", ...base, CLOUD_ALLOWED_TEAMS: "team_a" } as never)).toMatchObject({ prefix: null, image: null })
  })
})

describe("cloud driver prefix guard", () => {
  const counting = () => {
    const calls: Array<string> = []
    const raw: RawCloudDriver = {
      find: async (name) => (calls.push(`find:${name}`), null),
      create: async (name) => (calls.push(`create:${name}`), { id: "fs-1", tag: null }),
      delete: async (id) => void calls.push(`delete:${id}`)
    }
    return { calls, raw }
  }

  it("refuses any provider call on a name without this environment's prefix", async () => {
    const { calls, raw } = counting()
    const driver = new GuardedCloudDriver(raw, "cmuxnp-test-cld-")
    const tag = { team: "team_00000000000000000001", machine: "vm_00000000000000000001" }
    for (const name of [
      "cmux-vm-00000000000000000001",
      "cmuxnp-test-vm-00000000000000000001",
      "cmuxnp-test-tvm-vm-00000000000000000001",
      "cmuxnp-dev-cld-vm-00000000000000000001",
      "cmuxnp-test-cld-",
      "cmuxnp-test-cld-../x",
      "cmuxnp-test-cld-vm-0000000000000000001",
      "cmuxnp-test-cld-vm-000000000000000000011",
      "cmuxnp-test-cld-vm-0000000000000000000A",
      "cmuxnp-test-cld-vmimg-fake"
    ]) {
      await expect(driver.ensure(name, tag)).rejects.toBeInstanceOf(DriverError)
      await expect(driver.remove(name, tag)).rejects.toMatchObject({ code: "cloud.provider.refused", final: true })
    }
    expect(calls).toEqual([])
    await driver.ensure("cmuxnp-test-cld-vm-00000000000000000001", tag)
    expect(calls).toEqual(["find:cmuxnp-test-cld-vm-00000000000000000001", "create:cmuxnp-test-cld-vm-00000000000000000001"])
  })

  it("refuses a team VM lane name and a bare env name with the development prefix, and a prefix without a lane (FREESTYLE-NAMES)", async () => {
    const { calls, raw } = counting()
    const driver = new GuardedCloudDriver(raw, "cmuxnp-dev-cld-")
    const tag = { team: "team_00000000000000000001", machine: "vm_00000000000000000001" }
    for (const name of ["cmuxnp-dev-tvm-team-00000000000000000001-e1", "cmuxnp-dev-tvm-vm-00000000000000000001", "cmuxnp-dev-vm-00000000000000000001", "cmuxnp-dev-vmimg-vm-00000000000000000001"]) {
      await expect(driver.ensure(name, tag)).rejects.toMatchObject({ code: "cloud.provider.refused" })
    }
    expect(calls).toEqual([])
    expect(() => new GuardedCloudDriver(raw, "cmuxnp-dev-")).toThrow()
    expect(() => new GuardedCloudDriver(raw, "cmuxnp-dev-tvm-")).toThrow()
    expect(ENV_PREFIX).toEqual({ development: "cmuxnp-dev-cld-", staging: "cmuxnp-stg-cld-", production: "cmuxnp-prod-cld-", test: "cmuxnp-test-cld-" })
  })

  it("never adopts or deletes a VM under our name that another team or machine owns", async () => {
    const raw: RawCloudDriver = {
      find: async () => ({ id: "fs-9", tag: { cmux_next_team: "team_00000000000000000002", cmux_next_machine: "vm_00000000000000000001" } }),
      create: async () => {
        throw new Error("must not create")
      },
      delete: async () => {
        throw new Error("must not delete")
      }
    }
    const driver = new GuardedCloudDriver(raw, "cmuxnp-test-cld-")
    const tag = { team: "team_00000000000000000001", machine: "vm_00000000000000000001" }
    await expect(driver.ensure("cmuxnp-test-cld-vm-00000000000000000001", tag)).rejects.toMatchObject({ final: true })
    await expect(driver.remove("cmuxnp-test-cld-vm-00000000000000000001", tag)).rejects.toMatchObject({ final: true })
  })
})
