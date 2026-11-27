import { env, exports } from "cloudflare:workers"
import { createExecutionContext, runInDurableObject, waitOnExecutionContext } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import worker from "../../src/index.ts"
import { userIdFor } from "../../src/domains/user.ts"
import { storePlan } from "../../src/inference/plan.ts"

/** Shared by the model router billing tests (cx-y79zh): a paid person, a chat call through the Worker's fetch handler. */
export const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USAGE_METER_DO: DurableObjectNamespace; TEAM_DO: DurableObjectNamespace }
export const loopback = (exports as unknown as { default: Fetcher }).default
export const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any) => Promise<void>) => Promise<void>
export const MODEL = "qwen/qwen3.7-flash"

export const token = async (stackUser: string) => {
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
export const post = async (path: string, t: string, body: unknown) => {
  const res = await loopback.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) })
  return (await res.json()) as any
}

/** A signed-in person on a paid personal plan (the plan copy TeamDO keeps, inference/plan.ts). */
export const paidPerson = async (stackUser: string, plan = "pro") => {
  const t = await token(stackUser)
  const ensured = await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })
  const team = ensured.value.personal_team as string
  await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)), async (i) => storePlan(i.ctx.storage.sql, plan, Date.now()))
  return { t, team, user: userIdFor(testEnv.STACK_PROJECT_ID, stackUser) }
}

/** One chat call through the Worker's fetch handler; returns after every waitUntil (the settle) ended. */
export const chat = async (t: string, runEnv: unknown = env) => {
  const ctx = createExecutionContext()
  const res = await worker.fetch!(
    new Request("https://api.test/v1/inference/chat/completions", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify({ model: MODEL, max_tokens: 64, messages: [{ role: "user", content: "hi" }] }) }) as any,
    runEnv as any,
    ctx
  )
  const text = await res.text()
  await waitOnExecutionContext(ctx)
  return { status: res.status, text }
}

