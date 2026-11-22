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

describe("coderouter edge configuration", () => {
  it("is on only in development and test, with a bare host name", () => {
    expect(coderouterEdgeConfig({ ENVIRONMENT: "development", CLOUD_CODEROUTER_EDGE_HOST: HOST })).toEqual({ host: HOST })
    expect(coderouterEdgeConfig({ ENVIRONMENT: "test", CLOUD_CODEROUTER_EDGE_HOST: ` ${HOST.toUpperCase()} ` })).toEqual({ host: HOST })
    expect(coderouterEdgeConfig({ ENVIRONMENT: "staging", CLOUD_CODEROUTER_EDGE_HOST: HOST })).toBeNull()
    expect(coderouterEdgeConfig({ ENVIRONMENT: "production", CLOUD_CODEROUTER_EDGE_HOST: HOST })).toBeNull()
    expect(coderouterEdgeConfig({ ENVIRONMENT: "development" })).toBeNull()
    for (const bad of [`https://${HOST}`, `${HOST}:443`, `${HOST}/v1`, "localhost", "a b.example"]) expect(coderouterEdgeConfig({ ENVIRONMENT: "development", CLOUD_CODEROUTER_EDGE_HOST: bad })).toBeNull()
  })
})

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

  it("never authenticates on the backend itself (aud api only)", async () => {
    const token = await mintCoderouterMachineToken(E, { machine: "vm_0123456789abcdefghij", owner: "stack-owner-1", now: Date.now() })
    expect(await authenticate(E, token)).toBeUndefined()
  })
})

describe("create sends the inline edge rule", { timeout: 60_000 }, () => {
  it("a development create carries one rule for coderouter.cmux.internal with the machine's token", async () => {
    const x = person()
    await ensureUser(x)
    await edgeStub(x).fakeControl({ edge_host: HOST })
    const created = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE })))
    expect(created.t).toBe("result")
    const machine = created.value.machine.id as string
    const { tls } = await edgeStub(x).fakeControl({})
    expect(tls).toHaveLength(1)
    const r = tls[0]!
    expect(r.rule).toMatchObject({ action: "allow", domain: CODEROUTER_EDGE_DOMAIN, source: {}, destination: { host: HOST, port: 443 } })
    expect(Object.keys(r.rule.transform[0]!.headers)).toEqual([CODEROUTER_EDGE_HEADER])
    const c = await verify(bearer(r))
    expect(c).toMatchObject({ sub: `vm:${machine}`, owner_id: `stack_${x.user}`, team_id: `stack_${x.user}` })
  })

  it("sends no rule without the edge host", async () => {
    const x = person()
    await ensureUser(x)
    await edgeStub(x).fakeControl({ edge_host: null })
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE }))).t).toBe("result")
    expect((await edgeStub(x).fakeControl({})).tls).toEqual([])
  })

  it("creates the machine without a rule when the owner has no Stack user on record", async () => {
    const x = person()
    await edgeStub(x).fakeControl({ edge_host: HOST })
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE }))).t).toBe("result")
    expect((await edgeStub(x).fakeControl({})).tls).toEqual([])
  })
})

describe("the rule's token is refreshed", { timeout: 60_000 }, () => {
  it("replaces the token after 30 minutes on a running machine, and after a start; never while paused", async () => {
    const x = person()
    await ensureUser(x)
    await edgeStub(x).fakeControl({ edge_host: HOST })
    const { machine } = await createdAndBound(x)
    const first = bearer((await edgeStub(x).fakeControl({})).tls[0]!)

    // Before 30 minutes: nothing changes.
    await edgeStub(x).fakeControl({ advance_ms: 10 * 60_000 })
    await fireAlarm(x.stub)
    expect(bearer((await edgeStub(x).fakeControl({})).tls[0]!)).toBe(first)

    // After 30 minutes: a new token for the same machine, still one rule.
    const at = (await edgeStub(x).fakeControl({ advance_ms: 25 * 60_000 })).now
    await fireAlarm(x.stub)
    const after = await edgeStub(x).fakeControl({})
    expect(after.tls).toHaveLength(1)
    const second = bearer(after.tls[0]!)
    expect(second).not.toBe(first)
    const c = await verify(second, at)
    expect(c.sub).toBe(`vm:${machine}`)
    expect((c.iat ?? 0) * 1000).toBeGreaterThanOrEqual(at - 5_000)

    // Paused: no refresh however long it waits.
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.pause", { machine }))).t).toBe("result")
    await edgeStub(x).fakeControl({ advance_ms: 3 * 3600_000 })
    await fireAlarm(x.stub)
    expect(bearer((await edgeStub(x).fakeControl({})).tls[0]!)).toBe(second)

    // A start refreshes at once.
    expect(reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.start", { machine }))).t).toBe("result")
    expect(bearer((await edgeStub(x).fakeControl({})).tls[0]!)).not.toBe(second)
  })
})
