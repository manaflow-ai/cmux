import { env } from "cloudflare:workers"
import type { OwnerFrame, Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { MAX_ATTEMPTS, teamVmSlug } from "../src/domains/team-vm.ts"
import type { SubmitResult } from "../src/owner-do.ts"

/**
 * TVM-LEDGER (decision by a9, 2026-10-04): every team VM the lane creates has a durable ledger row
 * in its TeamVmDO. A create writes the intent before the provider call and confirms the id after;
 * an unconfirmed row is resolved by an EXACT name lookup; a delete accepts only a ledger id and
 * never the team's current VM; a provider VM that is in no ledger is never adopted or deleted.
 */
interface LedgerRow {
  name: string
  provider_id: string | null
  env: string
  team: string
  epoch: number
  created_by: string
  created_at: number
  state: string
  deleted_at: number | null
}
interface LedgerStub {
  ensureAwake(entity: string, principal: Principal, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin: "cli" }): Promise<SubmitResult>
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<unknown>
  fakeControl(cmd: { fail_next?: number; delete_all?: boolean; slug_prefix?: string; lose_next_create?: number; seed_vm?: { slug: string; id: string }; drop_ledger?: boolean }): Promise<{ creates: number; starts: number }>
  fakeVms(): Promise<string[]>
  fakeAlarm(aheadMs: number): Promise<void>
  ledger(entity: string): Promise<{ rows: LedgerRow[] }>
  reconcileLedger(entity: string): Promise<{ confirmed: number; absent: number; unresolved: number }>
  deleteVm(entity: string, providerId: string, by: string): Promise<{ ok: true } | { ok: false; code: string; message: string }>
}
const namespace = (env as unknown as { TEAM_VM_DO: DurableObjectNamespace }).TEAM_VM_DO
const stubFor = (team: string) => namespace.get(namespace.idFromName(team)) as unknown as LedgerStub
const ALICE = "user_00000000000000000171"
const principal = (team: string): Principal => ({ identity: `user:${ALICE}`, user: ALICE, team, kind: "session" })
let key = 0
const op = (name: string, params: unknown) => ({ t: "op" as const, op: name, params, idempotency_key: `lk${++key}`, origin: "cli" as const })
const result = (frames: ReadonlyArray<OwnerFrame>) => frames.find((x) => x.t === "result" || x.t === "reject") as { t: string; value?: Record<string, unknown> }
const PREFIX = "cmuxnp-stg-tvm-"

