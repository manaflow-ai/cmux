import { env, exports } from "cloudflare:workers"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { cloudOps } from "@cmux/protocol"
import { importJWK, SignJWT, type JWK } from "jose"
import { afterEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.ts"
import type { Env } from "../src/env.ts"
import { OWNER_SURFACE, platformSurfaces } from "../src/platform-forward.ts"

/**
 * The platform forwarder (platform-forward.ts; cmux-platform docs/port-cloud-worker.md 3.1, row 1d).
 * Off (no PLATFORM_SURFACES, or an empty one) every request runs the existing handler. On, NEXT
 * Cloud's machine routes and the CloudDO ops on /v1/ops and /v1/read go to the PLATFORM binding
 * with the body intact; every other op, a body that does not parse and an unknown op stay here.
 * A listed surface without the binding stays here too. The entry ticket spend runs first, once.
 */
const testEnv = env as unknown as Env & { STACK_TEST_PRIVATE_JWK: string }
const self = (exports as unknown as { default: Fetcher }).default
const ORIGIN = "https://api.test"
const VM = "vm_abcdefghij0123456789"

const cloudMutation = cloudOps.find((o) => o.owner === "cloud:CloudDO" && o.class === "mutation")!.name
const cloudRead = cloudOps.find((o) => o.owner === "cloud:CloudDO" && o.class === "read")!.name
const stayingMutation = "user.ensure"

type Seen = { url: string; method: string; body: string; protocols: string | null }

/** A stand-in for the platform Worker: records what reached it and answers 299. */
const fakePlatform = (opts: { throws?: boolean } = {}) => {
  const seen: Seen[] = []
  const fetcher = {
    fetch: vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      if (opts.throws) throw new Error("platform down")
      const r = new Request(input as RequestInfo, init)
      seen.push({ url: r.url, method: r.method, body: await r.text(), protocols: r.headers.get("Sec-WebSocket-Protocol") })
      return new Response("from platform", { status: 299, headers: { "x-from": "platform" } })
    })
  }
  return { fetcher: fetcher as unknown as Fetcher, seen, calls: () => fetcher.fetch.mock.calls.length }
}

const call = async (request: Request, extra: Partial<Env> & Record<string, unknown>) => {
  const ctx = createExecutionContext()
  const res = await worker.fetch!(request as any, { ...testEnv, ...extra } as any, ctx)
  await waitOnExecutionContext(ctx)
  return { status: res.status, from: res.headers.get("x-from"), text: await res.text() }
}

const post = (path: string, body: string, headers: Record<string, string> = {}) => new Request(`${ORIGIN}${path}`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body })
const op = (name: string, params: unknown = {}) => JSON.stringify({ op: name, params, idempotency_key: crypto.randomUUID() })
const read = (name: string, params: unknown = {}) => JSON.stringify({ op: name, params })

/** Each request as a fresh Request (a body is read once). */
const requests: ReadonlyArray<readonly [string, () => Request]> = [
  ["cloud bind", () => post("/v1/cloud/bind", "{}")],
  ["cloud keyset", () => new Request(`${ORIGIN}/v1/cloud/keyset`)],
  ["cloud acpmux", () => post(`/v1/cloud/machines/${VM}/acpmux/keyed-start`, "{}")],
  ["cloud client-session", () => post(`/v1/cloud/machines/${VM}/client-session`, "{}")],
  ["cloud guest exec", () => post(`/v1/cloud/machines/${VM}/exec`, "{}")],
  ["CloudDO mutation", () => post("/v1/ops", op(cloudMutation))],
  ["CloudDO read", () => post("/v1/read", read(cloudRead))],
  ["staying op", () => post("/v1/ops", op(stayingMutation))],
  ["health", () => new Request(`${ORIGIN}/v1/health`)]
]

afterEach(() => vi.restoreAllMocks())

describe("PLATFORM_SURFACES", () => {
  it("parses only known surface names", () => {
    expect([...platformSurfaces(undefined)]).toEqual([])
    expect([...platformSurfaces("")]).toEqual([])
    expect([...platformSurfaces(" , ")]).toEqual([])
    expect([...platformSurfaces("auth, cloud ,wire")]).toEqual(["cloud"])
    expect(OWNER_SURFACE["cloud:CloudDO"]).toBe("cloud")
    expect(OWNER_SURFACE["cloud:UserDO"]).toBeUndefined()
  })

  for (const [label, surfaces] of [["unset", undefined], ["empty", ""], ["unknown only", "auth"]] as const) {
    it(`${label}: every request runs the existing handler, binding or not`, async () => {
      for (const [name, make] of requests) {
        const platform = fakePlatform()
        const without = await call(make(), {})
        const withBinding = await call(make(), { PLATFORM: platform.fetcher, ...(surfaces === undefined ? {} : { PLATFORM_SURFACES: surfaces }) })
        expect(platform.calls(), name).toBe(0)
        expect(withBinding.status, name).toBe(without.status)
        expect(withBinding.from, name).toBeNull()
      }
    })
  }
})

