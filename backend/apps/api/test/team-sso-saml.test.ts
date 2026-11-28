import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import type { SsoJoin } from "../src/team-sso-join.ts"
// @ts-expect-error a Vite raw import (the test runner bundles it; the Worker build never sees it)
import IDP_CERT from "../../../packages/saml/test/fixtures/idp-cert.pem?raw"
// @ts-expect-error a Vite raw import
import IDP_KEY from "../../../packages/saml/test/fixtures/idp-key.pem?raw"
// @ts-expect-error a Vite raw import
import OTHER_KEY from "../../../packages/saml/test/fixtures/other-key.pem?raw"

/**
 * SAML 2.0 SSO (RFD 0211): a team creates a SAML connection from its IdP's entity id, sign-on URL and
 * certificate, gives the IdP our SP metadata, and its people sign in SP-initiated: /v1/sso/start sends an
 * AuthnRequest by HTTP-Redirect, the IdP posts a signed Response to the ACS URL, and the sign-in ends
 * like OIDC (Stack session, sso.enforce record, JIT join, one-time redeem code). The test plays the IdP:
 * it signs assertions with the @cmux/saml test key (RSA-SHA256, exclusive c14n written out by hand).
 */

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; TEAM_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const inDO: (stub: DurableObjectStub, fn: (instance: any, state: any) => Promise<void>) => Promise<void> = runInDurableObject as any
const RETURN = "cmux://sso-complete"
const DS = "http://www.w3.org/2000/09/xmldsig#"
const EXC = "http://www.w3.org/2001/10/xml-exc-c14n#"
let n = 0

const sessionToken = async (stackUser: string) => {
  const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email: `${stackUser}@admin.dev`, email_verified: true, name: stackUser })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key)
}
const op = async (token: string, name: string, params: unknown) =>
  (await (await worker.fetch("https://api.test/v1/ops", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ op: name, params, idempotency_key: crypto.randomUUID(), origin: "user" }) })).json()) as any

const ip = () => ({ "cf-connecting-ip": `198.51.100.${Math.floor(Math.random() * 250)}-${crypto.randomUUID()}` })
const b64 = (bytes: Uint8Array) => {
  let s = ""
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s)
}
const b64u = (b: Uint8Array) => b64(b).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const CLIENT_VERIFIER = "client-verifier-0123456789-abcdefghijklmnopqrstuvwxyz"
const challengeOf = async (v: string) => b64u(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(v))))
const pemBytes = (pem: string) => Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0))
const rsaKey = (pem: string) => crypto.subtle.importKey("pkcs8", pemBytes(pem), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"])

interface Assertion {
  id?: string
  idp: string
  audience: string
  acs: string
  requestId: string
  nameId: string
  format?: string
  attributes?: Record<string, string>
  now?: number
}

/**
 * A Response with one assertion, signed enveloped by `key`. The assertion and SignedInfo are written in
 * their exclusive-c14n form (attributes sorted, no self-closing tags, no whitespace nodes), so the bytes
 * signed here are the bytes the validator canonicalizes.
 */
const response = async (a: Assertion, key = IDP_KEY as string) => {
  const now = a.now ?? Date.now()
  const iso = (ms: number) => new Date(ms).toISOString()
  const id = a.id ?? `_a${crypto.randomUUID().replace(/-/g, "")}`
  const attrs = Object.entries(a.attributes ?? {})
    .map(([k, v]) => `<saml:Attribute Name="${k}"><saml:AttributeValue>${v}</saml:AttributeValue></saml:Attribute>`)
    .join("")
  const head = `<saml:Assertion xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ID="${id}" IssueInstant="${iso(now)}" Version="2.0"><saml:Issuer>${a.idp}</saml:Issuer>`
  const body =
    `<saml:Subject><saml:NameID Format="${a.format ?? "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"}">${a.nameId}</saml:NameID>` +
    `<saml:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer"><saml:SubjectConfirmationData InResponseTo="${a.requestId}" NotOnOrAfter="${iso(now + 300_000)}" Recipient="${a.acs}"></saml:SubjectConfirmationData></saml:SubjectConfirmation></saml:Subject>` +
    `<saml:Conditions NotBefore="${iso(now - 60_000)}" NotOnOrAfter="${iso(now + 300_000)}"><saml:AudienceRestriction><saml:Audience>${a.audience}</saml:Audience></saml:AudienceRestriction></saml:Conditions>` +
    `<saml:AuthnStatement AuthnInstant="${iso(now)}" SessionIndex="_s1"></saml:AuthnStatement>` +
    (attrs ? `<saml:AttributeStatement>${attrs}</saml:AttributeStatement>` : "") +
    `</saml:Assertion>`
  const digest = b64(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(head + body))))
  const signedInfoInner =
    `<ds:CanonicalizationMethod Algorithm="${EXC}"></ds:CanonicalizationMethod>` +
    `<ds:SignatureMethod Algorithm="http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"></ds:SignatureMethod>` +
    `<ds:Reference URI="#${id}"><ds:Transforms><ds:Transform Algorithm="${DS}enveloped-signature"></ds:Transform><ds:Transform Algorithm="${EXC}"></ds:Transform></ds:Transforms>` +
    `<ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"></ds:DigestMethod><ds:DigestValue>${digest}</ds:DigestValue></ds:Reference>`
  const signedInfoC14n = `<ds:SignedInfo xmlns:ds="${DS}">${signedInfoInner}</ds:SignedInfo>`
  const value = b64(new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", await rsaKey(key), new TextEncoder().encode(signedInfoC14n))))
  const signature = `<ds:Signature xmlns:ds="${DS}"><ds:SignedInfo>${signedInfoInner}</ds:SignedInfo><ds:SignatureValue>${value}</ds:SignatureValue></ds:Signature>`
  const xml =
    `<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" ID="_r${crypto.randomUUID().replace(/-/g, "")}" Version="2.0" IssueInstant="${iso(now)}" Destination="${a.acs}" InResponseTo="${a.requestId}">` +
    `<saml:Issuer xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion">${a.idp}</saml:Issuer>` +
    `<samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"></samlp:StatusCode></samlp:Status>` +
    head + signature + body +
    `</samlp:Response>`
  return { id, b64: b64(new TextEncoder().encode(xml)) }
}

