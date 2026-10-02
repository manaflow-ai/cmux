import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import type { ReduceContext } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { teamDomain, type TeamState } from "../src/domains/team.ts"

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; TEAM_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const inDO: (stub: DurableObjectStub, fn: (instance: any, state: any) => Promise<void>) => Promise<void> = runInDurableObject as any

const OWNER = "user_00000000000000000001"
const MEMBER = "user_00000000000000000002"
const TEAM = "team_00000000000000000001"
let txn = 0
const ctx = (user = OWNER, extra: Partial<ReduceContext["principal"]> = {}): ReduceContext => ({
  principal: { identity: `user:${user}`, user, team: TEAM, kind: "session", ...extra },
  now: 1_000_000 + txn,
  tx: `tx${++txn}`,
  newId: (p) => `${p}_${String(txn).padStart(20, "0")}`
})
const withDomain = (): TeamState => ({
  team: { id: TEAM, kind: "personal", display_name: "Acme" },
  members: { [OWNER]: { user: OWNER, role: "owner", display_name: "o" }, [MEMBER]: { user: MEMBER, role: "member", display_name: "m" } },
  hosts: {},
  domains: { "acme.dev": { domain: "acme.dev", state: "pending", record_name: "_cmux-challenge.acme.dev", record_value: "v", requested_at: 1, expires_at: 9e15, verified_at: null } }
})

