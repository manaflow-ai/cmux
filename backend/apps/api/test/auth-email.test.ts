import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
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
  it("is stored on the user profile by user.ensure, so install tokens carry it too", async () => {
    // Only a boolean true from Stack counts: false, a missing claim and the string "true" are unverified.
    const cases = [["ev-store-yes", { email_verified: true }, true], ["ev-store-no", { email_verified: false }, false], ["ev-store-absent", {}, false], ["ev-store-string", { email_verified: "true" }, false]] as const
    for (const [sub, claims, verified] of cases) {
      const t = await token(sub, claims)
      const call = (path: string, body: unknown) =>
        worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) }).then((r) => r.json() as Promise<any>)
      expect((await call("/v1/ops", { op: "user.ensure", params: {}, idempotency_key: `ensure-${sub}` })).ok).toBe(true)
      const list = await call("/v1/read", { op: "install.list", params: {} })
      expect(list.value.user.email_verified).toBe(verified)
    }
  })
})
