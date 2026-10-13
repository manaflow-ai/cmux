import { env, exports } from "cloudflare:workers"
import { createExecutionContext, runInDurableObject, waitOnExecutionContext } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { afterEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.ts"
import { userIdFor } from "../src/domains/user.ts"
import { storePlan } from "../src/inference/plan.ts"

/**
 * cx-y79zh S1 (plans/cmux-next/usage-billing.md): one model router call is one fact, and the member's
 * monthly spend and the team's model spend read that same fact. Driven at the route
 * (POST /v1/inference/chat/completions) with the provider faked at its HTTP boundary.
 */

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USAGE_METER_DO: DurableObjectNamespace; TEAM_DO: DurableObjectNamespace }
const loopback = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any) => Promise<void>) => Promise<void>
const MODEL = "qwen/qwen3.7-flash"

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
const post = async (path: string, t: string, body: unknown) => {
  const res = await loopback.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) })
  return (await res.json()) as any
}

/** A signed-in person on a paid personal plan (the plan copy TeamDO keeps, inference/plan.ts). */
const paidPerson = async (stackUser: string) => {
  const t = await token(stackUser)
  const ensured = await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })
  const team = ensured.value.personal_team as string
  await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)), async (i) => storePlan(i.ctx.storage.sql, "pro", Date.now()))
  return { t, team, user: userIdFor(testEnv.STACK_PROJECT_ID, stackUser) }
}

/** One chat call through the Worker's fetch handler; returns after every waitUntil (the settle) ended. */
const chat = async (t: string) => {
  const ctx = createExecutionContext()
  const res = await worker.fetch!(
    new Request("https://api.test/v1/inference/chat/completions", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify({ model: MODEL, max_tokens: 64, messages: [{ role: "user", content: "hi" }] }) }) as any,
    env as any,
    ctx
  )
  const text = await res.text()
  await waitOnExecutionContext(ctx)
  return { status: res.status, text }
}

/** The provider's chat/completions endpoint answers `reply`; every other request goes out as usual. */
const fakeProvider = (reply: () => Response) => {
  const real = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input instanceof Request ? input.url : String(input)
    return url.startsWith("https://openrouter.ai/") ? reply() : real(input, init)
  })
}

const counters = async (t: string, team: string, user: string) => {
  const summary = await post("/v1/read", t, { op: "usage.summary", params: {} })
  const model = summary.value.meters.find((m: any) => m.meter === "model.spend_usd")
  const spends = await (testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)) as any).userSpends(team, [user])
  let facts: Array<{ key: string; user: string | null; quantity: number; source: string }> = []
  await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)), async (m) => {
    facts = m.ctx.storage.sql.exec(`SELECT key, user, quantity, source FROM usage_ledger WHERE meter = 'model.spend_usd'`).toArray()
  })
  return { team_usd: model.usd as number, member_usd: spends[user] as number, facts }
}

/** The provider answers only when the test releases it; `asked` resolves when the request arrived. */
const heldProvider = (reply: () => Response) => {
  const real = globalThis.fetch
  let release!: () => void
  let arrived!: () => void
  const gate = new Promise<void>((r) => (release = r))
  const asked = new Promise<void>((r) => (arrived = r))
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input instanceof Request ? input.url : String(input)
    if (!url.startsWith("https://openrouter.ai/")) return real(input, init)
    arrived()
    await gate
    return reply()
  })
  return { asked, release }
}

