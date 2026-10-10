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

})

describe("Cloud plan allowlist (P1-1)", { timeout: 60_000 }, () => {

})

describe("cloud driver prefix guard", () => {
  const EDGE_RULE = { action: "allow", domain: "coderouter.cmux.internal", source: {}, destination: { host: "coderouter.example.com", port: 443 }, transform: [{ headers: { "x-chatmux-vm-authorization": "Bearer t" } }] } as const
  const counting = () => {
    const calls: Array<string> = []
    const raw: RawCloudDriver = {
      find: async (name) => (calls.push(`find:${name}`), null),
      create: async (name) => (calls.push(`create:${name}`), { id: "fs-1", tag: null }),
      delete: async (id) => void calls.push(`delete:${id}`),
      list: async () => ({ vms: [], total: 0 }),
      writeFile: async () => {},
      pause: async (id) => void calls.push(`pause:${id}`),
      start: async (id) => void calls.push(`start:${id}`),
      state: async () => null,
      resize: async (id) => void calls.push(`resize:${id}`),
      resources: async () => null,
      findSnapshot: async (slug) => (calls.push(`findSnapshot:${slug}`), null),
      createSnapshot: async (id) => (calls.push(`createSnapshot:${id}`), { id: "sh-1" }),
      deleteSnapshot: async (id) => void calls.push(`deleteSnapshot:${id}`),
      replaceTlsRule: async (id) => (calls.push(`replaceTlsRule:${id}`), true)
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
      await expect(driver.ensure(name, tag, { idleSeconds: 0 })).rejects.toBeInstanceOf(DriverError)
      await expect(driver.remove(name, tag)).rejects.toMatchObject({ code: "cloud.provider.refused", final: true })
      // Money ops (CLOUDDO-MONEY-OPS): pause and start never touch a name outside the prefix either.
      await expect(driver.power(name, tag, "pause")).rejects.toMatchObject({ code: "cloud.provider.refused", final: true })
      await expect(driver.power(name, tag, "start")).rejects.toMatchObject({ code: "cloud.provider.refused", final: true })
      await expect(driver.resize(name, tag, { cpu: 4, memory: 8192, storage: 16384 })).rejects.toMatchObject({ code: "cloud.provider.refused", final: true })
      await expect(driver.snapshot(name, tag, "cmuxnp-test-cld-snap-00000000000000000001")).rejects.toMatchObject({ code: "cloud.provider.refused", final: true })
      // The coderouter edge token refresh (cloud-coderouter-edge.ts) never touches a name outside the prefix either.
      await expect(driver.replaceEdgeRule(name, tag, EDGE_RULE)).rejects.toMatchObject({ code: "cloud.provider.refused", final: true })
    }
    // Snapshot slugs carry the prefix and the snap- tail, also for a restore's boot snapshot.
    for (const slug of ["cmuxnp-test-cld-vm-00000000000000000001", "cmuxnp-dev-cld-snap-00000000000000000001", "freestyle/ubuntu", "cmuxnp-test-cld-snap-x"]) {
      await expect(driver.removeSnapshot(slug)).rejects.toMatchObject({ code: "cloud.provider.refused", final: true })
      await expect(driver.ensure("cmuxnp-test-cld-vm-00000000000000000001", tag, { idleSeconds: 0, snapshot: slug })).rejects.toMatchObject({ code: "cloud.provider.refused" })
    }
    expect(calls).toEqual([])
    await driver.ensure("cmuxnp-test-cld-vm-00000000000000000001", tag, { idleSeconds: 0 })
    expect(calls).toEqual(["find:cmuxnp-test-cld-vm-00000000000000000001", "create:cmuxnp-test-cld-vm-00000000000000000001"])
  })

  it("refuses a team VM lane name and a bare env name with the development prefix, and a prefix without a lane (FREESTYLE-NAMES)", async () => {
    const { calls, raw } = counting()
    const driver = new GuardedCloudDriver(raw, "cmuxnp-dev-cld-")
    const tag = { team: "team_00000000000000000001", machine: "vm_00000000000000000001" }
    for (const name of ["cmuxnp-dev-tvm-team-00000000000000000001-e1", "cmuxnp-dev-tvm-vm-00000000000000000001", "cmuxnp-dev-vm-00000000000000000001", "cmuxnp-dev-vmimg-vm-00000000000000000001"]) {
      await expect(driver.ensure(name, tag, { idleSeconds: 0 })).rejects.toMatchObject({ code: "cloud.provider.refused" })
    }
    expect(calls).toEqual([])
    expect(() => new GuardedCloudDriver(raw, "cmuxnp-dev-")).toThrow()
    expect(() => new GuardedCloudDriver(raw, "cmuxnp-dev-tvm-")).toThrow()
    expect(ENV_PREFIX).toEqual({ development: "cmuxnp-dev-cld-", staging: "cmuxnp-stg-cld-", production: "cmuxnp-prod-cld-", test: "cmuxnp-test-cld-" })
  })

})
