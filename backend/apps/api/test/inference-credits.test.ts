import { env } from "cloudflare:workers"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.ts"
import { chat, inDO, paidPerson, post, testEnv, token } from "./setup/inference-person.ts"
import { userIdFor } from "../src/domains/user.ts"

/**
 * Paid plan step 1 (plans/cmux-next/paid-plan.md): "Use cmux credits". A signed-in person with no
 * paid plan pays the model router from their prepaid credits (credits.ts, the same ledger Cloud Chief
 * uses). Driven at POST /v1/inference/chat/completions with the provider faked at its HTTP boundary.
 */

const KEY = "test-billing-levels-key-0123456789abcdef"

const fakeProvider = (reply: () => Response) => {
  const real = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input instanceof Request ? input.url : String(input)
    return url.startsWith("https://openrouter.ai/") ? reply() : real(input, init)
  })
}

const ok = (cost: number) => () => Response.json({ id: "x", choices: [{ index: 0, message: { role: "assistant", content: "hello" } }], usage: { prompt_tokens: 10, completion_tokens: 5, cost } })

/** A signed-in person with no plan copy (unpaid) and an optional operator grant of credits. */
const unpaidPerson = async (stackUser: string, usd = 0) => {
  const t = await token(stackUser)
  const ensured = await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })
  const team = ensured.value.personal_team as string
  // No paid plan: the plan copy says "no plan" (fresh), so no Stack read happens.
  await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)), async (i) => {
    i.ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS inference_plan (id INTEGER PRIMARY KEY CHECK (id = 1), plan TEXT, checked_at INTEGER NOT NULL, failed_at INTEGER)`)
    i.ctx.storage.sql.exec(`INSERT OR REPLACE INTO inference_plan (id, plan, checked_at, failed_at) VALUES (1, NULL, ?, NULL)`, Date.now())
  })
  if (usd > 0) {
    const ctx = createExecutionContext()
    const res = await worker.fetch!(
      new Request("https://api.test/v1/internal/credits", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${KEY}` }, body: JSON.stringify({ action: "grant", team, usd, actor: "test", reason: "router credits test", key: `g-${stackUser}` }) }) as any,
      env as any,
      ctx
    )
    await waitOnExecutionContext(ctx)
    expect(res.status).toBe(200)
  }
  return { t, team, user: userIdFor(testEnv.STACK_PROJECT_ID, stackUser) }
}

const balance = async (t: string) => {
  const ctx = createExecutionContext()
  const res = await worker.fetch!(new Request("https://api.test/v1/credits", { headers: { authorization: `Bearer ${t}` } }) as any, env as any, ctx)
  await waitOnExecutionContext(ctx)
  return ((await res.json()) as { value: { available_usd: number; balance_usd: number; held_usd: number } }).value
}

const billableFacts = async (team: string) => {
  let n = 0
  await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)), async (m) => {
    n = m.ctx.storage.sql.exec(`SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'usage_ledger'`).one().n
      ? Number(m.ctx.storage.sql.exec(`SELECT COUNT(*) AS n FROM usage_ledger WHERE meter = 'model.spend_usd'`).one().n)
      : 0
  })
  return n
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe("the model router takes cmux credits (paid-plan step 1)", () => {
  it("a person with no plan and no credits gets a 402 that offers both ways out", async () => {
    const { t } = await unpaidPerson("router-credits-none")
    fakeProvider(ok(0.00001))
    const r = await chat(t)
    expect(r.status).toBe(402)
    const body = JSON.parse(r.text)
    expect(body.error.code).toBe("inference.plan_required")
    expect(body.error.details.actions).toEqual(["add_credits", "add_api_key", "see_plans"])
    expect(body.error.details.credits).toMatchObject({ available_usd: 0, topup_path: "/v1/credits/topup" })
  })

  it("a person with no plan but credits is served and the call is charged to the credits, not billed", async () => {
    const { t, team } = await unpaidPerson("router-credits-some", 1)
    fakeProvider(ok(0.000012))
    const r = await chat(t)
    expect(r.status).toBe(200)
    const b = await balance(t)
    expect(b.held_usd).toBe(0)
    expect(b.balance_usd).toBeCloseTo(1 - 0.000012, 6)
    // Prepaid: never a billable fact, so the same call is never paid twice.
    expect(await billableFacts(team)).toBe(0)
  })

  it("credits below the call's maximum price refuse before any provider call", async () => {
    const { t } = await unpaidPerson("router-credits-low", 0.000001)
    let called = 0
    fakeProvider(() => {
      called++
      return ok(0.00001)()
    })
    const r = await chat(t)
    expect(r.status).toBe(402)
    const body = JSON.parse(r.text)
    expect(body.error.code).toBe("credits.insufficient")
    expect(body.error.details.actions).toEqual(["add_credits", "add_api_key", "see_plans"])
    expect(body.error.details.needed_usd).toBeGreaterThan(body.error.details.available_usd)
    expect(called).toBe(0)
  })

  it("a call the provider fails before the first byte releases the hold", async () => {
    const { t } = await unpaidPerson("router-credits-fail", 1)
    fakeProvider(() => new Response("busy", { status: 503 }))
    const r = await chat(t)
    expect(r.status).toBe(502)
    const b = await balance(t)
    expect(b.held_usd).toBe(0)
    expect(b.balance_usd).toBe(1)
  })

  it("a paid person still uses the plan path (no credits charged)", async () => {
    const { t } = await paidPerson("router-credits-paid")
    fakeProvider(ok(0.00001))
    expect((await chat(t)).status).toBe(200)
  })
})
