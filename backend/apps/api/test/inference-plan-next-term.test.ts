import { describe, expect, it } from "vitest"
import { cloudVmPlanOf, grantRank, higherGrant, storeCarriedVmPlan } from "../src/cloud-vm-plan.ts"
import type { TeamState } from "../src/domains/team.ts"
import { grantTestPlan, inferencePlanOf, storePlan } from "../src/inference/plan.ts"
import { nextPlanId, planTime, stackServer, type StackServer } from "../src/stack-server.ts"
import { PROJECT, teamStub } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"

/**
 * The cmux NEXT entry plans (RFD 0052): `cmuxNextPlan` may be next_intro (the 30-day pass) or next_taste (the free
 * week), with its term in cmuxNextPlanStartedAt and cmuxNextPlanEndsAt. TeamDO.inferencePlan passes the plan and the
 * term (`next_plan_started_at`, `next_plan_ends_at`: parseable ISO times, else null) to the Cloud service, which
 * enforces the term. An entry plan is never `paid`, never changes the limit, and ranks below every paid plan.
 */

const fakeHttp = (meta: Record<string, unknown> | undefined) => async (r: Request) => {
  void r
  return Response.json({ display_name: "Acme", ...(meta === undefined ? {} : { client_read_only_metadata: meta }) })
}
const env = { STACK_SECRET_SERVER_KEY: "sk", STACK_PROJECT_ID: PROJECT } as never

const personal = (stack: StackServer, before?: (sql: SqlStorage) => void) =>
  inDO(teamStub(`personal-${crypto.randomUUID()}`), async (_i, state) => {
    before?.(state.storage.sql)
    return inferencePlanOf(state.storage.sql, null, "entity", stack, "stack-user", "user")
  })

const START = "2026-11-20T10:00:00.000Z"
const END = "2026-12-20T10:00:00.000Z"

