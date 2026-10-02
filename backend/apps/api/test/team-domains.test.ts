import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import type { ReduceContext } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { teamDomain, type TeamState } from "../src/domains/team.ts"
import { txtContains } from "../src/domains/team-domains.ts"

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; TEAM_DO: DurableObjectNamespace; DOMAIN_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default

const OWNER = "user_00000000000000000001"
const MEMBER = "user_00000000000000000002"
const TEAM = "team_00000000000000000001"
const base = (): TeamState => ({
  team: { id: TEAM, kind: "personal", display_name: "Acme" },
  members: { [OWNER]: { user: OWNER, role: "owner", display_name: "o" }, [MEMBER]: { user: MEMBER, role: "member", display_name: "m" } },
  hosts: {}
})
let txn = 0
const ctx = (user = OWNER, extra: Partial<ReduceContext["principal"]> = {}): ReduceContext => ({
  principal: { identity: `user:${user}`, user, team: TEAM, kind: "session", ...extra },
  now: 1_000_000 + txn,
  tx: `tx${++txn}`,
  newId: (p) => `${p}_${String(txn).padStart(20, "0")}`
})

describe("domain claims (TeamDO reducer)", () => {
  it("claims return one TXT record while pending, refuse public mail domains, members and agents", () => {
    const r = teamDomain.reduce(base(), "domain.claim", { domain: "acme.com" }, ctx())
    if (!r.ok) throw new Error(r.message)
    expect(r.value).toMatchObject({ domain: "acme.com", state: "pending", record_name: "_cmux-challenge.acme.com" })
    expect((r.value as { record_value: string }).record_value).toMatch(/^cmux-verification=dvt_[0-9a-f]{20}$/)
    expect(r.outbox?.map((o) => o.kind)).toEqual(["audit.append"])
    const again = teamDomain.reduce(r.state as TeamState, "domain.claim", { domain: "acme.com" }, ctx())
    expect(again).toMatchObject({ ok: true, changed: false })
    expect(teamDomain.reduce(base(), "domain.claim", { domain: "gmail.com" }, ctx())).toMatchObject({ ok: false, code: "policy.invalid" })
    expect(teamDomain.reduce(base(), "domain.claim", { domain: "Acme.COM" }, ctx())).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(teamDomain.reduce(base(), "domain.claim", { domain: "acme.com" }, ctx(MEMBER))).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(teamDomain.reduce(base(), "domain.claim", { domain: "acme.com" }, ctx(OWNER, { agent: "agent_x" }))).toMatchObject({ ok: false, code: "auth.forbidden" })
  })

  it("matches TXT answers as DoH returns them (quoted, split strings)", () => {
    expect(txtContains(['"cmux-verification=dvt_1"'], "cmux-verification=dvt_1")).toBe(true)
    expect(txtContains(['"cmux-verification=" "dvt_1"'], "cmux-verification=dvt_1")).toBe(true)
    expect(txtContains(['"cmux-verification=dvt_2"', '"v=spf1 -all"'], "cmux-verification=dvt_1")).toBe(false)
  })
})

const sessionToken = async (stackUser: string) => {
  const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email: `${stackUser}@acme.com`, email_verified: true, name: stackUser })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key)
}
const op = async (token: string, name: string, params: unknown) => {
  const res = await worker.fetch("https://api.test/v1/ops", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ op: name, params, idempotency_key: crypto.randomUUID(), origin: "user" })
  })
  return (await res.json()) as any
}
const inDO: (stub: DurableObjectStub, fn: (instance: any, state: any) => Promise<void>) => Promise<void> = runInDurableObject as any

/** Fakes both DoH resolvers; `records` maps a name to its TXT strings per resolver. */
const fakeDns = (records: (resolver: "cloudflare" | "google", name: string) => Array<string>) => async (req: Request) => {
  const url = new URL(req.url)
  const resolver = url.hostname === "dns.google" ? "google" : "cloudflare"
  const name = url.searchParams.get("name")!
  return new Response(JSON.stringify({ Status: 0, Answer: records(resolver, name).map((data) => ({ type: 16, data: `"${data}"` })) }), { headers: { "content-type": "application/dns-json" } })
}

describe("domain verification over the API (workerd)", () => {
  it("verifies only when both resolvers see the record, gives the domain to one team, and releases it", async () => {
    const a = await sessionToken("stack-domain-a")
    const b = await sessionToken("stack-domain-b")
    await op(a, "user.ensure", {})
    await op(b, "user.ensure", {})
    const claimA = await op(a, "domain.claim", { domain: "example-acme.dev" })
    expect(claimA.ok).toBe(true)
    const valueA = claimA.value.record_value as string
    const teamA = claimA.stream.replace("team:", "")
    const teamB = (await op(b, "domain.claim", { domain: "example-acme.dev" })).stream.replace("team:", "")
    const setDns = async (team: string, fn: Parameters<typeof fakeDns>[0]) =>
      inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)) as unknown as DurableObjectStub, async (instance) => {
        instance.http = fakeDns(fn)
      })

    // Only one resolver sees it: not verified (retryable).
    await setDns(teamA, (r) => (r === "cloudflare" ? [valueA] : []))
    const partial = await op(a, "domain.verify", { domain: "example-acme.dev" })
    expect(partial).toMatchObject({ ok: false, error: { code: "domain.not_verified", retryable: true } })

    await setDns(teamA, () => [valueA, "v=spf1 -all"])
    const verified = await op(a, "domain.verify", { domain: "example-acme.dev" })
    expect(verified).toMatchObject({ ok: true, value: { state: "verified" } })

    // Team B publishes its own record too, but the domain already belongs to team A.
    const valueB = (await op(b, "domain.claim", { domain: "example-acme.dev" })).value.record_value as string
    await setDns(teamB, () => [valueA, valueB])
    expect(await op(b, "domain.verify", { domain: "example-acme.dev" })).toMatchObject({ ok: false, error: { code: "domain.taken" } })

    // After A releases, B can verify.
    expect((await op(a, "domain.release", { domain: "example-acme.dev" })).ok).toBe(true)
    expect(await op(b, "domain.verify", { domain: "example-acme.dev" })).toMatchObject({ ok: true, value: { state: "verified" } })
    const owner = await inDO(testEnv.DOMAIN_DO.get(testEnv.DOMAIN_DO.idFromName("example-acme.dev")) as unknown as DurableObjectStub, async (instance) => {
      expect(await instance.owner()).toBe(teamB)
    })
    void owner
  })
})
