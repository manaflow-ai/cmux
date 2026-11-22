import { env } from "cloudflare:workers"
import type { OwnerFrame, Principal, ReduceContext, SqlStore } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { MAX_ATTEMPTS, teamVmDomain, teamVmSlug, teamVmWakeAt, type TeamVmState } from "../src/domains/team-vm.ts"
import type { SubmitResult } from "../src/owner-do.ts"
import type { Env } from "../src/env.ts"
import { FreestyleDriver, PRODUCTION_PLAN_GATE_LANDED, providerRefusal, teamVmDriver } from "../src/team-vm-driver.ts"

/** The RPC surface the tests use (the generated stub type does not carry these signatures). */
interface TeamVmStub {
  ensureAwake(entity: string, principal: Principal, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin: "cli" }): Promise<SubmitResult>
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<unknown>
  fakeControl(cmd: { fail_next?: number; pause_all?: boolean; delete_all?: boolean; slug_prefix?: string; lose_next_create?: number }): Promise<{ creates: number; starts: number }>
  fakeAlarm(aheadMs: number): Promise<void>
  bindInstall(entity: string, install: string, epoch: number): Promise<SubmitResult>
  journalAppend(entity: string, principal: Principal, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin: "cli" }): Promise<SubmitResult>
}
const namespace = (env as unknown as { TEAM_VM_DO: DurableObjectNamespace }).TEAM_VM_DO
const ns = { get: (id: DurableObjectId) => namespace.get(id) as unknown as TeamVmStub, idFromName: (n: string) => namespace.idFromName(n) }
const TEAM = "team_00000000000000000071"
const OTHER = "team_00000000000000000072"
const ALICE = "user_00000000000000000071"

let txn = 0
const ctx = (p: Principal, now = 1_000_000 + txn): ReduceContext => ({ principal: p, now, tx: `tx${++txn}`, newId: (x) => `${x}_${String(txn).padStart(20, "0")}` })
const alice: Principal = { identity: `user:${ALICE}`, user: ALICE, team: TEAM, kind: "session" }
const install: Principal = { identity: "install:inst_00000000000000000071", user: ALICE, team: TEAM, kind: "install", install: "inst_00000000000000000071", grant_classes: ["read", "mutate-own"] }
const system: Principal = { identity: "system:team_vm", kind: "system" }

const apply = (s: TeamVmState, op: string, params: unknown, p: Principal, now?: number) => {
  const denied = teamVmDomain.authorize?.(s, op, params, p)
  if (denied) return { ok: false as const, ...denied }
  return teamVmDomain.reduce(s, op, params, ctx(p, now))
}
const must = (r: ReturnType<typeof apply>) => {
  if (!r.ok) throw new Error(`${r.code}: ${r.message}`)
  return r
}