describe("SSO connections (TeamDO reducer)", () => {
  it("creates drafts for claimed domains only; members, agents and the wire path to secret ops are refused", () => {
    const params = { issuer: "https://idp.acme.dev/", client_id: "cmux", domains: ["acme.dev"] }
    const r = teamDomain.reduce(withDomain(), "sso.connection.create", params, ctx())
    if (!r.ok) throw new Error(r.message)
    expect(r.value).toMatchObject({ kind: "oidc", state: "draft", secret_set: false, oidc: { issuer: "https://idp.acme.dev/", scopes: ["openid", "email", "profile"] } })
    expect(teamDomain.reduce(withDomain(), "sso.connection.create", { ...params, domains: ["other.dev"] }, ctx())).toMatchObject({ ok: false, code: "policy.invalid" })
    expect(teamDomain.reduce(withDomain(), "sso.connection.create", { ...params, issuer: "http://idp.acme.dev" }, ctx())).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(teamDomain.reduce(withDomain(), "sso.connection.create", params, ctx(MEMBER))).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(teamDomain.reduce(withDomain(), "sso.connection.create", params, ctx(OWNER, { agent: "agent_x" }))).toMatchObject({ ok: false, code: "auth.forbidden" })
    // HTTP-only ops are refused in authorize (not recorded in the ledger, so no secret hash is stored).
    expect(teamDomain.authorize!(withDomain(), "sso.connection.set_secret", { connection: "ssoc_00000000000000000001", client_secret: "s" }, ctx().principal)).toMatchObject({ code: "validation.invalid" })
    // An issuer with a trailing slash is kept exactly (OpenID Discovery compares it exactly).
    const slash = teamDomain.reduce(withDomain(), "sso.connection.create", { ...params, issuer: "https://tenant.auth0.example/" }, ctx())
    expect(slash.ok && (slash.value as { oidc: { issuer: string } }).oidc.issuer).toBe("https://tenant.auth0.example/")
    expect(teamDomain.reduce(withDomain(), "sso.connection.create", { ...params, issuer: "https://user@idp.acme.dev/?x=1" }, ctx())).toMatchObject({ ok: false, code: "policy.invalid" })
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
const discover = async (email: string) => (await (await worker.fetch(`https://api.test/v1/sso/discover?email=${encodeURIComponent(email)}`)).json()) as any

describe("SSO connections over the API (workerd)", () => {
  it("draft, sealed secret, discovery-checked activation; sign-in discovery says yes only then and never leaks the secret", async () => {
    const a = await sessionToken("stack-sso-admin")
    await op(a, "user.ensure", {})
    const domain = "sso-acme.dev"
    const claim = await op(a, "domain.claim", { domain })
    const team = claim.stream.replace("team:", "")
    const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)) as unknown as DurableObjectStub
    let discoveryDoc: Record<string, unknown> = {}
    await inDO(stub, async (instance) => {
      instance.http = async (req: Request) => {
        const url = new URL(req.url)
        if (url.pathname === "/.well-known/openid-configuration") return new Response(JSON.stringify(discoveryDoc))
        const name = url.searchParams.get("name")!
        return new Response(JSON.stringify({ Status: 0, Answer: [{ name: `${name}.`, type: 16, data: `"${claim.value.record_value}"` }] }))
      }
    })
    expect((await op(a, "domain.verify", { domain })).ok).toBe(true)

    const created = await op(a, "sso.connection.create", { issuer: "https://idp.sso-acme.dev", client_id: "cmux-client", domains: [domain] })
    expect(created.ok).toBe(true)
    const id = created.value.id as string
    expect(await discover(`alice@${domain}`)).toEqual({ sso: false })
    // Activation needs the secret first.
    discoveryDoc = { issuer: "https://idp.sso-acme.dev", authorization_endpoint: "https://idp.sso-acme.dev/authorize", token_endpoint: "https://idp.sso-acme.dev/token", jwks_uri: "https://idp.sso-acme.dev/jwks" }
    expect(await op(a, "sso.connection.activate", { connection: id })).toMatchObject({ ok: false, error: { code: "policy.invalid" } })

    const secret = "super-secret-client-value-42"
    expect(await op(a, "sso.connection.set_secret", { connection: id, client_secret: secret })).toMatchObject({ ok: true, value: { secret_set: true } })
    // A discovery document for another issuer is refused (OpenID Discovery 4.3).
    discoveryDoc = { ...discoveryDoc, issuer: "https://evil.example" }
    expect(await op(a, "sso.connection.activate", { connection: id })).toMatchObject({ ok: false, error: { code: "sso.discovery_failed" } })
    discoveryDoc = { ...discoveryDoc, issuer: "https://idp.sso-acme.dev" }
    expect(await op(a, "sso.connection.activate", { connection: id })).toMatchObject({ ok: true, value: { state: "active", oidc: { token_endpoint: "https://idp.sso-acme.dev/token" } } })

    expect(await discover(`Alice@${domain.toUpperCase()}`)).toEqual({ sso: true })
    expect(await discover(`bob@sub.${domain}`)).toEqual({ sso: false })
    expect(await discover("carol@unknown-team.dev")).toEqual({ sso: false })

    await inDO(stub, async (_instance, state) => {
      const everything = JSON.stringify([
        state.storage.sql.exec("SELECT * FROM own_events").toArray(),
        state.storage.sql.exec("SELECT * FROM own_ledger").toArray(),
        state.storage.sql.exec("SELECT * FROM own_state").toArray(),
        state.storage.sql.exec("SELECT * FROM own_outbox").toArray()
      ])
      expect(everything).not.toContain(secret)
      const sealed = state.storage.sql.exec("SELECT sealed FROM sso_secrets").toArray()
      expect(sealed.length).toBe(1)
      expect(String(sealed[0].sealed)).not.toContain(secret)
    })

    expect((await op(a, "sso.connection.disable", { connection: id })).ok).toBe(true)
    expect(await discover(`alice@${domain}`)).toEqual({ sso: false })
  })

  it("activation works after its precondition is fixed; a disable during discovery is not undone (review P1, P2)", async () => {
    const a = await sessionToken("stack-sso-retry")
    await op(a, "user.ensure", {})
    const domain = "retry-acme.dev"
    const claim = await op(a, "domain.claim", { domain })
    const team = claim.stream.replace("team:", "")
    const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)) as unknown as DurableObjectStub
    let onDiscovery: () => Promise<void> = async () => {}
    const doc = { issuer: "https://idp.retry-acme.dev", authorization_endpoint: "https://idp.retry-acme.dev/a", token_endpoint: "https://idp.retry-acme.dev/t", jwks_uri: "https://idp.retry-acme.dev/k" }
    await inDO(stub, async (instance) => {
      instance.http = async (req: Request) => {
        const url = new URL(req.url)
        if (url.pathname === "/.well-known/openid-configuration") {
          await onDiscovery()
          return new Response(JSON.stringify(doc))
        }
        const name = url.searchParams.get("name")!
        return new Response(JSON.stringify({ Status: 0, Answer: [{ name: `${name}.`, type: 16, data: `"${claim.value.record_value}"` }] }))
      }
    })
    const id = (await op(a, "sso.connection.create", { issuer: doc.issuer, client_id: "c", domains: [domain] })).value.id as string
    expect((await op(a, "sso.connection.set_secret", { connection: id, client_secret: "s3cret" })).ok).toBe(true)
    // Domain not verified yet: refused; after verifying, the same activation succeeds.
    expect(await op(a, "sso.connection.activate", { connection: id })).toMatchObject({ ok: false, error: { code: "policy.invalid" } })
    expect((await op(a, "domain.verify", { domain })).ok).toBe(true)
    expect(await op(a, "sso.connection.activate", { connection: id })).toMatchObject({ ok: true, value: { state: "active" } })
    // A disable that lands while an activation fetches discovery is not undone.
    expect((await op(a, "sso.connection.disable", { connection: id })).ok).toBe(true)
    const id2 = (await op(a, "sso.connection.create", { issuer: doc.issuer, client_id: "c2", domains: [domain] })).value.id as string
    expect((await op(a, "sso.connection.set_secret", { connection: id2, client_secret: "s3cret2" })).ok).toBe(true)
    onDiscovery = async () => {
      onDiscovery = async () => {}
      expect((await op(a, "sso.connection.disable", { connection: id2 })).ok).toBe(true)
    }
    expect((await op(a, "sso.connection.activate", { connection: id2 })).ok).toBe(false)
    const list = (await (await worker.fetch("https://api.test/v1/read", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${a}` }, body: JSON.stringify({ op: "sso.connection.list", params: {} }) })).json()) as any
    expect(list.value.connections.map((c: any) => c.state)).toEqual(["disabled", "disabled"])
  })
})
