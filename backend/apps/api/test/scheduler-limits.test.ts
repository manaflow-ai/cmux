import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { RUN_BURST } from "../src/domains/scheduler-limits.ts"

/** Slice 2: provider events refused by the run limits are kept and retried, never lost. */

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; SCHEDULER_DO: DurableObjectNamespace }
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
const op = async (t: string, name: string, params: unknown) => {
  const res = await worker.fetch("https://api.test/v1/ops", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${t}` },
    body: JSON.stringify({ op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
  })
  return (await res.json()) as any
}

describe("run limits keep provider events (workerd)", () => {
  it("defers events past the creation burst and starts them after the bucket refills", async () => {
    const t = await token("limits-user-1")
    const team = (await op(t, "user.ensure", {})).value.personal_team as string
    const connection = "conn_aaaaaaaaaaaaaaaaaaaa"
    const created = await op(t, "automation.create", {
      name: "on issue",
      triggers: [{ type: "event", source: "integration", connection, event: "issue.opened" }],
      body: { type: "steps", steps: [{ type: "note", text: "n" }] },
      concurrency: { max: 1, on_limit: "queue" }
    })
    expect(created.ok).toBe(true)
    const stub = testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(team))
    await inDO(stub, async (s) => {
      const ev = (i: number) => ({ connection, sharing: "team", created_by: "someone", provider: "github", event: "issue.opened", delivery_id: `d${i}`, payload: { n: i } })
      let runs = 0
      for (let i = 0; i < RUN_BURST + 5; i++) runs += (await s.deliverEvent(team, ev(i))).runs
      expect(runs).toBe(RUN_BURST)
      const waiting = () => Number(s.ctx.storage.sql.exec("SELECT COUNT(*) AS n FROM deferred_deliveries").toArray()[0].n)
      expect(waiting()).toBe(5)
      // A redelivery of a deferred event does not add a second row.
      await s.deliverEvent(team, ev(RUN_BURST))
      expect(waiting()).toBe(5)
      // Real time must pass: the bucket refills from the engine clock (5 tokens a second).
      await new Promise((r) => setTimeout(r, 1200))
      await s.onWake(Date.now())
      expect(waiting()).toBe(0)
      const open = Object.values(s.boundEngine.currentState.runs as Record<string, { trigger: { delivery_id?: string } }>)
      expect(new Set(open.map((r) => r.trigger.delivery_id)).size).toBe(RUN_BURST + 5)
    })
  })
})