describe("team VM ledger", { timeout: 30_000 }, () => {
  it("a create writes the intent row before the provider call and confirms the id after", async () => {
    const T = "team_00000000000000000171"
    const stub = stubFor(T)
    const name = teamVmSlug(PREFIX, T, 1)
    await stub.fakeControl({ slug_prefix: PREFIX, lose_next_create: 1 })
    await stub.ensureAwake(T, principal(T), op("team_vm.ensure_awake", { reason: "ssh" }))
    // The answer was lost: the row holds the intent (name, env, team, who asked), not an id.
    const before = (await stub.ledger(T)).rows
    expect(before).toHaveLength(1)
    expect(before[0]).toMatchObject({ name, provider_id: null, env: "test", team: T, epoch: 1, created_by: `tvm:user:${ALICE}`, state: "unconfirmed", deleted_at: null })
    await stub.fakeAlarm(10 * 60_000)
    const after = (await stub.ledger(T)).rows
    expect(after).toHaveLength(1)
    expect(after[0]).toMatchObject({ name, provider_id: `fakevm-${name}`, state: "confirmed" })
  })

  it("delete accepts only a ledger id, never the team's current VM, and marks the row deleted", async () => {
    const T = "team_00000000000000000172"
    const stub = stubFor(T)
    await stub.fakeControl({ slug_prefix: PREFIX })
    const first = result((await stub.ensureAwake(T, principal(T), op("team_vm.ensure_awake", { reason: "ssh" }))).frames).value!.vm as string
    // A provider VM with the lane's prefix that no ledger holds: never deleted.
    await stub.fakeControl({ seed_vm: { slug: `${PREFIX}stranger`, id: "fakevm-stranger" } })
    expect(await stub.deleteVm(T, "fakevm-stranger", "test")).toMatchObject({ ok: false, code: "team_vm.not_in_ledger" })
    expect(await stub.fakeVms()).toContain("fakevm-stranger")
    // The team's current VM: a user still uses it, so it is never deleted on this path.
    expect(await stub.deleteVm(T, first, "test")).toMatchObject({ ok: false, code: "team_vm.in_use" })
    expect(await stub.fakeVms()).toContain(first)
    // Replace the VM (the old one is gone at the provider): the old ledger id is no longer in use.
    await stub.fakeControl({ delete_all: true })
    const second = result((await stub.ensureAwake(T, principal(T), op("team_vm.ensure_awake", { reason: "ssh" }))).frames).value!.vm as string
    expect(second).not.toBe(first)
    // The stranger is back at the provider (delete_all removed it); recreate it for the next check.
    await stub.fakeControl({ seed_vm: { slug: `${PREFIX}stranger`, id: "fakevm-stranger" } })
    expect(await stub.deleteVm(T, first, "test")).toEqual({ ok: true })
    const rows = (await stub.ledger(T)).rows
    expect(rows.find((r) => r.provider_id === first)).toMatchObject({ state: "deleted" })
    expect(rows.find((r) => r.provider_id === first)!.deleted_at).toBeGreaterThan(0)
    expect(rows.find((r) => r.provider_id === second)).toMatchObject({ state: "confirmed" })
    expect(await stub.fakeVms()).toEqual(expect.arrayContaining([second, "fakevm-stranger"]))
  })

  it("reconcile resolves an unconfirmed row by its exact name and never touches a VM outside the ledger", async () => {
    const T = "team_00000000000000000173"
    const stub = stubFor(T)
    const name = teamVmSlug(PREFIX, T, 1)
    await stub.fakeControl({ slug_prefix: PREFIX, lose_next_create: 1 })
    await stub.ensureAwake(T, principal(T), op("team_vm.ensure_awake", { reason: "ssh" }))
    // Every retry fails until the call is given up: the row stays unconfirmed with no pending create.
    await stub.fakeControl({ fail_next: 100 })
    for (let i = 0; i < MAX_ATTEMPTS + 1; i++) await stub.fakeAlarm(60 * 60_000)
    const status = (await stub.readOp(T, principal(T), "team_vm.status", {})) as { value: { status: string } }
    expect(status.value.status).toBe("failed")
    await stub.fakeControl({ fail_next: 0, seed_vm: { slug: `${PREFIX}${T.replace(/_/g, "-")}-e9`, id: "fakevm-lookalike" } })
    expect((await stub.ledger(T)).rows[0]).toMatchObject({ name, state: "unconfirmed" })
    expect(await stub.reconcileLedger(T)).toEqual({ confirmed: 1, absent: 0, unresolved: 0 })
    const rows = (await stub.ledger(T)).rows
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({ name, provider_id: `fakevm-${name}`, state: "confirmed" })
    // The look-alike (same prefix and team, never in a record) is neither adopted nor deleted.
    expect(rows.some((r) => r.provider_id === "fakevm-lookalike")).toBe(false)
    expect(await stub.fakeVms()).toContain("fakevm-lookalike")
  })

  it("a VM confirmed for the epoch a create still targets is never deleted, and the next create reuses it", async () => {
    const T = "team_00000000000000000176"
    const stub = stubFor(T)
    const name = teamVmSlug(PREFIX, T, 1)
    await stub.fakeControl({ slug_prefix: PREFIX, lose_next_create: 1 })
    await stub.ensureAwake(T, principal(T), op("team_vm.ensure_awake", { reason: "ssh" }))
    await stub.fakeControl({ fail_next: 100 })
    for (let i = 0; i < MAX_ATTEMPTS + 1; i++) await stub.fakeAlarm(60 * 60_000)
    await stub.fakeControl({ fail_next: 0 })
    expect(await stub.reconcileLedger(T)).toEqual({ confirmed: 1, absent: 0, unresolved: 0 })
    // The row is for epoch 1 while the record is still at epoch 0: the next create would make it current.
    expect(await stub.deleteVm(T, `fakevm-${name}`, "test")).toMatchObject({ ok: false, code: "team_vm.in_use" })
    expect(await stub.fakeVms()).toContain(`fakevm-${name}`)
    // A deploy changes the prefix; the next wake creates under the confirmed row's name, not a new one.
    await stub.fakeControl({ slug_prefix: "cmuxnp-xyz-tvm-" })
    const r = result((await stub.ensureAwake(T, principal(T), op("team_vm.ensure_awake", { reason: "ssh" }))).frames)
    expect(r.value).toMatchObject({ status: "running", epoch: 1, vm: `fakevm-${name}` })
    expect(await stub.fakeControl({})).toMatchObject({ creates: 1 })
    expect((await stub.ledger(T)).rows).toHaveLength(1)
  })

  it("an unconfirmed row whose name the provider does not know becomes absent", async () => {
    const T = "team_00000000000000000174"
    const stub = stubFor(T)
    await stub.fakeControl({ slug_prefix: PREFIX, fail_next: 100 })
    for (let i = 0; i < MAX_ATTEMPTS + 1; i++) {
      if (i === 0) await stub.ensureAwake(T, principal(T), op("team_vm.ensure_awake", { reason: "ssh" }))
      else await stub.fakeAlarm(60 * 60_000)
    }
    await stub.fakeControl({ fail_next: 0 })
    expect(await stub.reconcileLedger(T)).toEqual({ confirmed: 0, absent: 1, unresolved: 0 })
    expect((await stub.ledger(T)).rows[0]).toMatchObject({ state: "absent", provider_id: null })
  })

  it("a team VM from before the ledger enters it from the stored record, marked backfilled", async () => {
    const T = "team_00000000000000000175"
    const stub = stubFor(T)
    await stub.fakeControl({ slug_prefix: "cmuxnp-dev-tvm-" })
    const vm = result((await stub.ensureAwake(T, principal(T), op("team_vm.ensure_awake", { reason: "ssh" }))).frames).value!.vm as string
    await stub.fakeControl({ drop_ledger: true })
    const rows = (await stub.ledger(T)).rows
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({ name: teamVmSlug("cmuxnp-dev-tvm-", T, 1), provider_id: vm, team: T, epoch: 1, created_by: "backfill", state: "backfilled" })
  })
})