const inflate = async (b64deflated: string) => {
  const bytes = Uint8Array.from(atob(b64deflated), (c) => c.charCodeAt(0))
  return new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate-raw"))).text()
}

/** A team with a verified domain and an active SAML connection, a fake Stack and a fake platform join. */
const setup = async () => {
  n += 1
  const DOMAIN = `saml${n}-acme.dev`
  const IDP = `https://idp.${DOMAIN}/saml/metadata`
  const SSO_URL = `https://idp.${DOMAIN}/saml/sso`
  const admin = await sessionToken(`stack-saml-admin-${crypto.randomUUID().slice(0, 8)}`)
  await op(admin, "user.ensure", {})
  const claim = await op(admin, "domain.claim", { domain: DOMAIN })
  const team = claim.stream.replace("team:", "") as string
  const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)) as unknown as DurableObjectStub
  const stack = { users: new Map<string, string>(), sessions: [] as Array<string> }
  const joins: Array<string> = []
  await inDO(stub, async (instance) => {
    instance.ssoJoin = async (_t: string, token: string): Promise<SsoJoin> => {
      joins.push(token)
      return { ok: true, status: "joined", role: "member", source: "domain" }
    }
    instance.http = async (req: Request) => {
      const url = new URL(req.url)
      if (url.searchParams.get("type") === "TXT") return new Response(JSON.stringify({ Status: 0, Answer: [{ name: `${url.searchParams.get("name")}.`, type: 16, data: `"${claim.value.record_value}"` }] }))
      // SAML activation fetches nothing.
      throw new Error(`unexpected fetch ${req.url}`)
    }
    instance.stack = {
      findUserByEmail: async (email: string) => (stack.users.has(email) ? { id: stack.users.get(email)!, email_verified: true } : undefined),
      createUser: async (email: string) => {
        const id = `stack_${stack.users.size + 1}`
        stack.users.set(email, id)
        return { id }
      },
      createSession: async (user: string) => {
        stack.sessions.push(user)
        const body = btoa(JSON.stringify({ sub: user, refresh_token_id: `rtid-${user}-${stack.sessions.length}` })).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
        return { access_token: `eyJhbGciOiJFUzI1NiJ9.${body}.sig`, refresh_token: `rt-${user}` }
      }
    }
  })
  expect((await op(admin, "domain.verify", { domain: DOMAIN })).ok).toBe(true)
  const created = await op(admin, "sso.connection.create_saml", { idp_entity_id: IDP, sso_url: SSO_URL, certificates: [IDP_CERT], domains: [DOMAIN] })
  expect(created.ok).toBe(true)
  expect(created.value).toMatchObject({ kind: "saml", state: "draft", secret_set: false, saml: { idp_entity_id: IDP, sso_url: SSO_URL } })
  expect(created.value.oidc).toBeUndefined()
  const connection = created.value.id as string
  // A SAML connection has no client secret.
  expect(await op(admin, "sso.connection.set_secret", { connection, client_secret: "x" })).toMatchObject({ ok: false, error: { code: "policy.invalid" } })
  const activated = await op(admin, "sso.connection.activate", { connection })
  expect(activated).toMatchObject({ ok: true, value: { state: "active" } })
  const acs = `https://api.test/v1/sso/saml/acs/${connection}`
  const sp = `https://api.test/v1/sso/saml/metadata/${team}/${connection}`
  return { DOMAIN, IDP, SSO_URL, admin, team, stub, stack, joins, connection, acs, sp }
}