describe("inferencePlan NEXT entry plans and their term", () => {
  it("passes next_intro and next_taste through with their term, never paid", async () => {
    const intro = await personal(stackServer(env, fakeHttp({ cmuxNextPlan: "next_intro", cmuxNextPlanStartedAt: START, cmuxNextPlanEndsAt: END }))!)
    expect(intro).toEqual({ ok: true, paid: false, user_limit_usd: expect.any(Number), plan: null, next_plan: "next_intro", chief_addon: null, next_plan_started_at: START, next_plan_ends_at: END })
    const taste = await personal(stackServer(env, fakeHttp({ cmuxNextPlan: "next_taste", cmuxNextPlanStartedAt: "2026-11-20T10:00:00+02:00", cmuxNextPlanEndsAt: "2026-11-27T08:00Z" }))!)
    expect(taste).toMatchObject({ paid: false, next_plan: "next_taste", next_plan_started_at: "2026-11-20T10:00:00+02:00", next_plan_ends_at: "2026-11-27T08:00Z" })
    expect(nextPlanId("next_intro")).toBe("next_intro")
    expect(nextPlanId("NEXT_INTRO")).toBeNull()
  })

  it("keeps paid, the limit and plan unchanged by an entry plan", async () => {
    const without = await personal(stackServer(env, fakeHttp({ cmuxPlan: "pro" }))!)
    const withPass = await personal(stackServer(env, fakeHttp({ cmuxPlan: "pro", cmuxNextPlan: "next_intro", cmuxNextPlanStartedAt: START, cmuxNextPlanEndsAt: END }))!)
    expect(withPass).toEqual({ ...(without as object), next_plan: "next_intro", next_plan_started_at: START, next_plan_ends_at: END })
    const unpaid = await personal(stackServer(env, fakeHttp({}))!)
    const unpaidPass = await personal(stackServer(env, fakeHttp({ cmuxNextPlan: "next_taste", cmuxNextPlanStartedAt: START }))!)
    expect(unpaidPass).toEqual({ ...(unpaid as object), next_plan: "next_taste", next_plan_started_at: START })
  })

  it("answers a bad or missing time as null, and still passes the plan", async () => {
    for (const bad of ["", "tomorrow", "2026-11-20", "2026-11-20T10:00:00", "2026-13-01T00:00:00Z", "Fri, 20 Nov 2026 10:00:00 GMT", 1795392000000, null, true, { at: START }]) {
      expect(planTime(bad)).toBeNull()
      const answer = await personal(stackServer(env, fakeHttp({ cmuxNextPlan: "next_intro", cmuxNextPlanStartedAt: bad, cmuxNextPlanEndsAt: bad }))!)
      expect(answer).toMatchObject({ paid: false, next_plan: "next_intro", next_plan_started_at: null, next_plan_ends_at: null })
    }
    const noStart = await personal(stackServer(env, fakeHttp({ cmuxNextPlan: "next_intro", cmuxNextPlanEndsAt: END }))!)
    expect(noStart).toMatchObject({ next_plan: "next_intro", next_plan_started_at: null, next_plan_ends_at: END })
  })

  it("reads the term from the Stack team record for a shared team, and a team sync stores it", async () => {
    const answer = await inDO(teamStub(`shared-${crypto.randomUUID()}`), async (_i, state) => {
      const team = { team: { id: "t1", kind: "stack", display_name: "Acme", stack_team: "st1" } } as unknown as TeamState
      return inferencePlanOf(state.storage.sql, team, "t1", stackServer(env, fakeHttp({ cmuxPlan: "team", cmuxNextPlan: "next_intro", cmuxNextPlanStartedAt: START, cmuxNextPlanEndsAt: END }))!, undefined, "user")
    })
    expect(answer).toMatchObject({ ok: true, paid: true, plan: "team", next_plan: "next_intro", next_plan_started_at: START, next_plan_ends_at: END })
  })

  it("carries the term in the stored copy; a store without it clears it, a store with a bad one stores null", async () => {
    let reads = 0
    const stack = { getUserPlans: async () => (reads++, { plan: null, next_plan: "next_intro", next_plan_started_at: START, next_plan_ends_at: END }) } as unknown as StackServer
    const [first, cached, cleared, bad] = await inDO(teamStub(`personal-${crypto.randomUUID()}`), async (_i, state) => {
      const sql = state.storage.sql
      const now = Date.now()
      const a = await inferencePlanOf(sql, null, "entity", stack, "stack-user", "user", now)
      const b = await inferencePlanOf(sql, null, "entity", stack, "stack-user", "user", now + 1)
      storePlan(sql, "pro", now + 2, "next_taste")
      const c = await inferencePlanOf(sql, null, "entity", stack, "stack-user", "user", now + 3)
      storePlan(sql, "pro", now + 4, "next_taste", null, "soon", END)
      const d = await inferencePlanOf(sql, null, "entity", stack, "stack-user", "user", now + 5)
      return [a, b, c, d]
    })
    expect(first).toMatchObject({ paid: false, next_plan: "next_intro", next_plan_started_at: START, next_plan_ends_at: END })
    expect(cached).toEqual(first)
    expect(reads).toBe(1)
    expect(cleared).toMatchObject({ paid: true, plan: "pro", next_plan: "next_taste", next_plan_started_at: null, next_plan_ends_at: null })
    expect(bad).toMatchObject({ next_plan: "next_taste", next_plan_started_at: null, next_plan_ends_at: END })
  })

  it("answers a fresh copy stored before the term existed with null times, without a read", async () => {
    let reads = 0
    const stack = { getUserPlans: async () => (reads++, { plan: "max", next_plan: "next_intro", next_plan_started_at: START, next_plan_ends_at: END }) } as unknown as StackServer
    const answer = await personal(stack, (sql) => {
      // The table and row as the Worker before this change wrote them: next_plan and chief_addon, no term columns.
      sql.exec(`CREATE TABLE inference_plan (id INTEGER PRIMARY KEY CHECK (id = 1), plan TEXT, checked_at INTEGER NOT NULL, failed_at INTEGER, next_plan TEXT, chief_addon TEXT)`)
      sql.exec(`INSERT INTO inference_plan (id, plan, checked_at, failed_at, next_plan, chief_addon) VALUES (1, 'pro', ?, NULL, 'next_pro', NULL)`, Date.now())
    })
    expect(answer).toEqual({ ok: true, paid: true, user_limit_usd: expect.any(Number), plan: "pro", next_plan: "next_pro", chief_addon: null, next_plan_started_at: null, next_plan_ends_at: null })
    expect(reads).toBe(0)
  })

  it("answers a server without the term on getUserPlans with null times", async () => {
    const older = { getUserPlans: async () => ({ plan: null, next_plan: "next_intro" }) } as unknown as StackServer
    expect(await personal(older)).toMatchObject({ next_plan: "next_intro", next_plan_started_at: null, next_plan_ends_at: null })
  })

  it("keeps the plan and its term when a Chief's test plan grant makes the answer paid", async () => {
    const stack = { getUserPlans: async () => ({ plan: null, next_plan: "next_intro", next_plan_started_at: START, next_plan_ends_at: END }) } as unknown as StackServer
    const answer = await inDO(teamStub(`personal-${crypto.randomUUID()}`), async (_i, state) => {
      const sql = state.storage.sql
      grantTestPlan(sql, "pro", "cs_test_1", "sub_1", Date.now())
      return inferencePlanOf(sql, null, "entity", stack, "stack-user", "user", Date.now(), true)
    })
    expect(answer).toEqual({ ok: true, paid: true, user_limit_usd: expect.any(Number), plan: "pro", next_plan: "next_intro", chief_addon: null, next_plan_started_at: START, next_plan_ends_at: END })
  })
})

