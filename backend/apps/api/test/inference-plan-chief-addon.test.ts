import { describe, expect, it } from "vitest"
import type { TeamState } from "../src/domains/team.ts"
import { grantTestPlan, inferencePlanOf, storePlan } from "../src/inference/plan.ts"
import { stackServer, type StackServer } from "../src/stack-server.ts"
import { PROJECT, teamStub } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"

/**
 * TeamDO.inferencePlan also answers `chief_addon` for the Cloud service (cmux-platform cloud.plan.get `chief_size`):
 * the record's client_read_only_metadata.cmuxChiefAddon when it names M, L or XL (any case, an optional chief_
 * prefix, answered as M, L or XL), else null. It is read from the same record and read as `plan` (cmuxPlan), and
 * never changes `paid`, the limit, `plan` or `next_plan`.
 */

type Sent = { method: string; path: string }
/** The sign-in service's HTTP answer for one user record or one team record with this read-only metadata. */
const fakeHttp = (meta: Record<string, unknown> | undefined) => {
  const sent: Array<Sent> = []
  const http = async (r: Request) => {
    sent.push({ method: r.method, path: new URL(r.url).pathname.replace(/^\/api\/v1/, "") })
    return Response.json({ display_name: "Acme", ...(meta === undefined ? {} : { client_read_only_metadata: meta }) })
  }
  return { sent, http }
}
const env = { STACK_SECRET_SERVER_KEY: "sk", STACK_PROJECT_ID: PROJECT } as never

/** inferencePlanOf for a caller's own personal team (no mirrored state) in a fresh TeamDO. */
const personal = (stack: StackServer, before?: (sql: SqlStorage) => void) =>
  inDO(teamStub(`personal-${crypto.randomUUID()}`), async (_i, state) => {
    before?.(state.storage.sql)
    return inferencePlanOf(state.storage.sql, null, "entity", stack, "stack-user", "user")
  })

