import { env } from "cloudflare:workers"
import { createLocalJWKSet, decodeProtectedHeader, jwtVerify, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { authenticate, publicJwks } from "../src/auth.ts"
import type { Env } from "../src/env.ts"
import { CODEROUTER_EDGE_DOMAIN, CODEROUTER_EDGE_HEADER, CODEROUTER_TOKEN_TTL_S, coderouterEdgeConfig, mintCoderouterMachineToken } from "../src/cloud-coderouter-edge.ts"
import { createdAndBound, ensureUser, frame, person, reply, SIZE } from "./cloud-bind-support.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * plans/cmux-next/vm-coderouter-edge.md: a development machine reaches coderouter through an inline
 * Freestyle TLS rule for coderouter.cmux.internal. The edge injects a per-machine ES256 token
 * (aud coderouter, 1 hour); the guest never holds it. Only development (and test) send the rule.
 */

const E = env as unknown as Env
const HOST = "coderouter-staging.example.com"
interface EdgeRule {
  vm: string
  domain: string
  rule: { action: string; domain: string; source: Record<string, unknown>; destination: { host?: string; port?: number }; transform: Array<{ headers: Record<string, string> }> }
}
interface EdgeStub {
  submit: ReturnType<typeof person>["stub"]["submit"]
  readOp: ReturnType<typeof person>["stub"]["readOp"]
  fakeControl(cmd: { advance_ms?: number; edge_host?: string | null }): Promise<{ tls: Array<EdgeRule>; now: number }>
}
const edgeStub = (x: ReturnType<typeof person>) => x.stub as unknown as EdgeStub

const verify = async (token: string, now?: number) =>
  (
    await jwtVerify(token, createLocalJWKSet(publicJwks(E) as { keys: Array<JWK> }), {
      algorithms: ["ES256"],
      issuer: "https://cmux-api/test",
      audience: "coderouter",
      ...(now ? { currentDate: new Date(now) } : {})
    })
  ).payload
const bearer = (r: EdgeRule) => {
  const v = r.rule.transform[0]?.headers[CODEROUTER_EDGE_HEADER] ?? ""
  expect(v).toMatch(/^Bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/)
  return v.slice("Bearer ".length)
}

describe("the machine's coderouter token", () => {
  it("is a 1-hour ES256 token for coderouter bound to the machine and its owner's Stack user", async () => {
    const now = Date.now()
    const token = await mintCoderouterMachineToken(E, { machine: "vm_0123456789abcdefghij", owner: "stack-owner-1", now })
    expect(decodeProtectedHeader(token)).toMatchObject({ alg: "ES256", typ: "cmux-machine+jwt" })
    const c = await verify(token)
    expect(c).toMatchObject({ sub: "vm:vm_0123456789abcdefghij", team_id: "stack-owner-1", owner_id: "stack-owner-1", role: "dev" })
    expect(typeof c.jti).toBe("string")
    expect(c.exp! - c.iat!).toBe(CODEROUTER_TOKEN_TTL_S)
    expect(CODEROUTER_TOKEN_TTL_S).toBeLessThanOrEqual(3600)
  })

})

describe("create sends the inline edge rule", { timeout: 60_000 }, () => {

})

describe("the rule's token is refreshed", { timeout: 60_000 }, () => {
})