describe("NEXT entry plans rank below every paid plan", () => {
  it("ranks next_intro and next_taste 0, below every paid and NEXT plan", () => {
    for (const entry of ["next_intro", "next_taste"]) {
      expect(grantRank(entry)).toBe(0)
      for (const paid of ["go", "pro", "founders", "team", "max", "next_plus", "next_pro", "next_max"]) expect(grantRank(paid)).toBeGreaterThan(grantRank(entry))
      // As the person's paid plan, an entry plan never blocks a carried grant.
      expect(higherGrant(null, entry, "pro")).toBe("pro")
    }
  })

  it("never reads an entry plan as an operator grant (cmuxNextVmPlan)", async () => {
    for (const entry of ["next_intro", "next_taste"]) {
      const r = await stackServer(env, fakeHttp({ cmuxNextVmPlan: entry }))!.getUserVmPlan("stack-user")
      expect(r).toEqual({ vm_plan: null })
      const both = await stackServer(env, fakeHttp({ cmuxVmPlan: "pro", cmuxNextVmPlan: entry }))!.getUserVmPlan("stack-user")
      expect(both).toEqual({ vm_plan: "pro" })
    }
  })

  it("compares a carried grant with the real plan, not the pass, when a person holds both", async () => {
    const grantOf = (plans: { plan: string | null; next_plan: string | null }, carried: string) =>
      inDO(teamStub(`personal-${crypto.randomUUID()}`), async (_i, state) => {
        const sql = state.storage.sql
        storeCarriedVmPlan(sql, "deleted-team", carried, Date.now())
        const stack = { getUserVmPlan: async () => ({ vm_plan: null }), getUserPlans: async () => plans } as unknown as StackServer
        return cloudVmPlanOf(sql, null, "entity", stack, "stack-user", Date.now())
      })
    // The real plan (max) already covers the carried pro: no grant.
    expect(await grantOf({ plan: "max", next_plan: "next_intro" }, "pro")).toEqual({ ok: true, vm_plan: null })
    // A pass alone is no paid plan: the carried grant applies.
    expect(await grantOf({ plan: null, next_plan: "next_taste" }, "pro")).toEqual({ ok: true, vm_plan: "pro" })
    // A real plan with a pass and a carried grant above it: the carried grant.
    expect(await grantOf({ plan: "go", next_plan: "next_intro" }, "max")).toEqual({ ok: true, vm_plan: "max" })
  })
})
