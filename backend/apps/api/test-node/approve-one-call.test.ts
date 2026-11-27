import { describe, expect, it } from "vitest"
import type { Principal } from "@cmux/ownership"
import { APPROVE_ONE_CALL_BUDGET_MS, approveInOneCall, sameJson, type ApproveDeps, type ItemLookup } from "../src/integrations/approve-one-call.ts"

/**
 * integration.approval.approve (G8 in one call): the Worker makes the Mac's three checks (integration.approval.get,
 * feed.list, feed.answer) and returns the approved run's reply, so a Cloud create's approval is two round trips, not
 * five. Every refusal is the Mac's own (CloudApprovalAnswer.Failure.mismatch reasons) and answers nothing.
 */
const USER = "user_00000000000000000001"
const TEAM = "team_00000000000000000001"
const REQUEST = `apr_${"a".repeat(32)}`
const OP = "cloud.machine.create"
const PARAMS = { name: "box", size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }
const session: Principal = { identity: `session:${USER}`, kind: "session", user: USER, team: TEAM }
const MACHINE = { machine: { id: "vm_aaaaaaaaaaaaaaaaaaaa" } }

const fixture = (over: Partial<{ held: Record<string, unknown>; owner: string; item: ItemLookup; answer: Awaited<ReturnType<ApproveDeps["answer"]>>; run: ApproveDeps["run"]; clock: Array<number> }> = {}) => {
  const calls: Array<string> = []
  const waits: Array<number> = []
  const clock = over.clock ?? [0]
  let tick = 0
  const deps: ApproveDeps = {
    route: async (p) => (calls.push("route"), { reader: p, owner: over.owner ?? "cloud:CloudDO" }),
    read: async () => (calls.push("read"), { ok: true, value: over.held ?? { op: OP, state: "pending", params: PARAMS, digest: "sha256:d" } }),
    item: async (_u, a) => (calls.push(`item:${a.digest}:${a.team}:${a.op}`), over.item === undefined ? { open: "fi_1" } : over.item),
    answer: async (_p, item, key) => (calls.push(`answer:${item}:${key}`), over.answer ?? { ok: true }),
    run:
      over.run ??
      (async (_r, _q, waitMs) => (calls.push("run"), waits.push(waitMs), { ok: true, value: { request: REQUEST, state: "done", reply: { ok: true, value: MACHINE } } })),
    now: () => clock[Math.min(tick++, clock.length - 1)]!
  }
  const approve = (params: Partial<{ op: string; params: unknown; team: string }> = {}, p: Principal = session) =>
    approveInOneCall(deps, p, { request: REQUEST, op: OP, params: PARAMS, team: TEAM, ...params }, `approve:${REQUEST}`)
  return { calls, waits, approve }
}

const refusedWith = (reason: string) => ({ ok: false, code: "approval.mismatch", retryable: false, details: { reason } })

describe("integration.approval.approve: one call answers the approval and carries the run's reply", () => {
  it("answers the open item allow once with the caller's key and returns the create's machine", async () => {
    const f = fixture()
    expect(await f.approve()).toEqual({ ok: true, value: { request: REQUEST, answered: "here", state: "done", reply: { ok: true, value: MACHINE } } })
    expect(f.calls).toEqual(["route", "read", `item:sha256:d:${TEAM}:${OP}`, `answer:fi_1:approve:${REQUEST}`, "run"])
  })

  it("params match as JSON, whatever the key order", async () => {
    const f = fixture({ held: { op: OP, state: "pending", params: { size: { disk_mb: 16384, memory_mb: 4096, cpu: 2 }, name: "box" }, digest: "sha256:d" } })
    expect(await f.approve()).toMatchObject({ ok: true, value: { answered: "here" } })
  })

  for (const [name, held, reason] of [
    ["another op", { op: "cloud.machine.delete", state: "pending", params: PARAMS, digest: "sha256:d" }, "op"],
    ["a request no longer pending", { op: OP, state: "done", params: PARAMS, digest: "sha256:d" }, "state"],
    ["other params", { op: OP, state: "pending", params: { ...PARAMS, name: "other" }, digest: "sha256:d" }, "params"],
    ["no digest", { op: OP, state: "pending", params: PARAMS }, "digest"]
  ] as const)
    it(`refuses ${name} (${reason}) and answers nothing`, async () => {
      const f = fixture({ held: held as Record<string, unknown> })
      expect(await f.approve()).toMatchObject(refusedWith(reason))
      expect(f.calls.some((c) => c.startsWith("answer") || c === "run")).toBe(false)
    })

  it("refuses when no item of the create's team carries it (another team's item, or none)", async () => {
    const f = fixture({ item: null })
    expect(await f.approve({ team: "team_00000000000000000002" })).toMatchObject(refusedWith("feed item or team"))
    expect(f.calls).toContain(`item:sha256:d:team_00000000000000000002:${OP}`)
    expect(f.calls.some((c) => c.startsWith("answer"))).toBe(false)
  })

  it("answered elsewhere (only the team's closed item): answers nothing, still returns the run's reply", async () => {
    const f = fixture({ item: { closed: true } })
    expect(await f.approve()).toMatchObject({ ok: true, value: { answered: "elsewhere", reply: { ok: true, value: MACHINE } } })
    expect(f.calls.some((c) => c.startsWith("answer"))).toBe(false)
  })

  it("a refused feed answer is the refusal, with no run read", async () => {
    const f = fixture({ answer: { ok: false, code: "feed.closed", message: "closed", retryable: false } })
    expect(await f.approve()).toEqual({ ok: false, code: "feed.closed", message: "closed", retryable: false })
    expect(f.calls).not.toContain("run")
  })

  it("only a session, and only a Cloud request", async () => {
    const install: Principal = { identity: "inst_mac", kind: "install", user: USER, team: TEAM, install: "inst_mac" }
    expect(await fixture().approve({}, install)).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await fixture({ owner: "cloud:ConnectionDO" }).approve()).toMatchObject({ ok: false, code: "selector.not_found" })
  })

  it("the run's wait is what is left of one budget from the start of the call", async () => {
    const f = fixture({ clock: [1_000, 3_500] })
    await f.approve()
    expect(f.waits).toEqual([APPROVE_ONE_CALL_BUDGET_MS - 2_500])
    expect(APPROVE_ONE_CALL_BUDGET_MS).toBeLessThanOrEqual(10_000)
    const late = fixture({ clock: [0, 60_000] })
    await late.approve()
    expect(late.waits).toEqual([0])
  })

  it("a run still going, or a platform without the RPC, answers without a reply: the caller retries the create", async () => {
    const running = fixture({ run: async () => ({ ok: true, value: { request: REQUEST, state: "running" } }) })
    expect(await running.approve()).toEqual({ ok: true, value: { request: REQUEST, answered: "here", state: "running" } })
    const old = fixture({ run: async () => Promise.reject(new Error("approvalRun is not a function")) })
    expect(await old.approve()).toEqual({ ok: true, value: { request: REQUEST, answered: "here" } })
  })

  it("sameJson: deep, order-free, type-strict", () => {
    expect(sameJson({ a: [1, { b: 2 }] }, { a: [1, { b: 2 }] })).toBe(true)
    expect(sameJson({ a: 1 }, { a: "1" })).toBe(false)
    expect(sameJson({ a: 1 }, { a: 1, b: undefined })).toBe(false)
    expect(sameJson([1, 2], [2, 1])).toBe(false)
  })
})
