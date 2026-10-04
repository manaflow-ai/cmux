import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"

/**
 * POST /v1/admin/cloud/abandoned/clear: an operator key AND a person's own session token
 * (x-cmux-person-token); never an install or an agent. A reason (8..500 characters) is required.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; CLOUD_ADMIN_KEY: string }
const worker = (exports as unknown as { default: Fetcher }).default
const token = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const clear = async (headers: Record<string, string>, body: unknown) => {
  const res = await worker.fetch("https://api.test/v1/admin/cloud/abandoned/clear", { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) })
  return { status: res.status, body: (await res.json()) as any }
}
const BODY = { team: "team_00000000000000000000", machine: "vm_00000000000000000000", reason: "VM gone in the provider console" }

describe("cloud abandoned clear route", () => {
  it("needs the operator key", async () => {
    expect((await clear({}, BODY)).status).toBe(401)
    expect((await clear({ authorization: "Bearer wrong-key-wrong-key-wrong-key-wrong" }, BODY)).status).toBe(401)
  })
  it("needs a person's session token, not just the key", async () => {
    const key = { authorization: `Bearer ${testEnv.CLOUD_ADMIN_KEY}` }
    expect((await clear(key, BODY)).status).toBe(403)
    expect((await clear({ ...key, "x-cmux-person-token": "not-a-token" }, BODY)).status).toBe(403)
  })
  it("validates the body and reaches CloudDO with a person", async () => {
    const h = { authorization: `Bearer ${testEnv.CLOUD_ADMIN_KEY}`, "x-cmux-person-token": await token("ops_person_1") }
    expect((await clear(h, { ...BODY, reason: "short" })).status).toBe(400)
    expect((await clear(h, { ...BODY, machine: "nope" })).status).toBe(400)
    const r = await clear(h, BODY)
    expect(r).toMatchObject({ status: 404, body: { error: "not_abandoned" } })
  })
})
