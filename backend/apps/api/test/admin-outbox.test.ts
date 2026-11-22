import { env, exports } from "cloudflare:workers"
import { runInDurableObject as runIn } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { handleOutboxReplay } from "../src/admin-outbox.ts"
import { userIdFor } from "../src/domains/user.ts"

/** The operator replay tool for dead outbox items (home-scale review P1). */
const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any) => Promise<T>) => Promise<T>
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const KEY = "k".repeat(40)

describe("outbox replay tool", { timeout: 60_000 }, () => {
  it("needs the operator key, and puts dead items back in the queue", async () => {
    const sub = "outbox-replay-1"
    const token = await new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
      .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
      .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
      .setAudience(testEnv.STACK_PROJECT_ID)
      .setSubject(sub)
      .setIssuedAt()
      .setExpirationTime("10m")
      .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
    await worker.fetch("https://api.test/v1/ops", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ op: "user.ensure", params: {}, idempotency_key: "e1", origin: "user" }) })
    const user = userIdFor(testEnv.STACK_PROJECT_ID, sub)
    const stub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
    const deadId = await runInDurableObject(stub, async (i) => {
      const row = i.engine.outbox.allPending(1)[0]
      i.engine.outbox.deadLetter(row.id, Date.now())
      return row.id as number
    })
    const call = (key: string | undefined, auth: string | null, body: unknown) =>
      handleOutboxReplay(
        new Request("https://api.test/v1/admin/outbox/replay", { method: "POST", headers: { "content-type": "application/json", ...(auth ? { authorization: `Bearer ${auth}` } : {}) }, body: JSON.stringify(body) }),
        Object.assign({}, env as object, { OUTBOX_ADMIN_KEY: key }) as never
      )
    expect((await call(undefined, KEY, { class: "UserDO", name: user })).status).toBe(404)
    expect((await call(KEY, "wrong", { class: "UserDO", name: user })).status).toBe(401)
    expect((await call(KEY, KEY, { class: "HostDO", name: user })).status).toBe(400)
    const ok = await call(KEY, KEY, { class: "UserDO", name: user, ids: [deadId] })
    expect(ok.status).toBe(200)
    expect(await ok.json()).toEqual({ replayed: 1, dead: 0 })
  })
})