describe("inferencePlan chief_addon (cmuxChiefAddon)", () => {
  it("answers XL from the owner's user record, in the same single read as plan and next_plan", async () => {
    const f = fakeHttp({ cmuxPlan: "pro", cmuxNextPlan: "next_plus", cmuxChiefAddon: "XL" })
    expect(await personal(stackServer(env, f.http)!)).toEqual({ ok: true, paid: true, user_limit_usd: expect.any(Number), plan: "pro", next_plan: "next_plus", chief_addon: "XL", next_plan_started_at: null, next_plan_ends_at: null })
    expect(f.sent).toEqual([{ method: "GET", path: "/users/stack-user" }])
  })

  it("answers M, L and XL as the Cloud service reads them, and null for an unknown, wrong-typed or absent value", async () => {
    for (const [raw, want] of [["M", "M"], ["L", "L"], ["XL", "XL"], ["xl", "XL"], [" l ", "L"], ["chief_m", "M"], ["CHIEF-XL", "XL"]] as const)
      expect(((await personal(stackServer(env, fakeHttp({ cmuxChiefAddon: raw }).http)!)) as any).chief_addon).toBe(want)
    for (const meta of [{ cmuxChiefAddon: "XXL" }, { cmuxChiefAddon: "S" }, { cmuxChiefAddon: "included" }, { cmuxChiefAddon: "" }, { cmuxChiefAddon: "chief_" }, { cmuxChiefAddon: 2 }, { cmuxChiefAddon: null }, { cmuxPlan: "pro" }, undefined])
      expect(((await personal(stackServer(env, fakeHttp(meta).http)!)) as any).chief_addon).toBeNull()
  })

  it("keeps paid, the limit, plan and next_plan unchanged when only cmuxChiefAddon is set", async () => {
    const withAddon = await personal(stackServer(env, fakeHttp({ cmuxChiefAddon: "L" }).http)!)
    const without = await personal(stackServer(env, fakeHttp({}).http)!)
    expect(withAddon).toEqual({ ok: true, paid: false, user_limit_usd: (without as any).user_limit_usd, plan: null, next_plan: null, chief_addon: "L", next_plan_started_at: null, next_plan_ends_at: null })
    expect(without).toEqual({ ok: true, paid: false, user_limit_usd: (withAddon as any).user_limit_usd, plan: null, next_plan: null, chief_addon: null, next_plan_started_at: null, next_plan_ends_at: null })
  })

  it("reads chief_addon from the Stack team record for a shared team", async () => {
    const f = fakeHttp({ cmuxPlan: "team", cmuxNextPlan: "next_pro", cmuxChiefAddon: "M" })
    const answer = await inDO(teamStub(`shared-${crypto.randomUUID()}`), async (_i, state) => {
      const team = { team: { id: "t1", kind: "stack", display_name: "Acme", stack_team: "st1" } } as unknown as TeamState
      return inferencePlanOf(state.storage.sql, team, "t1", stackServer(env, f.http)!, undefined, "user")
    })
    expect(answer).toMatchObject({ ok: true, paid: true, plan: "team", next_plan: "next_pro", chief_addon: "M" })
    expect(f.sent.filter((s) => s.path === "/teams/st1")).toHaveLength(1)
  })

  it("answers a server without chief_addon on getUserPlans, or without getUserPlans, with chief_addon null", async () => {
    const older = { getUserPlans: async () => ({ plan: "pro", next_plan: "next_pro" }) } as unknown as StackServer
    expect(await personal(older)).toEqual({ ok: true, paid: true, user_limit_usd: expect.any(Number), plan: "pro", next_plan: "next_pro", chief_addon: null, next_plan_started_at: null, next_plan_ends_at: null })
    const oldest = { getUserPlan: async () => "pro" } as unknown as StackServer
    expect(await personal(oldest)).toEqual({ ok: true, paid: true, user_limit_usd: expect.any(Number), plan: "pro", next_plan: null, chief_addon: null, next_plan_started_at: null, next_plan_ends_at: null })
  })

  it("answers a fresh copy stored before chief_addon existed with chief_addon null, without a read", async () => {
    let reads = 0
    const stack = { getUserPlan: async () => (reads++, "max"), getUserPlans: async () => (reads++, { plan: "max", next_plan: "next_max", chief_addon: "XL" }) } as unknown as StackServer
    const answer = await personal(stack, (sql) => {
      // The table and row as the Worker before this change wrote them: next_plan, no chief_addon column.
      sql.exec(`CREATE TABLE inference_plan (id INTEGER PRIMARY KEY CHECK (id = 1), plan TEXT, checked_at INTEGER NOT NULL, failed_at INTEGER, next_plan TEXT)`)
      sql.exec(`INSERT INTO inference_plan (id, plan, checked_at, failed_at, next_plan) VALUES (1, 'pro', ?, NULL, 'next_pro')`, Date.now())
    })
    expect(answer).toEqual({ ok: true, paid: true, user_limit_usd: expect.any(Number), plan: "pro", next_plan: "next_pro", chief_addon: null, next_plan_started_at: null, next_plan_ends_at: null })
    expect(reads).toBe(0)
  })

  it("carries chief_addon in the stored copy, a webhook-style store with it keeps it, and one without it clears it", async () => {
    let reads = 0
    const stack = { getUserPlans: async () => (reads++, { plan: "pro", next_plan: null, chief_addon: "XL" }) } as unknown as StackServer
    const [first, cached, withAddon, afterStore] = await inDO(teamStub(`personal-${crypto.randomUUID()}`), async (_i, state) => {
      const sql = state.storage.sql
      const now = Date.now()
      const a = await inferencePlanOf(sql, null, "entity", stack, "stack-user", "user", now)
      const b = await inferencePlanOf(sql, null, "entity", stack, "stack-user", "user", now + 1)
      storePlan(sql, "pro", now + 2, null, "chief_l")
      const c = await inferencePlanOf(sql, null, "entity", stack, "stack-user", "user", now + 3)
      storePlan(sql, "pro", now + 4)
      const d = await inferencePlanOf(sql, null, "entity", stack, "stack-user", "user", now + 5)
      return [a, b, c, d]
    })
    expect(first).toMatchObject({ paid: true, plan: "pro", chief_addon: "XL" })
    expect(cached).toEqual(first)
    expect(reads).toBe(1)
    expect(withAddon).toMatchObject({ paid: true, plan: "pro", chief_addon: "L" })
    expect(afterStore).toMatchObject({ paid: true, plan: "pro", chief_addon: null })
  })

  it("keeps chief_addon when a Chief's test plan grant makes the answer paid", async () => {
    const stack = { getUserPlans: async () => ({ plan: null, next_plan: null, chief_addon: "M" }) } as unknown as StackServer
    const answer = await inDO(teamStub(`personal-${crypto.randomUUID()}`), async (_i, state) => {
      const sql = state.storage.sql
      grantTestPlan(sql, "pro", "cs_test_1", "sub_1", Date.now())
      return inferencePlanOf(sql, null, "entity", stack, "stack-user", "user", Date.now(), true)
    })
    expect(answer).toEqual({ ok: true, paid: true, user_limit_usd: expect.any(Number), plan: "pro", next_plan: null, chief_addon: "M", next_plan_started_at: null, next_plan_ends_at: null })
  })

  it("leaves the unavailable answer unchanged", async () => {
    const stack = { getUserPlans: async () => Promise.reject(new Error("stack down")) } as unknown as StackServer
    expect(await personal(stack)).toEqual({ ok: false, reason: "unavailable" })
  })
})
