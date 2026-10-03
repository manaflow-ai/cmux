import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { idFactory, MemoryRows, type Principal, type ReduceContext } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { MAX_ACTIVE_RUNS_PER_TEAM, RUN_BURST, takeRunToken } from "../src/domains/scheduler-limits.ts"
import { dispatchable, schedulerDomain, type RunRecord, type SchedulerState } from "../src/domains/scheduler.ts"
import { ceilingUsd, summarize, usageDomain } from "../src/domains/usage.ts"

/** Slice 2 (plans/cmux-next/automations-plan.md): the usage ledger, the hard cap and the scheduler's abuse limits. */

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USAGE_METER_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any) => Promise<void>) => Promise<void>

const token = async (stackUser: string) => {
  const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email: `${stackUser}@example.com`, name: stackUser })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key)
}
const call = async (path: string, t: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) })
  return (await res.json()) as any
}
const op = (t: string, name: string, params: unknown) => call("/v1/ops", t, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
const read = (t: string, name: string, params: unknown = {}) => call("/v1/read", t, { op: name, params })
const signedIn = async (u: string) => {
  const t = await token(u)
  const e = await op(t, "user.ensure", {})
  return { t, team: e.value.personal_team as string }
}
const meter = (team: string) => testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team))
const now = () => Date.now()

describe("UsageMeterDO ledger (workerd)", () => {
  it("records idempotently by key, keeps monthly counters and prices them", async () => {
    const { t, team } = await signedIn("usage-user-1")
    await inDO(meter(team), async (m) => {
      const steps = { key: "step:run_a:s1", meter: "automation.steps", quantity: 1, source: "step", observed_at: now(), run: "run_a" }
      const cpu = { key: "tail:run_a:s1:1:0", meter: "automation.cpu_ms", quantity: 1_000_000, source: "tail", observed_at: now() }
      const first = await m.record(team, [steps, cpu, { key: "bad", meter: "nope", quantity: 1, source: "tail", observed_at: 0 }])
      expect(first).toMatchObject({ recorded: 2, duplicates: 0, invalid: 1, allowed: true })
      const again = await m.record(team, [steps, cpu])
      expect(again).toMatchObject({ recorded: 0, duplicates: 2, allowed: true })
      const line = (s: any, name: string) => s.meters.find((x: any) => x.meter === name)
      expect(line(again.summary, "automation.steps")).toMatchObject({ quantity: 1, usd: 0.000008 })
      expect(line(again.summary, "automation.cpu_ms")).toMatchObject({ quantity: 1_000_000, usd: 0.02 })
      expect(again.summary).toMatchObject({ owner: team, cap_usd: 25, ceiling_usd: 25, team_cap_usd: null, stopped: null })
    })
    const summary = await read(t, "usage.summary")
    expect(summary.value.owner).toBe(team)
    expect(summary.value.total_usd).toBeCloseTo(0.020008, 6)
  })

  it("stops work at the hard cap and honors a lower team cap", async () => {
    const { t, team } = await signedIn("usage-user-2")
    const set = await op(t, "usage.cap.set", { cap_usd: 5 })
    expect(set).toMatchObject({ ok: true, value: { team_cap_usd: 5 } })
    await inDO(meter(team), async (m) => {
      const under = await m.record(team, [{ key: "model:1", meter: "model.spend_usd", quantity: 4.99, source: "coderouter", observed_at: now() }])
      expect(under.allowed).toBe(true)
      const over = await m.record(team, [{ key: "model:2", meter: "model.spend_usd", quantity: 0.02, source: "coderouter", observed_at: now() }])
      expect(over).toMatchObject({ allowed: false, summary: { stopped: "cap.reached", cap_usd: 5 } })
      expect((await m.check(team)).allowed).toBe(false)
    })
    // A team cap above the ceiling never raises the cap in force.
    await op(t, "usage.cap.set", { cap_usd: 1000 })
    const s = await read(t, "usage.summary")
    expect(s.value).toMatchObject({ cap_usd: 25, team_cap_usd: 1000, stopped: null })
  })

  it("counts a late record against the current month, and refuses oversize batches whole", async () => {
    const { team } = await signedIn("usage-user-3")
    await inDO(meter(team), async (m) => {
      const lastYear = Date.UTC(2025, 0, 15)
      const r = await m.record(team, [{ key: "old", meter: "model.spend_usd", quantity: 30, source: "coderouter", observed_at: lastYear }])
      expect(r).toMatchObject({ recorded: 1, allowed: false, summary: { total_usd: 30, stopped: "cap.reached" } })
      const many = Array.from({ length: 501 }, (_, i) => ({ key: `k${i}`, meter: "automation.steps", quantity: 1, source: "step", observed_at: now() }))
      const big = await m.record(team, many)
      expect(big).toMatchObject({ recorded: 0, too_large: true })
    })
  })
})

