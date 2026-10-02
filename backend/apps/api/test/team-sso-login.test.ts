import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { exportJWK, generateKeyPair, importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; TEAM_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const inDO: (stub: DurableObjectStub, fn: (instance: any, state: any) => Promise<void>) => Promise<void> = runInDurableObject as any
let n = 0
let ISSUER = ""
let DOMAIN = ""
const RETURN = "cmux://sso-complete"

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

/** A team with a verified domain and an active OIDC connection, a fake IdP and a fake Stack. */
const setup = async () => {
  n += 1
  DOMAIN = `login${n}-acme.dev`
  ISSUER = `https://idp.${DOMAIN}`
  const idpKey = await generateKeyPair("ES256", { extractable: true })
  const jwks = { keys: [{ ...(await exportJWK(idpKey.publicKey)), kid: "idp1", alg: "ES256" }] }
  const admin = await sessionToken(`stack-login-admin-${crypto.randomUUID().slice(0, 8)}`)
  await op(admin, "user.ensure", {})
  const claim = await op(admin, "domain.claim", { domain: DOMAIN })
  const team = claim.stream.replace("team:", "") as string
  const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)) as unknown as DurableObjectStub
  const idp = { nextIdToken: async (_code: string): Promise<string> => "", tokenRequests: [] as Array<URLSearchParams> }
  const stack = { users: new Map<string, string>(), sessions: [] as Array<{ user: string; ttl?: number }> }
  await inDO(stub, async (instance) => {
    instance.http = async (req: Request) => {
      const url = new URL(req.url)
      if (url.searchParams.get("type") === "TXT") return new Response(JSON.stringify({ Status: 0, Answer: [{ name: `${url.searchParams.get("name")}.`, type: 16, data: `"${claim.value.record_value}"` }] }))
      if (url.pathname === "/.well-known/openid-configuration") return new Response(JSON.stringify({ issuer: ISSUER, authorization_endpoint: `${ISSUER}/authorize`, token_endpoint: `${ISSUER}/token`, jwks_uri: `${ISSUER}/jwks` }))
      if (url.pathname === "/jwks") return new Response(JSON.stringify(jwks))
      if (url.pathname === "/token") {
        expect(req.headers.get("authorization")).toBe(`Basic ${btoa("cmux-login:idp-secret")}`)
        const form = new URLSearchParams(await req.text())
        idp.tokenRequests.push(form)
        return new Response(JSON.stringify({ id_token: await idp.nextIdToken(form.get("code")!) }))
      }
      return new Response("not found", { status: 404 })
    }
    instance.stack = {
      findUserByEmail: async (email: string) => (stack.users.has(email) ? { id: stack.users.get(email)! } : undefined),
      createUser: async (email: string) => {
        const id = `stack_${stack.users.size + 1}`
        stack.users.set(email, id)
        return { id }
      },
      createSession: async (user: string, ttl?: number) => {
        stack.sessions.push({ user, ...(ttl ? { ttl } : {}) })
        return { access_token: `at-${user}`, refresh_token: `rt-${user}` }
      }
    }
  })
  expect((await op(admin, "domain.verify", { domain: DOMAIN })).ok).toBe(true)
  const id = (await op(admin, "sso.connection.create", { issuer: ISSUER, client_id: "cmux-login", domains: [DOMAIN] })).value.id as string
  expect((await op(admin, "sso.connection.set_secret", { connection: id, client_secret: "idp-secret" })).ok).toBe(true)
  expect((await op(admin, "sso.connection.activate", { connection: id })).ok).toBe(true)
  const signIdToken = (claims: Record<string, unknown>, opts: { issuer?: string; audience?: string; key?: CryptoKey } = {}) =>
    new SignJWT(claims).setProtectedHeader({ alg: "ES256", kid: "idp1" }).setIssuer(opts.issuer ?? ISSUER).setAudience(opts.audience ?? "cmux-login").setIssuedAt().setExpirationTime("5m").sign(opts.key ?? idpKey.privateKey)
  return { team, stub, idp, stack, signIdToken, admin, connection: id }
}

const start = async (email: string, returnTo = RETURN) => worker.fetch(`https://api.test/v1/sso/start?email=${encodeURIComponent(email)}&return_to=${encodeURIComponent(returnTo)}`, { redirect: "manual" })
const callback = async (state: string, code: string) => worker.fetch(`https://api.test/v1/sso/callback?state=${encodeURIComponent(state)}&code=${encodeURIComponent(code)}`, { redirect: "manual" })