const LEVELS_KEY = "test-billing-levels-key-0123456789abcdef"
/** The reconcile worker's read: POST /v1/internal/billing/levels. */
const levels = async (items: unknown, key = LEVELS_KEY) => {
  const res = await loopback.fetch("https://api.test/v1/internal/billing/levels", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${key}` }, body: JSON.stringify({ items }) })
  return { status: res.status, body: (await res.json()) as any }
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe("model router spend is one fact (cx-y79zh S1)", () => {
  it("a settled call writes one fact that the member spend and the team spend both count", async () => {
    const { t, team, user } = await paidPerson("spend-facts-settled")
    fakeProvider(() => Response.json({ id: "x", choices: [{ index: 0, message: { role: "assistant", content: "hello" } }], usage: { prompt_tokens: 10, completion_tokens: 5, cost: 0.000012 } }))
    const r = await chat(t)
    expect(r.status).toBe(200)
    const c = await counters(t, team, user)
    expect(c.facts).toHaveLength(1)
    expect(c.facts[0]).toMatchObject({ user, quantity: 0.000012, source: "coderouter" })
    expect(c.member_usd).toBeCloseTo(0.000012, 9)
    expect(c.team_usd).toBeCloseTo(0.000012, 9)
  })

  it("a call the provider may have billed (a broken body) is charged in full on both counters", async () => {
    const { t, team, user } = await paidPerson("spend-facts-charged")
    fakeProvider(() => new Response("not json", { status: 200, headers: { "content-type": "application/json" } }))
    const r = await chat(t)
    expect(r.status).toBe(502)
    const c = await counters(t, team, user)
    expect(c.facts).toHaveLength(1)
    expect(c.facts[0]).toMatchObject({ user, source: "coderouter" })
    expect(c.member_usd).toBeGreaterThan(0)
    // Before S1 the team counter stayed at 0 here: the member and the team disagreed.
    expect(c.team_usd).toBeCloseTo(c.member_usd, 6)
    expect(c.facts[0]!.quantity).toBeCloseTo(c.member_usd, 6)
  })

  it("a billable fact outlives the 35-day dedupe window (S2: nothing deletes a bill's input)", async () => {
    const { t, team, user } = await paidPerson("spend-facts-kept")
    fakeProvider(() => Response.json({ id: "x", choices: [{ index: 0, message: { role: "assistant", content: "kept" } }], usage: { prompt_tokens: 10, completion_tokens: 5, cost: 0.000004 } }))
    expect((await chat(t)).status).toBe(200)
    // The alarm 40 days later prunes old dedupe keys; the call's money fact stays.
    await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)), async (m) => m.onWake(Date.now() + 40 * 86_400_000))
    const c = await counters(t, team, user)
    expect(c.facts).toHaveLength(1)
    expect(c.facts[0]).toMatchObject({ user, quantity: 0.000004, source: "coderouter" })
  })

  it("a reservation that expires is charged in full, and a late settle is a correction fact on both counters", async () => {
    const { t, team, user } = await paidPerson("spend-facts-late")
    const held = heldProvider(() => Response.json({ id: "x", choices: [{ index: 0, message: { role: "assistant", content: "late" } }], usage: { prompt_tokens: 10, completion_tokens: 5, cost: 0.000003 } }))
    const call = chat(t)
    await held.asked
    // The alarm runs past the reservation TTL while the provider has not answered yet.
    await inDO(testEnv.USAGE_METER_DO.get(testEnv.USAGE_METER_DO.idFromName(team)), async (m) => m.onWake(Date.now() + 2 * 3600_000))
    const expired = await counters(t, team, user)
    expect(expired.facts.map((f) => f.source)).toEqual(["coderouter.expired"])
    expect(expired.team_usd).toBeCloseTo(expired.member_usd, 9)
    expect(expired.member_usd).toBeGreaterThan(0.000003)
    held.release()
    expect((await call).status).toBe(200)
    const settled = await counters(t, team, user)
    expect(settled.facts.map((f) => f.source).sort()).toEqual(["coderouter.expired", "coderouter.late"])
    expect(settled.facts.every((f) => f.user === user)).toBe(true)
    expect(settled.member_usd).toBeCloseTo(0.000003, 9)
    expect(settled.team_usd).toBeCloseTo(0.000003, 9)
    // The bill's level reads the same facts: the expired charge plus its correction is the real cost.
    // The expired fact is recorded at the alarm's time (2 h ahead in this test), so the window covers it.
    const l = await levels([{ stack_user: "spend-facts-late", from: 0, to: Date.now() + 3 * 3600_000 }])
    expect(l.body.levels[0]).toMatchObject({ team, micros: 3, facts: 2, price_version: "ai-passthrough-v1" })
  })

  it("the billing level of a period is the sum of the facts recorded in it, read with the service key only", async () => {
    const { t, team } = await paidPerson("spend-facts-level")
    const before = Date.now()
    fakeProvider(() => Response.json({ id: "x", choices: [{ index: 0, message: { role: "assistant", content: "a" } }], usage: { prompt_tokens: 10, completion_tokens: 5, cost: 0.000005 } }))
    expect((await chat(t)).status).toBe(200)
    expect((await chat(t)).status).toBe(200)
    const after = Date.now() + 1
    const r = await levels([
      { stack_user: "spend-facts-level", from: before, to: after },
      { stack_user: "spend-facts-level", from: 0, to: before },
      { stack_team: "no-such-team", from: before, to: after }
    ])
    expect(r.status).toBe(200)
    expect(r.body.levels[0]).toMatchObject({ team, micros: 10, facts: 2 })
    expect(r.body.levels[1]).toMatchObject({ team, micros: 0, facts: 0, last_at: null })
    expect(r.body.levels[2]).toMatchObject({ micros: 0, facts: 0 })
    // Asking twice gives the same level (the worker sends levels, never deltas).
    expect((await levels([{ stack_user: "spend-facts-level", from: before, to: after }])).body.levels[0].micros).toBe(10)
    expect((await levels([{ stack_user: "spend-facts-level", from: before, to: after }], "wrong-key-0123456789abcdef0123456789")).status).toBe(401)
    expect((await levels([{ stack_user: "x", stack_team: "y", from: 0, to: 1 }])).status).toBe(400)
  })
})
