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

