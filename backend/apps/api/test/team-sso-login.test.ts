import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { exportJWK, generateKeyPair, importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it, vi } from "vitest"
import { clearSignInRules, withSsoSession } from "../src/policy-gate.ts"

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
  const stack = { users: new Map<string, string>(), unverified: new Set<string>(), created: 0, sessions: [] as Array<{ user: string; ttl?: number }> }
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
      findUserByEmail: async (email: string) => (stack.users.has(email) ? { id: stack.users.get(email)!, email_verified: !stack.unverified.has(email) } : undefined),
      createUser: async (email: string) => {
        // Slow, so two concurrent first sign-ins interleave here.
        await new Promise((r) => setTimeout(r, 30))
        stack.created += 1
        const id = `stack_${stack.users.size + 1}`
        stack.users.set(email, id)
        return { id }
      },
      createSession: async (user: string, ttl?: number) => {
        stack.sessions.push({ user, ...(ttl ? { ttl } : {}) })
        // A Stack-shaped access token: the callback reads its refresh_token_id (unverified decode).
        const body = btoa(JSON.stringify({ sub: user, refresh_token_id: `rtid-${user}` })).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
        return { access_token: `eyJhbGciOiJFUzI1NiJ9.${body}.sig`, refresh_token: `rt-${user}` }
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

/** A fresh client IP per request, so the shared per-IP limiter never trips across tests. */
const ip = () => ({ "cf-connecting-ip": `198.51.100.${Math.floor(Math.random() * 250)}-${crypto.randomUUID()}` })
const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const CLIENT_VERIFIER = "client-verifier-0123456789-abcdefghijklmnopqrstuvwxyz"
const challengeOf = async (v: string) => b64u(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(v))))
const start = async (email: string, returnTo = RETURN) =>
  worker.fetch(`https://api.test/v1/sso/start?email=${encodeURIComponent(email)}&return_to=${encodeURIComponent(returnTo)}&client_challenge=${await challengeOf(CLIENT_VERIFIER)}`, { redirect: "manual", headers: ip() })
const callback = async (state: string, code: string, path?: string) => {
  const p = path ?? (await pendingPath(state))
  return worker.fetch(`https://api.test${p}?state=${encodeURIComponent(state)}&code=${encodeURIComponent(code)}`, { redirect: "manual", headers: ip() })
}
/** The callback path the start step registered (per connection). */
const pathByState = new Map<string, string>()
const pendingPath = async (state: string) => pathByState.get(state) ?? "/v1/sso/callback"
const redeem = (code: string, verifier = CLIENT_VERIFIER) =>
  worker.fetch("https://api.test/v1/sso/redeem", { method: "POST", headers: { "content-type": "application/json", ...ip() }, body: JSON.stringify({ code, client_verifier: verifier }) })
const authFrom = (res: Response) => {
  const auth = new URL(res.headers.get("location")!)
  pathByState.set(auth.searchParams.get("state")!, new URL(auth.searchParams.get("redirect_uri")!).pathname)
  return auth
}

