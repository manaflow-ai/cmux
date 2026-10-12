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

  it("refuses another team, an unknown op from a system principal, and an install whose grant lacks the risk", () => {
    const s = must(apply(teamVmDomain.initial(), "team_vm.ensure_awake", { reason: "ssh" }, alice)).state
    expect(apply(s, "team_vm.ensure_awake", { reason: "ssh" }, { ...alice, team: OTHER })).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(apply(s, "team_vm.ensure_awake", { reason: "ssh" }, system)).toMatchObject({ ok: false })
    expect(apply(s, "team_vm.ensure_awake", { reason: "ssh" }, install)).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(apply(s, "team_vm.driver_result", { action: "create", epoch: 0, ok: true, vm: "vm1", slug: "x" }, alice)).toMatchObject({ ok: false })
  })

})

const result = (frames: ReadonlyArray<OwnerFrame>) => {
  const f = frames.find((x) => x.t === "result" || x.t === "reject")
  if (!f) throw new Error("no result")
  return f as { t: string; value?: Record<string, unknown>; code?: string }
}
let key = 0
const op = (name: string, params: unknown) => ({ t: "op" as const, op: name, params, idempotency_key: `k${++key}`, origin: "cli" as const })

const enc = new TextEncoder()
const b64 = (t: string) => btoa(t)
const hex = async (t: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(t))), (b) => b.toString(16).padStart(2, "0")).join("")
const append = async (stub: TeamVmStub, team: string, p: Principal, a: { stream: string; epoch: number; first: number; last: number; text: string; sha?: string }) =>
  result(
    (
      await stub.journalAppend(team, p, op("team_vm.journal.append", { stream: a.stream, epoch: a.epoch, first_seq: a.first, last_seq: a.last, bytes: b64(a.text), sha256: a.sha ?? (await hex(a.text)) }))
    ).frames
  )

