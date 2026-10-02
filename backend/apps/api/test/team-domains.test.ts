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
  return new Response(JSON.stringify({ Status: 0, Answer: records(resolver, name).map((data) => ({ name: `${name}.`, type: 16, data: `"${data}"` })) }), { headers: { "content-type": "application/dns-json" } })
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

  it("a release during a verify leaves no orphaned DomainDO owner; verify re-checks DomainDO (review P1)", async () => {
    const a = await sessionToken("stack-domain-race")
    await op(a, "user.ensure", {})
    const claim = await op(a, "domain.claim", { domain: "race-acme.dev" })
    const team = claim.stream.replace("team:", "")
    const value = claim.value.record_value as string
    const teamStub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)) as unknown as DurableObjectStub
    let released = false
    await inDO(teamStub, async (instance) => {
      // While verify waits on DNS, the admin releases the claim.
      instance.http = async (req: Request) => {
        if (!released) {
          released = true
          expect((await op(a, "domain.release", { domain: "race-acme.dev" })).ok).toBe(true)
        }
        return fakeDns(() => [value])(req)
      }
    })
    const verify = await op(a, "domain.verify", { domain: "race-acme.dev" })
    expect(verify.ok).toBe(false)
    // DomainDO must not keep an owner that TeamDO no longer knows.
    await inDO(testEnv.DOMAIN_DO.get(testEnv.DOMAIN_DO.idFromName("race-acme.dev")) as unknown as DurableObjectStub, async (instance) => {
      expect(await instance.owner()).toBe(null)
    })
  })

  it("ignores TXT answers reached through a CNAME and verifies only the exact record name (review P2)", async () => {
    const a = await sessionToken("stack-domain-cname")
    await op(a, "user.ensure", {})
    const claim = await op(a, "domain.claim", { domain: "cname-acme.dev" })
    const team = claim.stream.replace("team:", "")
    const value = claim.value.record_value as string
    await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)) as unknown as DurableObjectStub, async (instance) => {
      instance.http = async () =>
        new Response(JSON.stringify({ Status: 0, Answer: [
          { name: "_cmux-challenge.cname-acme.dev.", type: 5, data: "attacker.example." },
          { name: "attacker.example.", type: 16, data: `"${value}"` }
        ] }))
    })
    expect(await op(a, "domain.verify", { domain: "cname-acme.dev" })).toMatchObject({ ok: false, error: { code: "domain.not_verified" } })
  })
})

describe("Public Suffix List and public mail (review P2)", () => {
  it("refuses public suffixes and regional public mail domains, allows registrable domains and names below them", async () => {
    const { unclaimableReason } = await import("../src/domains/team-domains.ts")
    const { registrableDomain } = await import("../src/domains/public-suffix.ts")
    for (const d of ["co.uk", "github.io", "com", "pages.dev", "yahoo.co.uk", "outlook.de", "gmx.at", "gmail.com"]) expect(unclaimableReason(d), d).toBeDefined()
    for (const d of ["acme.co.uk", "acme.com", "eng.acme.com", "alice.github.io", "mail.acme.dev"]) expect(unclaimableReason(d), d).toBeUndefined()
    expect(registrableDomain("eng.acme.co.uk")).toBe("acme.co.uk")
    expect(registrableDomain("co.uk")).toBeUndefined()
  })
})

describe("weekly domain re-check (spec 3.4)", () => {
  it("three failed weekly re-checks mark a verified domain lapsed; one success resets the count", () => {
    let s: TeamState = { ...base(), domains: { "acme.com": { domain: "acme.com", state: "verified", record_name: "_cmux-challenge.acme.com", record_value: "v1", requested_at: 0, expires_at: 9e15, verified_at: 0 } } }
    const sys = (): ReduceContext => ({ principal: { identity: "system:team", kind: "system" }, now: 1, tx: `tx${++txn}`, newId: (p) => `${p}_${String(txn).padStart(20, "0")}` })
    const step = (ok: boolean, at: number) => {
      const r = teamDomain.reduce(s, "domain.rechecked", { domain: "acme.com", record_value: "v1", ok, at }, sys())
      if (!r.ok) throw new Error(r.message)
      s = r.state as TeamState
      return r
    }
    step(false, 1)
    step(true, 2)
    expect(s.domains?.["acme.com"]?.check_failures).toBe(0)
    step(false, 3)
    step(false, 4)
    const last = step(false, 5)
    expect(s.domains?.["acme.com"]?.state).toBe("lapsed")
    expect(last.outbox?.map((o) => o.kind)).toEqual(["audit.append"])
    // A stale result for an older record value changes nothing.
    expect(teamDomain.reduce(s, "domain.rechecked", { domain: "acme.com", record_value: "old", ok: true, at: 6 }, sys())).toMatchObject({ ok: true, changed: false })
  })

  it("over workerd: three failing re-checks lapse the domain, free it in DomainDO, and verifying again restores it", async () => {
    const a = await sessionToken("stack-domain-lapse")
    await op(a, "user.ensure", {})
    const claim = await op(a, "domain.claim", { domain: "lapse-acme.dev" })
    const team = claim.stream.replace("team:", "")
    const value = claim.value.record_value as string
    const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)) as unknown as DurableObjectStub
    let published = true
    await inDO(stub, async (instance) => {
      instance.http = fakeDns(() => (published ? [value] : []))
    })
    expect((await op(a, "domain.verify", { domain: "lapse-acme.dev" })).ok).toBe(true)
    published = false
    await inDO(stub, async (instance) => {
      const week = 7 * 86_400_000
      for (let i = 1; i <= 3; i++) await instance.recheckDomains(Date.now() + i * week + 1000)
    })
    const domains = (await (await worker.fetch("https://api.test/v1/read", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${a}` },
      body: JSON.stringify({ op: "domain.list", params: {} })
    })).json()) as any
    expect(domains.value.domains[0]).toMatchObject({ domain: "lapse-acme.dev", state: "lapsed", check_failures: 3 })
    await inDO(testEnv.DOMAIN_DO.get(testEnv.DOMAIN_DO.idFromName("lapse-acme.dev")) as unknown as DurableObjectStub, async (instance) => {
      expect(await instance.owner()).toBe(null)
    })
    published = true
    const again = await op(a, "domain.verify", { domain: "lapse-acme.dev" })
    expect(again).toMatchObject({ ok: true, value: { state: "verified", check_failures: 0 } })
  })
})
