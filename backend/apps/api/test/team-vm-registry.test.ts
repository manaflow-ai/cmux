import { env } from "cloudflare:workers"
import type { OwnerFrame, Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { teamVmSlug } from "../src/domains/team-vm.ts"
import type { Env } from "../src/env.ts"
import type { SubmitResult } from "../src/owner-do.ts"
import { handleTeamVmAdmin, TEAM_VM_REGISTRY } from "../src/team-vm-admin.ts"

/**
 * The team VM registry (a9, 2026-10-04): one reserved TeamVmDO instance knows every team that has a
 * team VM and keeps the counts. The ledger write path sends one event per confirmed create,
 * backfill and delete, idempotent by provider id, so a retried event never counts twice. No cron:
 * the prefix report runs on demand only, and it is report-only (it never adopts, deletes or writes).
 */
interface Counts {
  teams: number
  created: number
  backfilled: number
  deleted: number
  live: number
}
interface Report {
  prefix: string
  listed: number
  matched: number
  in_registry: number
  not_in_registry: string[]
  truncated: boolean
}
interface Stub {
  ensureAwake(entity: string, principal: Principal, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin: "cli" }): Promise<SubmitResult>
  fakeControl(cmd: { delete_all?: boolean; slug_prefix?: string; seed_vm?: { slug: string; id: string }; drop_ledger?: boolean; drop_registry?: boolean; reset_registry_seed?: boolean }): Promise<{ creates: number; starts: number }>
  fakeVms(): Promise<string[]>
  ledger(entity: string): Promise<{ rows: Array<{ provider_id: string | null; state: string }> }>
  deleteVm(entity: string, providerId: string, by: string): Promise<{ ok: boolean }>
  registryEvent(ev: { kind: "intent" | "created" | "backfilled" | "deleted"; team: string; name: string; provider_id: string | null }): Promise<void>
  registryCounts(): Promise<Counts>
  prefixReport(): Promise<Report>
}
const namespace = (env as unknown as { TEAM_VM_DO: DurableObjectNamespace }).TEAM_VM_DO
const stubFor = (name: string) => namespace.get(namespace.idFromName(name)) as unknown as Stub
const registry = () => stubFor(TEAM_VM_REGISTRY)
const ALICE = "user_00000000000000000271"
const principal = (team: string): Principal => ({ identity: `user:${ALICE}`, user: ALICE, team, kind: "session" })
let key = 0
const op = (name: string, params: unknown) => ({ t: "op" as const, op: name, params, idempotency_key: `rk${++key}`, origin: "cli" as const })
const vmOf = (frames: ReadonlyArray<OwnerFrame>) => ((frames.find((x) => x.t === "result") as { value: { vm: string } }).value.vm)
const PREFIX = "cmuxnp-dev-tvm-"
const delta = (a: Counts, b: Counts) => ({ teams: b.teams - a.teams, created: b.created - a.created, backfilled: b.backfilled - a.backfilled, deleted: b.deleted - a.deleted, live: b.live - a.live })