describe("team VM reducer", () => {
  it("first ensure_awake binds the team, takes a lease and asks for a create", () => {
    const r = must(apply(teamVmDomain.initial(), "team_vm.ensure_awake", { reason: "ssh" }, alice, 5_000))
    expect(r.state).toMatchObject({ team: TEAM, status: "provisioning", pending: { action: "create", attempts: 0 } })
    expect(r.value).toMatchObject({ status: "provisioning", vm: null, epoch: 0, expires_at: 5_000 + 600_000 })
    expect(teamVmWakeAt(r.state)).toBe(5_000 + 30_000)
  })

  it("refuses another team, an unknown op from a system principal, and an install whose grant lacks the risk", () => {
    const s = must(apply(teamVmDomain.initial(), "team_vm.ensure_awake", { reason: "ssh" }, alice)).state
    expect(apply(s, "team_vm.ensure_awake", { reason: "ssh" }, { ...alice, team: OTHER })).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(apply(s, "team_vm.ensure_awake", { reason: "ssh" }, system)).toMatchObject({ ok: false })
    expect(apply(s, "team_vm.ensure_awake", { reason: "ssh" }, install)).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(apply(s, "team_vm.driver_result", { action: "create", epoch: 0, ok: true, vm: "vm1", slug: "x" }, alice)).toMatchObject({ ok: false })
  })

  it("a create result sets the VM and epoch once; a duplicate result changes nothing", () => {
    const s0 = must(apply(teamVmDomain.initial(), "team_vm.ensure_awake", { reason: "ssh" }, alice)).state
    const r = must(apply(s0, "team_vm.driver_result", { action: "create", epoch: 0, ok: true, vm: "vm1", slug: "s-e1", observed: "running" }, system))
    expect(r.state).toMatchObject({ vm: "vm1", slug: "s-e1", epoch: 1, status: "running", pending: null })
    const dup = must(apply(r.state, "team_vm.driver_result", { action: "create", epoch: 0, ok: true, vm: "vm2", slug: "s-e1", observed: "running" }, system))
    expect(dup.changed).toBe(false)
    expect(dup.state.vm).toBe("vm1")
  })

  it("an existing VM is always started again (the provider may have paused it)", () => {
    let s = must(apply(teamVmDomain.initial(), "team_vm.ensure_awake", { reason: "ssh" }, alice)).state
    s = must(apply(s, "team_vm.driver_result", { action: "create", epoch: 0, ok: true, vm: "vm1", slug: "s-e1", observed: "running" }, system)).state
    const r = must(apply(s, "team_vm.ensure_awake", { reason: "tasks" }, alice))
    expect(r.state.pending).toMatchObject({ action: "start" })
    expect(r.state.status).toBe("running")
    const paused = must(apply(r.state, "team_vm.driver_result", { action: "start", epoch: 1, ok: true, observed: "running" }, system))
    expect(paused.state).toMatchObject({ pending: null, status: "running" })
  })

  it("failures back off and give up after the attempt limit; the next ensure_awake starts again", () => {
    let s = must(apply(teamVmDomain.initial(), "team_vm.ensure_awake", { reason: "ssh" }, alice, 0)).state
    for (let i = 1; i < MAX_ATTEMPTS; i++) {
      s = must(apply(s, "team_vm.driver_result", { action: "create", epoch: 0, ok: false, error: { code: "team_vm.provider_failed", message: "503" } }, system, 0)).state
      expect(s.pending).toMatchObject({ attempts: i, retry_at: Math.min(300_000, 1000 * 2 ** i) })
    }
    s = must(apply(s, "team_vm.driver_result", { action: "create", epoch: 0, ok: false, error: { code: "team_vm.provider_failed", message: "503" } }, system, 0)).state
    expect(s).toMatchObject({ status: "failed", pending: null, last_error: { code: "team_vm.provider_failed" } })
    const again = must(apply(s, "team_vm.ensure_awake", { reason: "ssh" }, alice))
    expect(again.state.pending).toMatchObject({ action: "create", attempts: 0 })
  })

  it("the same holder and reason renew one lease", () => {
    const a = must(apply(teamVmDomain.initial(), "team_vm.ensure_awake", { reason: "ssh", lease_seconds: 60 }, alice, 1_000))
    const b = must(apply(a.state, "team_vm.ensure_awake", { reason: "ssh", lease_seconds: 600 }, alice, 2_000))
    expect((b.value as { lease: string }).lease).toBe((a.value as { lease: string }).lease)
    expect(Object.keys(b.state.leases).length).toBe(1)
    expect((b.value as { expires_at: number }).expires_at).toBe(602_000)
    const c = must(apply(b.state, "team_vm.ensure_awake", { reason: "tasks" }, alice, 3_000))
    expect(Object.keys(c.state.leases).length).toBe(2)
  })

  it("a deleted VM is replaced under the next epoch; stale and malformed results cannot wedge the record", () => {
    let s = must(apply(teamVmDomain.initial(), "team_vm.ensure_awake", { reason: "ssh" }, alice)).state
    s = must(apply(s, "team_vm.driver_result", { action: "create", epoch: 0, ok: true, vm: "vm1", slug: "s-e1", observed: "running" }, system)).state
    s = must(apply(s, "team_vm.ensure_awake", { reason: "tasks" }, alice)).state
    // A start result for another epoch changes nothing.
    expect(must(apply(s, "team_vm.driver_result", { action: "start", epoch: 0, ok: true, observed: "running" }, system)).changed).toBe(false)
    s = must(apply(s, "team_vm.driver_result", { action: "start", epoch: 1, ok: false, error: { code: "team_vm.vm_missing", message: "read VM: 404" }, final: true }, system)).state
    expect(s).toMatchObject({ vm: null, status: "provisioning", epoch: 1, pending: { action: "create", attempts: 0 } })
    expect(teamVmSlug("p-", TEAM, s.epoch + 1)).toBe("p-team-00000000000000000071-e2")
    // A create "success" without an id is a final failure, not a reject that would leave the call due.
    const bad = must(apply(s, "team_vm.driver_result", { action: "create", epoch: 1, ok: true, slug: "s-e2" }, system))
    expect(bad.state).toMatchObject({ status: "failed", pending: null, last_error: { code: "team_vm.provider_refused" } })
  })

  it("binds the VM's install once per epoch, and a new VM clears the binding", () => {
    let s = must(apply(teamVmDomain.initial(), "team_vm.ensure_awake", { reason: "ssh" }, alice)).state
    expect(apply(s, "team_vm.bind_install", { install: "inst_00000000000000000081", epoch: 0 }, system)).toMatchObject({ ok: false, code: "team_vm.stale_epoch" })
    s = must(apply(s, "team_vm.driver_result", { action: "create", epoch: 0, ok: true, vm: "vm1", slug: "s-e1", observed: "running" }, system)).state
    expect(apply(s, "team_vm.bind_install", { install: "inst_00000000000000000081", epoch: 1 }, alice)).toMatchObject({ ok: false })
    s = must(apply(s, "team_vm.bind_install", { install: "inst_00000000000000000081", epoch: 1 }, system)).state
    expect(s.vm_install).toBe("inst_00000000000000000081")
    expect(apply(s, "team_vm.bind_install", { install: "inst_00000000000000000082", epoch: 1 }, system)).toMatchObject({ ok: false, code: "team_vm.already_bound" })
    s = must(apply(s, "team_vm.ensure_awake", { reason: "tasks" }, alice)).state
    s = must(apply(s, "team_vm.driver_result", { action: "start", epoch: 1, ok: false, error: { code: "team_vm.vm_missing", message: "read VM: 404" }, final: true }, system)).state
    expect(s.vm_install).toBeNull()
  })

  it("only the holder releases a lease; expiry drops past leases only", () => {
    const r = must(apply(teamVmDomain.initial(), "team_vm.ensure_awake", { reason: "ssh", lease_seconds: 60 }, alice, 1_000))
    const lease = (r.value as { lease: string }).lease
    expect(apply(r.state, "team_vm.lease.release", { lease }, { ...alice, identity: "user:someone-else" })).toMatchObject({ ok: false, code: "auth.forbidden" })
    const kept = must(apply(r.state, "team_vm.leases_expire", { now: 60_000 }, system))
    expect(kept.changed).toBe(false)
    const gone = must(apply(r.state, "team_vm.leases_expire", { now: 61_000 }, system))
    expect(Object.keys(gone.state.leases)).toEqual([])
    expect(must(apply(r.state, "team_vm.lease.release", { lease }, alice)).state.leases).toEqual({})
  })

  it("production refuses every provider call until the plan gate lands", () => {
    expect(PRODUCTION_PLAN_GATE_LANDED).toBe(false)
    expect(providerRefusal({ ENVIRONMENT: "production" })).toBe("team_vm.plan_gate_missing")
    expect(providerRefusal({ ENVIRONMENT: "staging" })).toBeNull()
    expect(providerRefusal({ ENVIRONMENT: "test" })).toBeNull()
    expect(providerRefusal({ ENVIRONMENT: "production" }, true)).toBeNull()
  })

  it("slugs are per team and epoch and fit the provider's 63 characters", () => {
    const slug = teamVmSlug("cmuxnp-dev-tvm-", TEAM, 1)
    expect(slug).toBe("cmuxnp-dev-tvm-team-00000000000000000071-e1")
    expect(slug.length).toBeLessThanOrEqual(63)
    expect(teamVmSlug("cmuxnp-stg-tvm-", TEAM, 1)).toBe("cmuxnp-stg-tvm-team-00000000000000000071-e1")
  })

  it("each environment creates new VMs only under its own cmuxnp-<env>- prefix (FREESTYLE-NAMES)", () => {
    // Constructing a driver makes no provider call; the SQL store is used only by the fake.
    const sql = {} as SqlStore
    const cfg = (ENVIRONMENT: string, TEAM_VM_SLUG_PREFIX: string) => ({ ENVIRONMENT, TEAM_VM_SLUG_PREFIX, FREESTYLE_API_KEY: "k", TEAM_VM_SNAPSHOT: "snap" }) as unknown as Env
    expect(teamVmDriver(cfg("development", "cmuxnp-dev-tvm-"), sql)).toBeInstanceOf(FreestyleDriver)
    expect(teamVmDriver(cfg("staging", "cmuxnp-stg-tvm-"), sql)).toBeInstanceOf(FreestyleDriver)
    expect(teamVmDriver(cfg("staging", "cmuxnp-dev-tvm-"), sql)).toBeNull()
    expect(teamVmDriver(cfg("development", "cmuxnp-stg-tvm-"), sql)).toBeNull()
    expect(teamVmDriver(cfg("staging", "cmux-tvm-"), sql)).toBeNull()
    expect(teamVmDriver(cfg("local", "cmuxnp-stg-tvm-"), sql)).toBeNull()
  })
})