/** /v1/sso/start for a SAML connection: the IdP URL, its RelayState and the AuthnRequest ID. */
const start = async (email: string) => {
  const res = await worker.fetch(`https://api.test/v1/sso/start?email=${encodeURIComponent(email)}&return_to=${encodeURIComponent(RETURN)}&client_challenge=${await challengeOf(CLIENT_VERIFIER)}`, { redirect: "manual", headers: ip() })
  expect(res.status).toBe(302)
  const url = new URL(res.headers.get("location")!)
  const request = await inflate(url.searchParams.get("SAMLRequest")!)
  const requestId = /\sID="([^"]+)"/.exec(request)![1]!
  return { url, request, requestId, relay: url.searchParams.get("RelayState")! }
}
const post = (acs: string, relay: string, samlResponse: string) =>
  worker.fetch(acs, { method: "POST", redirect: "manual", headers: { "content-type": "application/x-www-form-urlencoded", ...ip() }, body: new URLSearchParams({ SAMLResponse: samlResponse, RelayState: relay }).toString() })
const redeem = (code: string) =>
  worker.fetch("https://api.test/v1/sso/redeem", { method: "POST", headers: { "content-type": "application/json", ...ip() }, body: JSON.stringify({ code, client_verifier: CLIENT_VERIFIER }) })