describe("cap math and authorization (pure)", () => {
  it("treats a missing or invalid ceiling as zero, which stops everything", () => {
    expect(ceilingUsd(undefined)).toBe(0)
    expect(ceilingUsd("abc")).toBe(0)
    expect(ceilingUsd("-1")).toBe(0)
    expect(ceilingUsd("25")).toBe(25)
    expect(summarize({ owner: "team_x", team_cap_usd: null }, "2026-10", new Map(), 0).stopped).toBe("cap.not_configured")
  })
  it("refuses another team's principal", () => {
    const stranger: Principal = { identity: "session:s", kind: "session", user: "user_bbbbbbbbbbbbbbbbbbbb", team: "team_bbbbbbbbbbbbbbbbbbbb" }
    expect(usageDomain.authorize!({ owner: "team_aaaaaaaaaaaaaaaaaaaa", team_cap_usd: null }, "usage.cap.set", { cap_usd: 1 }, stranger)).toMatchObject({ code: "auth.forbidden" })
  })
})

describe("SchedulerDO abuse limits (pure)", () => {
  const user: Principal = { identity: "session:user_aaaaaaaaaaaaaaaaaaaa", kind: "session", user: "user_aaaaaaaaaaaaaaaaaaaa", team: "team_aaaaaaaaaaaaaaaaaaaa" }
  let txn = 0
  const ctx = (at: number): ReduceContext => {
    const tx = `tx${txn++}`
    return { principal: user, now: at, tx, newId: idFactory(tx), rows: new MemoryRows() }
  }
  const T0 = Date.UTC(2026, 9, 3, 10, 0, 0)

  it("refills the creation bucket at 5 per second up to the burst", () => {
    let b = takeRunToken(undefined, T0)
    for (let i = 1; i < RUN_BURST; i++) b = takeRunToken(b, T0)
    expect(b!.tokens).toBe(0)
    expect(takeRunToken(b, T0)).toBeUndefined()
    expect(takeRunToken(b, T0 + 200)).toBeDefined()
    expect(takeRunToken(b, T0 + 3_600_000)!.tokens).toBe(RUN_BURST - 1)
  })

  it("refuses run creation past the burst with a retryable rate.limited, and accepts after a refill", () => {
    let s: SchedulerState = schedulerDomain.initial()
    const created = schedulerDomain.reduce(s, "automation.create", { name: "x", triggers: [{ type: "manual" }], body: { type: "steps", steps: [{ type: "note", text: "n" }] }, concurrency: { max: 10, on_limit: "queue" } }, ctx(T0))
    if (!created.ok) throw new Error(created.code)
    s = created.state
    const id = Object.keys(s.automations)[0]!
    for (let i = 0; i < RUN_BURST; i++) {
      const r = schedulerDomain.reduce(s, "automation.run", { automation: id }, ctx(T0))
      if (!r.ok) throw new Error(`run ${i}: ${r.code}`)
      s = r.state
    }
    const limited = schedulerDomain.reduce(s, "automation.run", { automation: id }, ctx(T0))
    expect(limited).toMatchObject({ ok: false, code: "rate.limited", retryable: true })
    expect(schedulerDomain.reduce(s, "automation.run", { automation: id }, ctx(T0 + 1000)).ok).toBe(true)
  })

  it("dispatches at most 50 active runs per team, across automations", () => {
    const run = (i: number, automation: string, state: RunRecord["state"], dispatched: boolean): RunRecord => ({
      id: `run_${String(i).padStart(20, "0")}`,
      automation,
      automation_version: 1,
      owner: "team_aaaaaaaaaaaaaaaaaaaa",
      trigger: { id: null, type: "manual" },
      state,
      step: -1,
      created_at: T0 + i,
      started_at: null,
      finished_at: null,
      error: null,
      outcome: null,
      dispatched,
      body: { type: "steps", steps: [{ type: "note", text: "n" }] }
    })
    const runs: Record<string, RunRecord> = {}
    const automations: Record<string, any> = {}
    for (let a = 0; a < 6; a++) automations[`auto_${a}`] = { concurrency: { max: 10, on_limit: "queue" } }
    // 48 running over 5 automations, then 10 queued on a sixth.
    for (let i = 0; i < 48; i++) runs[`r${i}`] = run(i, `auto_${i % 5}`, "running", true)
    for (let i = 48; i < 58; i++) runs[`r${i}`] = run(i, "auto_5", "queued", false)
    const state = { owner: "team_aaaaaaaaaaaaaaaaaaaa", automations, runs, chains: {} } as unknown as SchedulerState
    expect(dispatchable(state)).toHaveLength(MAX_ACTIVE_RUNS_PER_TEAM - 48)
  })
})