const result = (frames: ReadonlyArray<OwnerFrame>) => {
  const f = frames.find((x) => x.t === "result" || x.t === "reject")
  if (!f) throw new Error("no result")
  return f as { t: string; value?: Record<string, unknown>; code?: string }
}
let key = 0
const op = (name: string, params: unknown) => ({ t: "op" as const, op: name, params, idempotency_key: `k${++key}`, origin: "cli" as const })

describe("TeamVmDO with the fake provider", { timeout: 30_000 }, () => {
  it("creates the VM once, answers with the running VM, and resumes it after a pause", async () => {
    const stub = ns.get(ns.idFromName(TEAM))
    const first = result((await stub.ensureAwake(TEAM, alice, op("team_vm.ensure_awake", { reason: "ssh" }))).frames)
    expect(first.t).toBe("result")
    expect(first.value).toMatchObject({ status: "running", epoch: 1, vm: `fakevm-${teamVmSlug("", TEAM, 1)}` })
    expect(await stub.fakeControl({})).toEqual({ creates: 1, starts: 0 })
    // A second wake never creates again.
    await stub.ensureAwake(TEAM, alice, op("team_vm.ensure_awake", { reason: "tasks" }))
    expect(await stub.fakeControl({})).toEqual({ creates: 1, starts: 0 })
    // The provider paused it on idle: the next wake starts it.
    await stub.fakeControl({ pause_all: true })
    const woke = result((await stub.ensureAwake(TEAM, alice, op("team_vm.ensure_awake", { reason: "mail" }))).frames)
    expect(woke.value).toMatchObject({ status: "running", epoch: 1 })
    expect(await stub.fakeControl({})).toEqual({ creates: 1, starts: 1 })
    const status = (await stub.readOp(TEAM, alice, "team_vm.status", {})) as { ok: boolean; value: { leases: Array<unknown>; status: string } }
    expect(status.ok).toBe(true)
    expect(status.value.status).toBe("running")
    expect(status.value.leases.length).toBe(3)
  })

  it("a failed provider call stays pending and the alarm finishes it", async () => {
    const T = "team_00000000000000000073"
    const stub = ns.get(ns.idFromName(T))
    const p = { ...alice, team: T }
    // Bind the object, then make the next provider call fail.
    await stub.fakeControl({ fail_next: 1 })
    const r = result((await stub.ensureAwake(T, p, op("team_vm.ensure_awake", { reason: "ssh" }))).frames)
    expect(r.value).toMatchObject({ status: "provisioning", vm: null })
    const before = (await stub.readOp(T, p, "team_vm.status", {})) as { value: { last_error: { code: string } | null } }
    expect(before.value.last_error?.code).toBe("team_vm.provider_failed")
    // The retry is due after the backoff; run the alarm's work as if that time had come.
    await stub.fakeAlarm(10 * 60_000)
    const done = (await stub.readOp(T, p, "team_vm.status", {})) as { value: { status: string; epoch: number } }
    expect(done.value).toMatchObject({ status: "running", epoch: 1 })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1 })
  })

  it("replaces a VM that was deleted outside cmux with a new one under the next epoch", async () => {
    const T = "team_00000000000000000074"
    const stub = ns.get(ns.idFromName(T))
    const p = { ...alice, team: T }
    result((await stub.ensureAwake(T, p, op("team_vm.ensure_awake", { reason: "ssh" }))).frames)
    await stub.fakeControl({ delete_all: true })
    const r = result((await stub.ensureAwake(T, p, op("team_vm.ensure_awake", { reason: "ssh" }))).frames)
    expect(r.value).toMatchObject({ status: "running", epoch: 2, vm: `fakevm-${teamVmSlug("", T, 2)}` })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 2 })
  })

  it("a team whose VM has the old cmuxnp-dev-tvm- name keeps it after the prefix moves to cmuxnp-stg-tvm-", async () => {
    const T = "team_00000000000000000079"
    const stub = ns.get(ns.idFromName(T))
    const p = { ...alice, team: T }
    // Staging before the FREESTYLE-NAMES change: the VM is created under the old prefix.
    await stub.fakeControl({ slug_prefix: "cmuxnp-dev-tvm-" })
    const old = `fakevm-${teamVmSlug("cmuxnp-dev-tvm-", T, 1)}`
    expect(result((await stub.ensureAwake(T, p, op("team_vm.ensure_awake", { reason: "ssh" }))).frames).value).toMatchObject({ status: "running", epoch: 1, vm: old })
    // The prefix changes and the provider pauses the VM: the wake resumes the same VM by its stored id.
    await stub.fakeControl({ slug_prefix: "cmuxnp-stg-tvm-", pause_all: true })
    expect(result((await stub.ensureAwake(T, p, op("team_vm.ensure_awake", { reason: "ssh" }))).frames).value).toMatchObject({ status: "running", epoch: 1, vm: old })
    expect(await stub.fakeControl({})).toEqual({ creates: 1, starts: 1 })
    const status = (await stub.readOp(T, p, "team_vm.status", {})) as { value: { vm: string; epoch: number } }
    expect(status.value).toMatchObject({ vm: old, epoch: 1 })
    // Only a NEW VM (here a replacement after an outside delete) gets the new name.
    await stub.fakeControl({ delete_all: true })
    const fresh = result((await stub.ensureAwake(T, p, op("team_vm.ensure_awake", { reason: "ssh" }))).frames)
    expect(fresh.value).toMatchObject({ status: "running", epoch: 2, vm: `fakevm-${teamVmSlug("cmuxnp-stg-tvm-", T, 2)}` })
  })

  it("a create whose answer was lost across a prefix change retries under the slug it first tried", async () => {
    const T = "team_00000000000000000080"
    const stub = ns.get(ns.idFromName(T))
    const p = { ...alice, team: T }
    // Old config: the create happens at the provider, but its answer is lost (timeout); the call stays pending.
    await stub.fakeControl({ slug_prefix: "cmuxnp-dev-tvm-", lose_next_create: 1 })
    const r = result((await stub.ensureAwake(T, p, op("team_vm.ensure_awake", { reason: "ssh" }))).frames)
    expect(r.value).toMatchObject({ status: "provisioning", vm: null })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1 })
    // A deploy changes the prefix before the retry: the retry must find the VM under the slug it first tried.
    await stub.fakeControl({ slug_prefix: "cmuxnp-stg-tvm-" })
    await stub.fakeAlarm(10 * 60_000)
    const done = (await stub.readOp(T, p, "team_vm.status", {})) as { value: { status: string; epoch: number; vm: string } }
    expect(done.value).toMatchObject({ status: "running", epoch: 1, vm: `fakevm-${teamVmSlug("cmuxnp-dev-tvm-", T, 1)}` })
    // No second VM: the provider saw one create.
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1 })
  })

  it("refuses a principal of another team", async () => {
    const stub = ns.get(ns.idFromName(TEAM))
    const r = result((await stub.ensureAwake(TEAM, { ...alice, team: OTHER }, op("team_vm.ensure_awake", { reason: "ssh" }))).frames)
    expect(r).toMatchObject({ t: "reject", code: "auth.forbidden" })
  })
})

