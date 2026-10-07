import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { authenticate } from "../src/auth.ts"
import type { Env } from "../src/env.ts"

const testEnv = env as unknown as Env & { STACK_TEST_PRIVATE_JWK: string }
const worker = (exports as unknown as { default: Fetcher }).default

const token = async (sub: string, claims: Record<string, unknown>) =>
  new SignJWT({ email: `${sub}@example.com`, name: sub, ...claims })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))

describe("verified email on the principal (lane 15 security blocker)", () => {
  it("is true only when Stack asserts email_verified === true", async () => {
    expect((await authenticate(testEnv, await token("ev-yes", { email_verified: true })))?.email_verified).toBe(true)
    expect((await authenticate(testEnv, await token("ev-no", { email_verified: false })))?.email_verified).toBe(false)
    expect((await authenticate(testEnv, await token("ev-absent", {})))?.email_verified).toBe(false)
    expect((await authenticate(testEnv, await token("ev-string", { email_verified: "true" })))?.email_verified).toBe(false)
  })

  it("is stored on the user profile by user.ensure, so install tokens carry it too", async () => {
    for (const [sub, verified] of [["ev-store-yes", true], ["ev-store-no", false]] as const) {
      const t = await token(sub, { email_verified: verified })
      const call = (path: string, body: unknown) =>
        worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) }).then((r) => r.json() as Promise<any>)
      expect((await call("/v1/ops", { op: "user.ensure", params: {}, idempotency_key: `ensure-${sub}` })).ok).toBe(true)
      const list = await call("/v1/read", { op: "install.list", params: {} })
      expect(list.value.user.email_verified).toBe(verified)
    }
  })
})