describe("SAML sign-in (workerd)", { timeout: 30_000 }, () => {
  it("serves SP metadata, sends an AuthnRequest, accepts a signed Response, and ends in a Stack session", async () => {
    const s = await setup()
    const meta = await worker.fetch(s.sp)
    expect(meta.status).toBe(200)
    const xml = await meta.text()
    expect(xml).toContain(`entityID="${s.sp}"`)
    expect(xml).toContain(`Location="${s.acs}"`)
    expect(xml).toContain('WantAssertionsSigned="true"')
    expect((await worker.fetch(`https://api.test/v1/sso/saml/metadata/${s.team}/ssoc_00000000000000000000`)).status).toBe(404)

    const st = await start(`Alice@${s.DOMAIN}`)
    expect(st.url.origin + st.url.pathname).toBe(s.SSO_URL)
    expect(st.request).toContain(`AssertionConsumerServiceURL="${s.acs}"`)
    expect(st.request).toContain(`<saml:Issuer>${s.sp}</saml:Issuer>`)
    expect(st.relay.startsWith(`${s.team}.`)).toBe(true)

    const r = await response({ idp: s.IDP, audience: s.sp, acs: s.acs, requestId: st.requestId, nameId: `alice@${s.DOMAIN}`, attributes: { displayName: "Alice" } })
    const res = await post(s.acs, st.relay, r.b64)
    expect(res.status).toBe(302)
    const back = new URL(res.headers.get("location")!)
    expect(back.protocol).toBe("cmux:")
    const code = new URLSearchParams(back.hash.slice(1)).get("sso_code")!
    const tokens = (await (await redeem(code)).json()) as { refresh_token: string }
    expect(tokens.refresh_token).toBe("rt-stack_1")
    expect(s.stack.users.get(`alice@${s.DOMAIN}`)).toBe("stack_1")
    expect(s.joins).toHaveLength(1)
    // sso.enforce counts this session as the team's SSO session.
    const sso = s.stub as unknown as { ssoSession(e: string, sid: string, user: string): Promise<boolean> }
    expect(await sso.ssoSession(s.team, "rtid-stack_1-1", "stack_1")).toBe(true)
    // The RelayState is single-use.
    expect((await post(s.acs, st.relay, r.b64)).status).toBe(400)

    // The same assertion id again, freshly signed for a new request: refused as a replay.
    const st2 = await start(`alice@${s.DOMAIN}`)
    const replay = await response({ id: r.id, idp: s.IDP, audience: s.sp, acs: s.acs, requestId: st2.requestId, nameId: `alice@${s.DOMAIN}` })
    const refused = await post(s.acs, st2.relay, replay.b64)
    expect(refused.status).toBe(400)
    expect(((await refused.json()) as { error: string }).error).toContain("already used")

    // A new assertion links to the same Stack user by IdP and NameID.
    const st3 = await start(`alice@${s.DOMAIN}`)
    const again = await response({ idp: s.IDP, audience: s.sp, acs: s.acs, requestId: st3.requestId, nameId: `alice@${s.DOMAIN}` })
    expect((await post(s.acs, st3.relay, again.b64)).status).toBe(302)
    expect(s.stack.sessions).toEqual(["stack_1", "stack_1"])

    await inDO(s.stub, async (_i, state) => {
      const all = JSON.stringify(state.storage.sql.exec("SELECT * FROM own_events").toArray())
      expect(all).toContain("sso.signed_in")
      expect(all).toContain("sso.connection.activated")
      expect(all).not.toContain("rt-stack_1")
    })
  })

  it("refuses another key, another audience, another request, another IdP, an email outside the team's domains, and IdP-initiated posts", async () => {
    const s = await setup()
    const email = `bob@${s.DOMAIN}`
    const cases: Array<(requestId: string) => Promise<{ b64: string }>> = [
      (requestId) => response({ idp: s.IDP, audience: s.sp, acs: s.acs, requestId, nameId: email }, OTHER_KEY),
      (requestId) => response({ idp: s.IDP, audience: "https://someone-else.example/sp", acs: s.acs, requestId, nameId: email }),
      () => response({ idp: s.IDP, audience: s.sp, acs: s.acs, requestId: "_not_this_request", nameId: email }),
      (requestId) => response({ idp: "https://evil.example/idp", audience: s.sp, acs: s.acs, requestId, nameId: email }),
      (requestId) => response({ idp: s.IDP, audience: s.sp, acs: s.acs, requestId, nameId: "bob@unrelated.dev" }),
      (requestId) => response({ idp: s.IDP, audience: s.sp, acs: s.acs, requestId, nameId: "opaque-id-123", format: "urn:oasis:names:tc:SAML:2.0:nameid-format:persistent" })
    ]
    for (const make of cases) {
      const st = await start(email)
      expect((await post(s.acs, st.relay, (await make(st.requestId)).b64)).status).toBe(400)
    }
    // A persistent NameID with an email attribute is accepted.
    const st = await start(email)
    const ok = await response({ idp: s.IDP, audience: s.sp, acs: s.acs, requestId: st.requestId, nameId: "opaque-id-456", format: "urn:oasis:names:tc:SAML:2.0:nameid-format:persistent", attributes: { email } })
    expect((await post(s.acs, st.relay, ok.b64)).status).toBe(302)
    expect(s.stack.sessions).toEqual(["stack_1"])
    // IdP-initiated (no RelayState of ours) and a post on another connection's path.
    const unsolicited = await response({ idp: s.IDP, audience: s.sp, acs: s.acs, requestId: "_x", nameId: email })
    expect((await post(s.acs, "", unsolicited.b64)).status).toBe(400)
    const st4 = await start(email)
    expect((await post(`https://api.test/v1/sso/saml/acs/ssoc_00000000000000000000`, st4.relay, unsolicited.b64)).status).toBe(400)
  })

  it("refuses a SAML connection with an unusable certificate", async () => {
    const admin = await sessionToken(`stack-saml-bad-${crypto.randomUUID().slice(0, 8)}`)
    await op(admin, "user.ensure", {})
    const domain = `saml-bad${++n}-acme.dev`
    expect((await op(admin, "domain.claim", { domain })).ok).toBe(true)
    const bad = await op(admin, "sso.connection.create_saml", { idp_entity_id: "https://idp.example/x", sso_url: "https://idp.example/sso", certificates: ["-----BEGIN CERTIFICATE-----\n" + "A".repeat(120) + "\n-----END CERTIFICATE-----"], domains: [domain] })
    expect(bad).toMatchObject({ ok: false, error: { code: "policy.invalid" } })
  })
})
