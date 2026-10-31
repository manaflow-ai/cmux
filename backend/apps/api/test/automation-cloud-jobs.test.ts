import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { storePlan } from "../src/inference/plan.ts"

/**
 * Cloud Chief jobs made from the person's own clients (`cmux automation create --target cloud`, the Mac
 * app's Automations page): `automation.create` with a `chief` body over /v1/ops as the signed-in user
 * (docs/automations-platonic-ideal.md, Cloud slice). The free plan has one Cloud job, the same cap as
 * `chief-auto` (chief-brain-cc/jobs.ts FREE_CHIEF_JOBS); the next create answers
 * `automation.plan.required` with a signed Stripe test checkout link. A paid plan is not capped.
 */
type TestEnv = Record<string, string | undefined> & { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; TEAM_DO: DurableObjectNamespace }
const testEnv = env as unknown as TestEnv
const worker = (exports as unknown as { default: Fetcher }).default
const sessionToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const post = async (path: string, token: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify(body) })
  return (await res.json()) as any
}
const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => post("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "cli" })
const read = (token: string, name: string, params: unknown) => post("/v1/read", token, { op: name, params })
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any) => Promise<unknown>) => Promise<any>

const person = async (sub: string, plan: string | null) => {
  const token = await sessionToken(sub)
  const ensured = (await op(token, "user.ensure", {})).value as { id: string; personal_team: string }
  const ns = testEnv.TEAM_DO as unknown as { get(id: unknown): unknown; idFromName(n: string): unknown }
  await inDO(ns.get(ns.idFromName(ensured.personal_team)), async (i) => storePlan(i.ctx.storage.sql, plan, Date.now()))
  const chief = (await op(token, "chief.create", { display_name: "Jobs Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  return { token, chief }
}
const job = (chief: { id: string; main_conversation: string }, name: string) => ({
  name,
  triggers: [{ type: "cron", expr: "0 9 * * 1-5", tz: "America/Los_Angeles" }, { type: "manual" }],
  body: { type: "chief", chief: chief.id, conversation: chief.main_conversation, prompt: `${name}: summarize merged PRs.` }
})

describe("Cloud Chief jobs from the person's clients", { timeout: 60_000 }, () => {
  it("the free plan gets one Cloud job; the second answers automation.plan.required with a checkout link", async () => {
    const p = await person("cloud-jobs-free", null)
    const first = await op(p.token, "automation.create", job(p.chief, "Morning brief"), "k-brief")
    expect(first.ok, JSON.stringify(first)).toBe(true)
    // A retried create (same key) is the same job, not a second one the cap refuses (staging proof 2026-10-31).
    const retried = await op(p.token, "automation.create", job(p.chief, "Morning brief"), "k-brief")
    expect(retried.ok, JSON.stringify(retried)).toBe(true)
    expect(retried.value.id).toBe(first.value.id)
    expect(first.value.body).toMatchObject({ type: "chief", chief: p.chief.id })
    const second = await op(p.token, "automation.create", job(p.chief, "Second brief"))
    expect(second.ok).toBe(false)
    expect(second.error.code).toBe("automation.plan.required")
    expect(second.error.details).toMatchObject({ plan: "pro" })
    expect(String(second.error.details.checkout)).toMatch(/\/v1\/billing\/plan\/|cmux\.com\/pricing/)
    const list = await read(p.token, "automation.list", {})
    expect(list.value.automations.map((a: any) => a.name)).toEqual(["Morning brief"])
  })

  it("a paid plan is not capped, and a retried create with the same key makes one job", async () => {
    const p = await person("cloud-jobs-paid", "pro")
    expect((await op(p.token, "automation.create", job(p.chief, "One"), "k-one")).ok).toBe(true)
    expect((await op(p.token, "automation.create", job(p.chief, "One"), "k-one")).ok).toBe(true)
    expect((await op(p.token, "automation.create", job(p.chief, "Two"))).ok).toBe(true)
    const list = await read(p.token, "automation.list", {})
    expect(list.value.automations.map((a: any) => a.name).sort()).toEqual(["One", "Two"])
  })

  it("a non-chief automation is not counted against the Cloud job cap", async () => {
    const p = await person("cloud-jobs-steps", null)
    const steps = await op(p.token, "automation.create", { name: "Note", triggers: [{ type: "manual" }], body: { type: "steps", steps: [{ type: "note", text: "hi" }] } })
    expect(steps.ok, JSON.stringify(steps)).toBe(true)
    expect((await op(p.token, "automation.create", job(p.chief, "Brief"))).ok).toBe(true)
  })
})
