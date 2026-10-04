import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK, decodeJwt } from "jose"
import { describe, expect, it } from "vitest"

/**
 * (e) Chief token principals: an install of the owner mints a token for one of the owner's
 * chiefs. principal.user is the owner, principal.agent the chief; every request asks the owner's
 * UserDO, so archiving the chief refuses the next request at once.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
const worker = (exports as unknown as { default: Fetcher }).default
const sessionToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const call = async (path: string, token: string | undefined, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) })
  return { status: res.status, json: (await res.json()) as any }
}
const op = (t: string, name: string, params: unknown) => call("/v1/ops", t, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "user" })
const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

const installFor = async (sub: string) => {
  const session = await sessionToken(sub)
  const user = (await op(session, "user.ensure", {})).json.value.id as string
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const install = (await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "mac", name: "mac", device_name: "mac", platform: "macos" })).json.value.id as string
  const mint = async (agent?: string) => {
    const ch = await call("/v1/auth/challenge", undefined, { user, install })
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
    return call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig), ...(agent ? { agent } : {}) })
  }
  return { session, user, install, mint }
}

describe("chief tokens", { timeout: 60_000 }, () => {
  it("carry the owner and the chief, and stop at once when the chief is archived", async () => {
    const a = await installFor("chief-tok-a")
    await op(a.session, "chief.create", {})
    const chief = (await op(a.session, "chief.create", { display_name: "Helper" })).json.value
    const tok = await a.mint(chief.id)
    expect(tok.status).toBe(200)
    expect(decodeJwt(tok.json.access_token)).toMatchObject({ sub: a.user, inst: a.install, agt: chief.id })
    // A request through another owner (FeedDO) is admitted as that chief.
    const posted = await op(tok.json.access_token, "feed.post", { type: "notice", kind: "notice", title: "from the chief" })
    expect(posted.json.ok, JSON.stringify(posted.json)).toBe(true)
    expect(posted.json.value.item.poster).toMatchObject({ agent: chief.id })
    // Archive the chief: the same token is refused on the next request.
    const archived = await op(a.session, "chief.archive", { chief: chief.id, expected_rev: chief.rev })
    expect(archived.json.ok, JSON.stringify(archived.json)).toBe(true)
    const after = await op(tok.json.access_token, "feed.post", { type: "notice", kind: "notice", title: "after archive" })
    expect(after.status).toBe(403)
    // A token for an archived chief, or another user's chief, is never minted.
    expect((await a.mint(chief.id)).status).toBe(403)
    const b = await installFor("chief-tok-b")
    const other = (await op(b.session, "chief.create", {})).json.value
    expect((await a.mint(other.id)).status).toBe(403)
  })
})