describe("cloud surface on", () => {
  it("forwards NEXT Cloud's machine routes and CloudDO ops with the body intact", async () => {
    for (const [name, make] of requests.slice(0, 7)) {
      const platform = fakePlatform()
      const original = make()
      const body = await original.clone().text()
      const res = await call(original, { PLATFORM: platform.fetcher, PLATFORM_SURFACES: "cloud" })
      expect(res.status, name).toBe(299)
      expect(res.text, name).toBe("from platform")
      expect(platform.seen, name).toHaveLength(1)
      expect(platform.seen[0]!.url, name).toBe(original.url)
      expect(platform.seen[0]!.method, name).toBe(original.method)
      expect(platform.seen[0]!.body, name).toBe(body)
    }
  })

  it("keeps an op of an owner that stays, a malformed body, an unknown op and an op on the wrong endpoint here", async () => {
    const local = [
      ["staying op", () => post("/v1/ops", op(stayingMutation))],
      ["staying read", () => post("/v1/read", read("user.teams.list"))],
      ["malformed body", () => post("/v1/ops", "{not json")],
      ["body not an object", () => post("/v1/ops", "null")],
      ["op not a string", () => post("/v1/ops", JSON.stringify({ op: 7, params: {} }))],
      ["unknown op", () => post("/v1/ops", op("cloud.machine.nope"))],
      ["CloudDO read on /v1/ops", () => post("/v1/ops", op(cloudRead))],
      ["CloudDO mutation on /v1/read", () => post("/v1/read", read(cloudMutation))],
      ["GET /v1/ops", () => new Request(`${ORIGIN}/v1/ops`)],
      ["health", () => new Request(`${ORIGIN}/v1/health`)],
      ["cloud wire socket (the wire surface, not cloud)", () => new Request(`${ORIGIN}/v1/wire/cloud`)]
    ] as const
    for (const [name, make] of local) {
      const platform = fakePlatform()
      const off = await call(make(), {})
      const on = await call(make(), { PLATFORM: platform.fetcher, PLATFORM_SURFACES: "cloud" })
      expect(platform.calls(), name).toBe(0)
      expect(on.status, name).toBe(off.status)
      expect(on.from, name).toBeNull()
      expect(on.text.replace(/"(transaction|idempotency_key)":"[^"]*"/g, ""), name).toBe(off.text.replace(/"(transaction|idempotency_key)":"[^"]*"/g, ""))
    }
  })

  it("stays here and logs when the PLATFORM binding is absent", async () => {
    const log = vi.spyOn(console, "error")
    for (const [name, make] of requests.slice(0, 7)) {
      const off = await call(make(), {})
      const on = await call(make(), { PLATFORM_SURFACES: "cloud" })
      expect(on.status, name).toBe(off.status)
      expect(on.from, name).toBeNull()
    }
    expect(log.mock.calls.some(([line]) => String(line).includes("platform.forward.unbound"))).toBe(true)
  })

  it("answers a retryable owner.unreachable when the platform cannot be reached, without serving locally", async () => {
    const platform = fakePlatform({ throws: true })
    const res = await call(post("/v1/ops", op(cloudMutation)), { PLATFORM: platform.fetcher, PLATFORM_SURFACES: "cloud" })
    expect(res.status).toBe(503)
    expect(JSON.parse(res.text)).toMatchObject({ error: { code: "owner.unreachable", retryable: true } })
  })
})

describe("entry ticket spend", () => {
  const stackToken = async (sub: string) =>
    new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
      .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
      .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
      .setAudience(testEnv.STACK_PROJECT_ID)
      .setSubject(sub)
      .setIssuedAt()
      .setExpirationTime("10m")
      .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))

  /** WIRE_TICKET_DO with a count of the objects reached (one per spend). */
  const countingTickets = () => {
    const real = testEnv.WIRE_TICKET_DO
    let spends = 0
    const ns = { idFromName: (n: string) => real.idFromName(n), get: (id: DurableObjectId) => (spends++, real.get(id)) }
    return { ns: ns as unknown as Env["WIRE_TICKET_DO"], spends: () => spends }
  }

  it("a forwarded request's ticket is spent exactly once, by cmux-api, before it is forwarded", async () => {
    const token = await stackToken(`pf-${crypto.randomUUID().slice(0, 8)}`)
    expect((await self.fetch(`${ORIGIN}/v1/ops`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: op("user.ensure") })).status).toBe(200)
    const minted = await self.fetch(`${ORIGIN}/v1/wire/ticket`, { method: "POST", headers: { authorization: `Bearer ${token}` } })
    const { ticket } = (await minted.json()) as { ticket: string }
    expect(ticket).toBeTruthy()
    const platform = fakePlatform()
    const tickets = countingTickets()
    const res = await call(new Request(`${ORIGIN}/v1/cloud/keyset`, { headers: { "Sec-WebSocket-Protocol": `cmux.wire.v1, ticket.${ticket}` } }), { PLATFORM: platform.fetcher, PLATFORM_SURFACES: "cloud", WIRE_TICKET_DO: tickets.ns })
    expect(res.status).toBe(299)
    expect(tickets.spends()).toBe(1)
    expect(platform.seen[0]!.protocols).toContain(`ticket.${ticket}`)
    // Already spent: the socket it was minted for refuses it.
    const replay = await self.fetch(`${ORIGIN}/v1/wire/user`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, ticket.${ticket}` } })
    expect(replay.status).toBe(401)
    expect(replay.webSocket).toBeNull()
    await replay.arrayBuffer()
  })

  it("a request that stays here spends its ticket once too", async () => {
    const tickets = countingTickets()
    const ticket = "a".repeat(43)
    await call(new Request(`${ORIGIN}/v1/health`, { headers: { "Sec-WebSocket-Protocol": `ticket.${ticket}` } }), { PLATFORM: fakePlatform().fetcher, PLATFORM_SURFACES: "cloud", WIRE_TICKET_DO: tickets.ns })
    expect(tickets.spends()).toBe(1)
  })
})