const enc = new TextEncoder()
const b64 = (t: string) => btoa(t)
const hex = async (t: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(t))), (b) => b.toString(16).padStart(2, "0")).join("")
const append = async (stub: TeamVmStub, team: string, p: Principal, a: { stream: string; epoch: number; first: number; last: number; text: string; sha?: string }) =>
  result(
    (
      await stub.journalAppend(team, p, op("team_vm.journal.append", { stream: a.stream, epoch: a.epoch, first_seq: a.first, last_seq: a.last, bytes: b64(a.text), sha256: a.sha ?? (await hex(a.text)) }))
    ).frames
  )

describe("team journal in TeamVmDO", { timeout: 30_000 }, () => {
  const T = "team_00000000000000000075"
  const VM_INSTALL = "inst_00000000000000000075"
  const vm: Principal = { identity: `install:${VM_INSTALL}`, user: ALICE, team: T, kind: "install", install: VM_INSTALL, grant_classes: ["read", "mutate-own"] }

  it("only the bound VM install appends; ranges are contiguous, replays return the stored ack, other replays conflict", async () => {
    const stub = ns.get(ns.idFromName(T))
    await stub.ensureAwake(T, { ...alice, team: T }, op("team_vm.ensure_awake", { reason: "ssh" }))
    expect(await append(stub, T, vm, { stream: "tasks", epoch: 1, first: 1, last: 3, text: "a" })).toMatchObject({ t: "reject", code: "team_vm.not_bound" })
    result((await stub.bindInstall(T, VM_INSTALL, 1)).frames)
    // A member's session and another install of the team are refused: the journal holds every person's files.
    expect(await append(stub, T, { ...alice, team: T }, { stream: "tasks", epoch: 1, first: 1, last: 3, text: "a" })).toMatchObject({ t: "reject", code: "auth.forbidden" })
    expect(await append(stub, T, { ...vm, install: "inst_00000000000000000076", identity: "install:x" }, { stream: "tasks", epoch: 1, first: 1, last: 3, text: "a" })).toMatchObject({
      t: "reject",
      code: "auth.forbidden"
    })
    expect(await append(stub, T, vm, { stream: "tasks", epoch: 1, first: 1, last: 3, text: "ops 1-3" })).toMatchObject({ t: "result", value: { high_water: 3, replayed: false } })
    expect(await append(stub, T, vm, { stream: "tasks", epoch: 1, first: 1, last: 3, text: "ops 1-3" })).toMatchObject({ t: "result", value: { high_water: 3, replayed: true } })
    expect(await append(stub, T, vm, { stream: "tasks", epoch: 1, first: 1, last: 3, text: "different" })).toMatchObject({ t: "reject", code: "journal.conflict" })
    expect(await append(stub, T, vm, { stream: "tasks", epoch: 1, first: 5, last: 5, text: "gap" })).toMatchObject({ t: "reject", code: "journal.gap", details: { high_water: 3 } })
    expect(await append(stub, T, vm, { stream: "tasks", epoch: 0, first: 4, last: 4, text: "old" })).toMatchObject({ t: "reject", code: "journal.stale_epoch" })
    expect(await append(stub, T, vm, { stream: "tasks", epoch: 1, first: 4, last: 4, text: "x", sha: "0".repeat(64) })).toMatchObject({ t: "reject", code: "validation.invalid" })
    expect(await append(stub, T, vm, { stream: "tasks", epoch: 1, first: 4, last: 6, text: "ops 4-6" })).toMatchObject({ t: "result", value: { high_water: 6 } })
    // A range wider than 100,000 seqs is refused, so no writer can push the seq out of safe integers.
    expect(await append(stub, T, vm, { stream: "tasks", epoch: 1, first: 7, last: 7 + 100_000, text: "wide" })).toMatchObject({ t: "reject", code: "validation.invalid" })
    // Streams are independent.
    expect(await append(stub, T, vm, { stream: "mail", epoch: 1, first: 1, last: 1, text: "msg" })).toMatchObject({ t: "result", value: { high_water: 1 } })
  })

  it("reads whole entries back for restore, only for the VM install", async () => {
    const stub = ns.get(ns.idFromName(T))
    const hw = (await stub.readOp(T, vm, "team_vm.journal.high_water", { stream: "tasks" })) as { ok: boolean; value: { high_water: number; epoch: number } }
    expect(hw).toMatchObject({ ok: true, value: { high_water: 6, epoch: 1 } })
    const r = (await stub.readOp(T, vm, "team_vm.journal.read", { stream: "tasks", from_seq: 2 })) as { ok: boolean; value: { entries: Array<{ first_seq: number; last_seq: number; bytes: string }>; more: boolean } }
    expect(r.ok).toBe(true)
    expect(r.value.entries.map((e) => [e.first_seq, e.last_seq, atob(e.bytes)])).toEqual([
      [1, 3, "ops 1-3"],
      [4, 6, "ops 4-6"]
    ])
    expect(r.value.more).toBe(false)
    expect(await stub.readOp(T, { ...alice, team: T }, "team_vm.journal.read", { stream: "tasks", from_seq: 1 })).toMatchObject({ ok: false, code: "auth.forbidden" })
  })
})