describe("OIDC sign-in (workerd)", () => {
  it("start -> IdP -> callback -> one-time code -> Stack session; links the IdP subject; refuses replays", async () => {
    const s = await setup()
    const res = await start(`Alice@${DOMAIN}`)
    expect(res.status).toBe(302)
    const auth = authFrom(res)
    expect(auth.origin + auth.pathname).toBe(`${ISSUER}/authorize`)
    expect(new URL(auth.searchParams.get("redirect_uri")!).pathname).toBe(`/v1/sso/callback/${s.connection}`)
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

    // Login CSRF / code theft: without the verifier of the client that started the flow, the code is useless.
    expect((await redeem(code, "someone-elses-verifier-0123456789-abcdefghijklmnop")).status).toBe(400)
    const redeemed = await redeem(code)
    const tokens = (await redeemed.json()) as { access_token: string; refresh_token: string }
    expect(tokens.refresh_token).toBe("rt-stack_1")
    // sso.enforce (P17-4): the team recorded the session it created, by Stack's refresh token id.
    const sso = s.stub as unknown as { ssoSession(e: string, sid: string, user: string): Promise<boolean> }
    expect(await sso.ssoSession(s.team, "rtid-stack_1", "stack_1")).toBe(true)
    expect(await sso.ssoSession(s.team, "rtid-other", "stack_1")).toBe(false)
    expect(await sso.ssoSession(s.team, "rtid-stack_1", "stack_2")).toBe(false)
    const principal = { identity: "session:u", kind: "session" as const, user: "user_u", team: s.team, stack_user_id: "stack_1" }
    expect((await withSsoSession(env as never, { ...principal, stack_session: "rtid-stack_1" }, s.team)).sso_team).toBe(s.team)
    expect((await withSsoSession(env as never, { ...principal, stack_session: "rtid-other" }, s.team)).sso_team).toBeUndefined()
    expect((await redeem(code)).status).toBe(400)
    // The state is single-use.
    expect((await callback(state, "code-1")).status).toBe(400)

    // Second sign-in: same IdP subject, new email at the IdP -> same Stack user (linked by subject).
    const again = authFrom(await start(`alice@${DOMAIN}`))
    s.idp.nextIdToken = async () => s.signIdToken({ sub: "idp-user-1", email: `alice.renamed@${DOMAIN}`, nonce: again.searchParams.get("nonce")! })
    expect((await callback(again.searchParams.get("state")!, "code-2")).status).toBe(302)
    expect(s.stack.sessions.map((x) => x.user)).toEqual(["stack_1", "stack_1"])
    expect(s.stack.users.size).toBe(1)

    await inDO(s.stub, async (_i, state) => {
      const all = JSON.stringify([state.storage.sql.exec("SELECT * FROM own_events").toArray(), state.storage.sql.exec("SELECT * FROM own_outbox").toArray()])
      expect(all).not.toContain("rt-stack_1")
      expect(all).not.toContain("eyJhbGciOiJFUzI1NiJ9")
      expect(all).not.toContain("idp-user-1")
      expect(all).toContain("sso.signed_in")
    })
    // Disabling the connection ends the standing of the sessions it created.
    const standing = s.stub as unknown as { ssoSession(e: string, sid: string, user: string): Promise<boolean> }
    expect((await op(s.admin, "sso.connection.disable", { connection: s.connection })).ok).toBe(true)
    expect(await standing.ssoSession(s.team, "rtid-stack_1", "stack_1")).toBe(false)
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
      const auth = authFrom(await start(`bob@${DOMAIN}`))
      s.idp.nextIdToken = async () => make(auth.searchParams.get("nonce")!)
      expect((await callback(auth.searchParams.get("state")!, "c")).status).toBe(400)
    }
    expect(s.stack.sessions).toEqual([])
  })

  it("refuses return_to outside the dashboard and the app callback, and emails without SSO", async () => {
    await setup()
    expect((await start(`alice@${DOMAIN}`, "https://evil.example/steal")).status).toBe(400)
    // Only exact return addresses: no other path on the dashboard (an open redirect there would leak the code).
    expect((await start(`alice@${DOMAIN}`, "http://localhost:3010/anything")).status).toBe(400)
    // A start without a client challenge is refused.
    expect((await worker.fetch(`https://api.test/v1/sso/start?email=alice@${DOMAIN}&return_to=${encodeURIComponent(RETURN)}`, { redirect: "manual", headers: ip() })).status).toBe(400)
    expect((await start("alice@nobody-has-this.dev")).status).toBe(404)
  })

  it("never links an IdP identity to an existing Stack account whose email is unverified (pre-hijacking)", async () => {
    const s = await setup()
    s.stack.users.set(`carol@${DOMAIN}`, "stack_attacker")
    s.stack.unverified.add(`carol@${DOMAIN}`)
    const auth = authFrom(await start(`carol@${DOMAIN}`))
    s.idp.nextIdToken = async () => s.signIdToken({ sub: "idp-carol", email: `carol@${DOMAIN}`, nonce: auth.searchParams.get("nonce")! })
    const cb = await callback(auth.searchParams.get("state")!, "c")
    expect(cb.status).toBe(400)
    expect(await cb.json()).toMatchObject({ code: "sso.account_conflict" })
    expect(s.stack.sessions).toEqual([])
  })

  it("refuses a callback on another connection's path or with a mismatched iss (mix-up)", async () => {
    const s = await setup()
    const auth = authFrom(await start(`dave@${DOMAIN}`))
    s.idp.nextIdToken = async () => s.signIdToken({ sub: "idp-dave", email: `dave@${DOMAIN}`, nonce: auth.searchParams.get("nonce")! })
    const state = auth.searchParams.get("state")!
    expect((await worker.fetch(`https://api.test/v1/sso/callback/ssoc_00000000000000000000?state=${encodeURIComponent(state)}&code=c`, { redirect: "manual", headers: ip() })).status).toBe(400)
    const auth2 = authFrom(await start(`dave@${DOMAIN}`))
    const p = pathByState.get(auth2.searchParams.get("state")!)!
    expect((await worker.fetch(`https://api.test${p}?state=${encodeURIComponent(auth2.searchParams.get("state")!)}&code=c&iss=${encodeURIComponent("https://evil.example")}`, { redirect: "manual", headers: ip() })).status).toBe(400)
  })

  it("two concurrent first sign-ins of one person create one Stack user (idempotent link by issuer and subject)", async () => {
    const s = await setup()
    const a1 = authFrom(await start(`erin@${DOMAIN}`))
    const a2 = authFrom(await start(`erin@${DOMAIN}`))
    const nonces = new Map([["c1", a1.searchParams.get("nonce")!], ["c2", a2.searchParams.get("nonce")!]])
    s.idp.nextIdToken = async (code) => s.signIdToken({ sub: "idp-erin", email: `erin@${DOMAIN}`, nonce: nonces.get(code)! })
    const [r1, r2] = await Promise.all([callback(a1.searchParams.get("state")!, "c1"), callback(a2.searchParams.get("state")!, "c2")])
    expect([r1.status, r2.status]).toEqual([302, 302])
    expect(s.stack.created).toBe(1)
    expect(new Set(s.stack.sessions.map((x) => x.user)).size).toBe(1)
  })

  it("sso.enforce binds every user of the team's verified domain, whatever team the token names; installs too", async () => {
    const s = await setup()
    // Before enforcement: a domain user signs in with a password (no SSO) and registers an install.
    const pat = await stackSession(`stack-pat-${crypto.randomUUID().slice(0, 8)}`, `pat@${DOMAIN}`)
    expect((await op(pat, "user.ensure", {})).ok).toBe(true)
    const patInstall = await register(pat)
    // Alice signs in through the team's SSO; her Stack session is the one the callback recorded.
    await ssoSignIn(s, "alice", "idp-alice")
    const alice = await stackSession("stack_1", `alice@${DOMAIN}`, "rtid-stack_1")
    expect((await op(alice, "user.ensure", {})).ok).toBe(true)
    const aliceInstall = await register(alice)
    const outsider = await stackSession(`stack-out-${crypto.randomUUID().slice(0, 8)}`, "olga@unrelated-sso.dev")
    expect((await op(outsider, "user.ensure", {})).ok).toBe(true)

    // The team has an active connection on a verified domain, so enforced SSO is accepted.
    const on = await op(s.admin, "team.policy.update", { changes: [{ key: "sso.enforce", value: { value: true, mode: "enforced" } }], expected_version: 0, reason: "test" })
    expect(on.error).toBeUndefined()
    clearSignInRules()

    // pat's token names pat's personal team; the domain's team still requires its SSO.
    expect((await op(pat, "user.ensure", {})).code).toBe("auth.sso_required")
    const patWire = await worker.fetch("https://api.test/v1/wire/user", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${pat}` } })
    expect(patWire.status).toBe(403)
    expect((await mint(patInstall)).status).toBe(403)
    // The SSO session and the install it registered pass; users of other domains and the owner are not bound.
    expect((await op(alice, "user.ensure", {})).ok).toBe(true)
    expect((await mint(aliceInstall)).status).toBe(200)
    expect((await op(outsider, "user.ensure", {})).ok).toBe(true)
    expect((await op(s.admin, "user.ensure", {})).ok).toBe(true)

    // A recommended (default) value never locks anyone out.
    const dflt = await op(s.admin, "team.policy.update", { changes: [{ key: "sso.enforce", value: { value: true, mode: "default" } }], expected_version: 1, reason: "test" })
    expect(dflt.error).toBeUndefined()
    clearSignInRules()
    expect((await op(pat, "user.ensure", {})).ok).toBe(true)
  })

  it("lowering sso.sessionMaxAgeHours shortens the session records that already exist", async () => {
    const s = await setup()
    await ssoSignIn(s, "max", "idp-max")
    const standing = s.stub as unknown as { ssoSession(e: string, sid: string, user: string): Promise<boolean> }
    expect(await standing.ssoSession(s.team, "rtid-stack_1", "stack_1")).toBe(true)
    const r = await op(s.admin, "team.policy.update", { changes: [{ key: "sso.sessionMaxAgeHours", value: { value: 1, mode: "enforced" } }], expected_version: 0, reason: "test" })
    expect(r.error).toBeUndefined()
    // Still young: the record stands.
    expect(await standing.ssoSession(s.team, "rtid-stack_1", "stack_1")).toBe(true)
    vi.useFakeTimers({ toFake: ["Date"] })
    try {
      vi.setSystemTime(Date.now() + 2 * 3_600_000)
      expect(await standing.ssoSession(s.team, "rtid-stack_1", "stack_1")).toBe(false)
    } finally {
      vi.useRealTimers()
    }
  })
})

/** A Stack-signed session for any email, with Stack's refresh_token_id claim when given. */
const stackSession = async (sub: string, email: string, refreshTokenId?: string) =>
  new SignJWT({ email, email_verified: true, name: sub, ...(refreshTokenId ? { refresh_token_id: refreshTokenId } : {}) })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))

/** A full OIDC sign-in through the team's connection (the fake Stack names the first user stack_1). */
const ssoSignIn = async (s: Awaited<ReturnType<typeof setup>>, local: string, sub: string) => {
  const auth = authFrom(await start(`${local}@${DOMAIN}`))
  s.idp.nextIdToken = async () => s.signIdToken({ sub, email: `${local}@${DOMAIN}`, nonce: auth.searchParams.get("nonce")! })
  expect((await callback(auth.searchParams.get("state")!, `code-${local}`)).status).toBe(302)
}

const keys = new Map<string, { user: string; pair: CryptoKeyPair }>()
/** Registers an install from a session; mint() later asks for its token. */
const register = async (session: string) => {
  const user = (await op(session, "user.ensure", {})).value.id as string
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const r = await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "mac", name: "m", device_name: "m", platform: "macos" })
  const install = r.value.id as string
  keys.set(install, { user, pair })
  return install
}
const mint = async (install: string) => {
  const { user, pair } = keys.get(install)!
  const post = (path: string, body: unknown) => worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) })
  const ch = (await (await post("/v1/auth/challenge", { user, install })).json()) as { nonce: string; message_prefix: string }
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.message_prefix}${ch.nonce}`)))
  return post("/v1/auth/token", { user, install, nonce: ch.nonce, signature: b64u(sig) })
}