describe("team VM registry", { timeout: 30_000 }, () => {
  it("a confirmed create registers the team and counts once, even when its event comes again", async () => {
    const T = "team_00000000000000000271"
    const before = await registry().registryCounts()
    await stubFor(T).fakeControl({ slug_prefix: PREFIX })
    const vm = vmOf((await stubFor(T).ensureAwake(T, principal(T), op("team_vm.ensure_awake", { reason: "ssh" }))).frames)
    expect(delta(before, await registry().registryCounts())).toEqual({ teams: 1, created: 1, backfilled: 0, deleted: 0, live: 1 })
    // A retried event (the sender did not see the answer) counts once.
    await registry().registryEvent({ kind: "created", team: T, name: teamVmSlug(PREFIX, T, 1), provider_id: vm })
    expect(delta(before, await registry().registryCounts())).toEqual({ teams: 1, created: 1, backfilled: 0, deleted: 0, live: 1 })
  })

  it("a delete decrements live once", async () => {
    const T = "team_00000000000000000272"
    const s = stubFor(T)
    const before = await registry().registryCounts()
    await s.fakeControl({ slug_prefix: PREFIX })
    const first = vmOf((await s.ensureAwake(T, principal(T), op("team_vm.ensure_awake", { reason: "ssh" }))).frames)
    await s.fakeControl({ delete_all: true })
    await s.ensureAwake(T, principal(T), op("team_vm.ensure_awake", { reason: "ssh" }))
    expect(await s.deleteVm(T, first, "test")).toEqual({ ok: true })
    expect(delta(before, await registry().registryCounts())).toEqual({ teams: 1, created: 2, backfilled: 0, deleted: 1, live: 1 })
    await registry().registryEvent({ kind: "deleted", team: T, name: teamVmSlug(PREFIX, T, 1), provider_id: first })
    expect(await s.deleteVm(T, first, "test")).toEqual({ ok: true })
    expect(delta(before, await registry().registryCounts())).toEqual({ teams: 1, created: 2, backfilled: 0, deleted: 1, live: 1 })
  })

  it("a backfilled VM counts once and never on top of its create", async () => {
    const T = "team_00000000000000000273"
    const s = stubFor(T)
    await s.fakeControl({ slug_prefix: PREFIX })
    await s.ensureAwake(T, principal(T), op("team_vm.ensure_awake", { reason: "ssh" }))
    const before = await registry().registryCounts()
    await s.fakeControl({ drop_ledger: true })
    await s.ledger(T)
    await s.ledger(T)
    // The id was already counted as created: the backfill does not add a second live VM.
    expect(delta(before, await registry().registryCounts())).toEqual({ teams: 0, created: 0, backfilled: 0, deleted: 0, live: 0 })
    // A VM the registry never saw (a DO from before the registry) counts as backfilled, once.
    await registry().registryEvent({ kind: "backfilled", team: "team_00000000000000000274", name: `${PREFIX}team-00000000000000000274-e1`, provider_id: "fakevm-old-274" })
    await registry().registryEvent({ kind: "backfilled", team: "team_00000000000000000274", name: `${PREFIX}team-00000000000000000274-e1`, provider_id: "fakevm-old-274" })
    expect(delta(before, await registry().registryCounts())).toEqual({ teams: 1, created: 0, backfilled: 1, deleted: 0, live: 1 })
  })

  it("the prefix report names a VM outside every ledger and changes nothing", async () => {
    const T = "team_00000000000000000275"
    await stubFor(T).fakeControl({ slug_prefix: PREFIX })
    const vm = vmOf((await stubFor(T).ensureAwake(T, principal(T), op("team_vm.ensure_awake", { reason: "ssh" }))).frames)
    // The registry object's fake provider stands for the shared provider account.
    const r = registry()
    // The report filters on the deployment's configured team VM prefix (here the fake's).
    await r.fakeControl({ slug_prefix: PREFIX })
    await r.fakeControl({ seed_vm: { slug: teamVmSlug(PREFIX, T, 1), id: vm } })
    await r.fakeControl({ seed_vm: { slug: "cmuxnp-stg-tvm-other-env", id: "fakevm-other-env" } })
    await r.fakeControl({ seed_vm: { slug: `${PREFIX}stranger`, id: "fakevm-stranger" } })
    await r.fakeControl({ seed_vm: { slug: "classic-customer-vm", id: "fakevm-classic" } })
    const vmsBefore = await r.fakeVms()
    const countsBefore = await r.registryCounts()
    const report = await r.prefixReport()
    expect(report).toMatchObject({ prefix: PREFIX, listed: 4, matched: 2, in_registry: 1, not_in_registry: [`${PREFIX}stranger`], truncated: false })
    expect(JSON.stringify(report)).not.toContain("classic")
    expect(await r.fakeVms()).toEqual(vmsBefore)
    expect(await r.registryCounts()).toEqual(countsBefore)
    expect((await stubFor(T).ledger(T)).rows).toHaveLength(1)
  })

  it("ledger rows from before the registry reach it once (one-time seed)", async () => {
    const T = "team_00000000000000000276"
    const s = stubFor(T)
    await s.fakeControl({ slug_prefix: PREFIX })
    const vm = vmOf((await s.ensureAwake(T, principal(T), op("team_vm.ensure_awake", { reason: "ssh" }))).frames)
    // Stand for a ledger that existed before the registry: the registry never saw this VM.
    await registry().fakeControl({ drop_registry: true })
    await s.fakeControl({ reset_registry_seed: true })
    expect((await registry().registryCounts()).live).toBe(0)
    await s.ledger(T)
    await s.ledger(T)
    expect(await registry().registryCounts()).toMatchObject({ teams: 1, created: 1, live: 1 })
    expect(vm).toContain("fakevm-")
  })

  it("the operator route needs its key and only reads", async () => {
    const without = await handleTeamVmAdmin(new Request("https://api.test/v1/admin/team-vm/registry"), env as unknown as Env)
    expect(without.status).toBe(404)
    const KEY = "t".repeat(40)
    const withKey = { ...(env as unknown as Env), TEAM_VM_ADMIN_KEY: KEY } as Env
    expect((await handleTeamVmAdmin(new Request("https://api.test/v1/admin/team-vm/registry", { headers: { authorization: "Bearer wrong" } }), withKey)).status).toBe(401)
    const ok = await handleTeamVmAdmin(new Request("https://api.test/v1/admin/team-vm/registry", { headers: { authorization: `Bearer ${KEY}` } }), withKey)
    expect(ok.status).toBe(200)
    expect(await ok.json()).toMatchObject({ counts: { teams: expect.any(Number), live: expect.any(Number) } })
    const report = await handleTeamVmAdmin(new Request("https://api.test/v1/admin/team-vm/prefix-report", { method: "POST", headers: { authorization: `Bearer ${KEY}` } }), withKey)
    expect(report.status).toBe(200)
    expect(await report.json()).toMatchObject({ report: { prefix: PREFIX } })
  })
})
