import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"

/**
 * The iPhone install principal (identity spec D5): an `ios` install registers with a session,
 * proves its key with the one-time challenge and gets a short-lived token whose principal
 * carries install_kind "ios". iOS SecKeyCreateSignature (.ecdsaSignatureMessageX962SHA256)
 * returns DER signatures; CryptoKit returns raw r||s. Both are accepted.
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
const call = async (path: string, token: string | undefined, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })
  return { status: res.status, json: (await res.json()) as any }
}
const op = (token: string, name: string, params: unknown) => call("/v1/ops", token, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

/** Raw r||s (64 bytes) to DER, as iOS Security.framework emits it. */
const toDer = (raw: Uint8Array): Uint8Array => {
  const int = (b: Uint8Array) => {
    let i = 0
    while (i < b.length - 1 && b[i] === 0) i++
    const v = b.slice(i)
    return v[0]! & 0x80 ? Uint8Array.of(0, ...v) : v
  }
  const r = int(raw.slice(0, 32))
  const s = int(raw.slice(32))
  return Uint8Array.of(0x30, r.length + s.length + 4, 0x02, r.length, ...r, 0x02, s.length, ...s)
}

describe("iPhone install principal (D5)", { timeout: 30_000 }, () => {
  for (const form of ["der", "raw"] as const) {
    it(`an ios install mints a token with a ${form} signature, and its principal is install_kind ios`, async () => {
      const session = await sessionToken(`ios-${form}`)
      const user = (await op(session, "user.ensure", {})).json.value.id as string
      const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
      const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
      const reg = await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "ios", name: "cmux iOS", device_name: "Aziz", platform: "ios" })
      expect(reg.json.ok).toBe(true)
      const install = reg.json.value.id as string

      const ch = await call("/v1/auth/challenge", undefined, { user, install })
      expect(ch.status).toBe(200)
      const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`)))
      const tok = await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(form === "der" ? toDer(raw) : raw) })
      expect(tok.status).toBe(200)

      // The install token acts as the iPhone: install.rename on itself succeeds and the event actor is the ios install.
      const renamed = await op(tok.json.access_token, "install.rename", { install, name: "cmux iOS (renamed)" })
      expect(renamed.json.ok).toBe(true)
      expect(renamed.json.value).toMatchObject({ id: install, kind: "ios" })
    })
  }

  it("a malformed DER signature is refused", async () => {
    const session = await sessionToken("ios-bad-der")
    const user = (await op(session, "user.ensure", {})).json.value.id as string
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    const install = (await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "ios", name: "x", device_name: "x", platform: "ios" })).json.value.id as string
    const ch = await call("/v1/auth/challenge", undefined, { user, install })
    const bad = Uint8Array.of(0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x09, 0x01)
    expect((await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(bad) })).status).toBe(403)
  })
})
