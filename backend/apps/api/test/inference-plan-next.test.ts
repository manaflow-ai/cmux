import { describe, expect, it } from "vitest"
import type { TeamState } from "../src/domains/team.ts"
import { grantTestPlan, inferencePlanOf, storePlan } from "../src/inference/plan.ts"
import { stackServer, type StackServer } from "../src/stack-server.ts"
import { PROJECT, teamStub } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"

/**
 * TeamDO.inferencePlan also answers `next_plan` for the Cloud service: the record's
 * client_read_only_metadata.cmuxNextPlan when it is exactly next_pro or next_max, else null. It is read
 * from the same record and read as `plan` (cmuxPlan), and never changes `paid`, the limit or `plan`.
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

describe("inferencePlan next_plan (cmuxNextPlan)", () => {
  it("answers next_pro from the owner's user record, in the same single read as plan", async () => {
    const f = fakeHttp({ cmuxPlan: "pro", cmuxNextPlan: "next_pro" })
    expect(await personal(stackServer(env, f.http)!)).toEqual({ ok: true, paid: true, user_limit_usd: expect.any(Number), plan: "pro", next_plan: "next_pro", chief_addon: null })
    expect(f.sent).toEqual([{ method: "GET", path: "/users/stack-user" }])
  })

  it("answers next_max, and null for an unknown, wrong-typed or absent value", async () => {
    expect((await personal(stackServer(env, fakeHttp({ cmuxNextPlan: "next_max" }).http)!)) as any).toMatchObject({ next_plan: "next_max" })
    // cmux NEXT Plus is a NEXT plan like the others; it never makes the record `paid` for the model router.
    expect(await personal(stackServer(env, fakeHttp({ cmuxNextPlan: "next_plus" }).http)!)).toMatchObject({ paid: false, plan: null, next_plan: "next_plus" })
    for (const meta of [{ cmuxNextPlan: "next_ultra" }, { cmuxNextPlan: "pro" }, { cmuxNextPlan: "NEXT_PRO" }, { cmuxNextPlan: 1 }, { cmuxPlan: "pro" }, undefined])
      expect(((await personal(stackServer(env, fakeHttp(meta).http)!)) as any).next_plan).toBeNull()
  })

  it("keeps paid, the limit and plan unchanged when only cmuxNextPlan is set", async () => {
    const withNext = await personal(stackServer(env, fakeHttp({ cmuxNextPlan: "next_max" }).http)!)
    const without = await personal(stackServer(env, fakeHttp({}).http)!)
    expect(withNext).toEqual({ ok: true, paid: false, user_limit_usd: (without as any).user_limit_usd, plan: null, next_plan: "next_max", chief_addon: null })
    expect(without).toEqual({ ok: true, paid: false, user_limit_usd: (withNext as any).user_limit_usd, plan: null, next_plan: null, chief_addon: null })
  })

  it("reads next_plan from the Stack team record for a shared team", async () => {
    const f = fakeHttp({ cmuxPlan: "team", cmuxNextPlan: "next_pro" })
    const answer = await inDO(teamStub(`shared-${crypto.randomUUID()}`), async (_i, state) => {
      const team = { team: { id: "t1", kind: "stack", display_name: "Acme", stack_team: "st1" } } as unknown as TeamState
      return inferencePlanOf(state.storage.sql, team, "t1", stackServer(env, f.http)!, undefined, "user")
    })
    expect(answer).toMatchObject({ ok: true, paid: true, plan: "team", next_plan: "next_pro" })
    expect(f.sent.filter((s) => s.path === "/teams/st1")).toHaveLength(1)
  })

  it("answers a fresh copy stored before next_plan existed with next_plan null, without a read", async () => {
    let reads = 0
    const stack = { getUserPlan: async () => (reads++, "max"), getUserPlans: async () => (reads++, { plan: "max", next_plan: "next_max" }) } as unknown as StackServer
    const answer = await personal(stack, (sql) => {
      // The table and row as an older Worker wrote them: no next_plan column.
      sql.exec(`CREATE TABLE inference_plan (id INTEGER PRIMARY KEY CHECK (id = 1), plan TEXT, checked_at INTEGER NOT NULL, failed_at INTEGER)`)
      sql.exec(`INSERT INTO inference_plan (id, plan, checked_at, failed_at) VALUES (1, 'pro', ?, NULL)`, Date.now())
    })
    expect(answer).toEqual({ ok: true, paid: true, user_limit_usd: expect.any(Number), plan: "pro", next_plan: null, chief_addon: null })
    expect(reads).toBe(0)
  })

  it("carries next_plan in the stored copy, and a webhook-style store without it clears it", async () => {
    let reads = 0
    const stack = { getUserPlans: async () => (reads++, { plan: null, next_plan: "next_pro" }) } as unknown as StackServer
    const [first, cached, afterStore] = await inDO(teamStub(`personal-${crypto.randomUUID()}`), async (_i, state) => {
      const sql = state.storage.sql
      const now = Date.now()
      const a = await inferencePlanOf(sql, null, "entity", stack, "stack-user", "user", now)
      const b = await inferencePlanOf(sql, null, "entity", stack, "stack-user", "user", now + 1)
      storePlan(sql, "pro", now + 2)
      const c = await inferencePlanOf(sql, null, "entity", stack, "stack-user", "user", now + 3)
      return [a, b, c]
    })
    expect(first).toMatchObject({ paid: false, plan: null, next_plan: "next_pro" })
    expect(cached).toEqual(first)
    expect(reads).toBe(1)
    expect(afterStore).toMatchObject({ paid: true, plan: "pro", next_plan: null })
  })

  it("keeps next_plan when a Chief's test plan grant makes the answer paid", async () => {
    const stack = { getUserPlans: async () => ({ plan: null, next_plan: "next_pro" }) } as unknown as StackServer
    const answer = await inDO(teamStub(`personal-${crypto.randomUUID()}`), async (_i, state) => {
      const sql = state.storage.sql
      grantTestPlan(sql, "pro", "cs_test_1", "sub_1", Date.now())
      return inferencePlanOf(sql, null, "entity", stack, "stack-user", "user", Date.now(), true)
    })
    expect(answer).toEqual({ ok: true, paid: true, user_limit_usd: expect.any(Number), plan: "pro", next_plan: "next_pro", chief_addon: null })
  })

  it("leaves the unavailable answer unchanged", async () => {
    const stack = { getUserPlans: async () => Promise.reject(new Error("stack down")) } as unknown as StackServer
    expect(await personal(stack)).toEqual({ ok: false, reason: "unavailable" })
  })
})