describe("OIDC sign-in (workerd)", () => {
  it("start -> IdP -> callback -> one-time code -> Stack session; links the IdP subject; refuses replays", async () => {
    const s = await setup()
    const res = await start(`Alice@${DOMAIN}`)
    expect(res.status).toBe(302)
    const auth = new URL(res.headers.get("location")!)
    expect(auth.origin + auth.pathname).toBe(`${ISSUER}/authorize`)
    expect(auth.searchParams.get("code_challenge_method")).toBe("S256")
    const state = auth.searchParams.get("state")!
    const nonce = auth.searchParams.get("nonce")!
    s.idp.nextIdToken = async () => s.signIdToken({ sub: "idp-user-1", email: `alice@${DOMAIN}`, nonce, name: "Alice" })

    const cb = await callback(state, "code-1")
    expect(cb.status).toBe(302)
    const back = new URL(cb.headers.get("location")!)
    expect(back.protocol).toBe("cmux:")
    const code = new URLSearchParams(back.hash.slice(1)).get("sso_code")!
    // PKCE: the verifier sent at the token endpoint hashes to the challenge sent at authorize.
    const verifier = s.idp.tokenRequests[0]!.get("code_verifier")!
    const digest = btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
    expect(digest).toBe(auth.searchParams.get("code_challenge"))

    const redeem = await worker.fetch("https://api.test/v1/sso/redeem", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ code }) })
    expect(await redeem.json()).toEqual({ access_token: "at-stack_1", refresh_token: "rt-stack_1" })
    expect((await worker.fetch("https://api.test/v1/sso/redeem", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ code }) })).status).toBe(400)
    // The state is single-use.
    expect((await callback(state, "code-1")).status).toBe(400)

    // Second sign-in: same IdP subject, new email at the IdP -> same Stack user (linked by subject).
    const again = new URL((await start(`alice@${DOMAIN}`)).headers.get("location")!)
    s.idp.nextIdToken = async () => s.signIdToken({ sub: "idp-user-1", email: `alice.renamed@${DOMAIN}`, nonce: again.searchParams.get("nonce")! })
    expect((await callback(again.searchParams.get("state")!, "code-2")).status).toBe(302)
    expect(s.stack.sessions.map((x) => x.user)).toEqual(["stack_1", "stack_1"])
    expect(s.stack.users.size).toBe(1)

    await inDO(s.stub, async (_i, state) => {
      const all = JSON.stringify([state.storage.sql.exec("SELECT * FROM own_events").toArray(), state.storage.sql.exec("SELECT * FROM own_outbox").toArray()])
      expect(all).not.toContain("at-stack_1")
      expect(all).not.toContain("idp-user-1")
      expect(all).toContain("sso.signed_in")
    })
  })

  it("refuses bad ID tokens: wrong nonce, wrong issuer, wrong audience, wrong key, other domain, unverified email", async () => {
    const s = await setup()
    const other = await generateKeyPair("ES256")
    const cases: Array<(nonce: string) => Promise<string>> = [
      () => s.signIdToken({ sub: "u", email: `bob@${DOMAIN}`, nonce: "not-the-nonce" }),
      (nonce) => s.signIdToken({ sub: "u", email: `bob@${DOMAIN}`, nonce }, { issuer: "https://evil.example" }),
      (nonce) => s.signIdToken({ sub: "u", email: `bob@${DOMAIN}`, nonce }, { audience: "someone-else" }),
      (nonce) => s.signIdToken({ sub: "u", email: `bob@${DOMAIN}`, nonce }, { key: other.privateKey }),
      (nonce) => s.signIdToken({ sub: "u", email: "bob@unrelated.dev", nonce }),
      (nonce) => s.signIdToken({ sub: "u", email: `bob@${DOMAIN}`, email_verified: false, nonce })
    ]
    for (const make of cases) {
      const auth = new URL((await start(`bob@${DOMAIN}`)).headers.get("location")!)
      s.idp.nextIdToken = async () => make(auth.searchParams.get("nonce")!)
      expect((await callback(auth.searchParams.get("state")!, "c")).status).toBe(400)
    }
    expect(s.stack.sessions).toEqual([])
  })

  it("refuses return_to outside the dashboard and the app callback, and emails without SSO", async () => {
    await setup()
    expect((await start(`alice@${DOMAIN}`, "https://evil.example/steal")).status).toBe(400)
    expect((await start("alice@nobody-has-this.dev")).status).toBe(404)
  })
})
