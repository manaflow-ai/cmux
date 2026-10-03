import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { jwkThumbprint } from "../src/domains/user.ts"

/** Presence keys and the text confirmation level through the API (home-messaging.md section 21). */
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
  return { status: res.status, json: (await res.json().catch(() => null)) as any }
}
const op = (token: string, name: string, params: unknown) => call("/v1/ops", token, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "user" })
const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const newKey = async () => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const j = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  return { pair, jwk: { kty: "EC", crv: "P-256", x: j.x!, y: j.y! } }
}
const device = async (sub: string, kind: "mac" | "ios") => {
  const session = await sessionToken(sub)
  const user = (await op(session, "user.ensure", {})).json.value.id as string
  const k = await newKey()
  const install = (await op(session, "install.register", { public_jwk: k.jwk, kind, name: kind, device_name: kind, platform: kind === "mac" ? "macos" : "ios" })).json.value.id as string
  const ch = await call("/v1/auth/challenge", undefined, { user, install })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, k.pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
  const token = (await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig) })).json.access_token as string
  return { session, user, install, token, key: k }
}

describe("presence keys and the text confirmation level", { timeout: 60_000 }, () => {
  it("a Mac registers a presence key signed by its install key; sign-out revokes it", async () => {
    const d = await device("presence-mac", "mac")
    const presence = await newKey()
    const thumb = jwkThumbprint(presence.jwk)
    const message = `cmux-presence-key-v1\n${d.user}\n${d.install}\n${thumb}`
    const wrong = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, presence.pair.privateKey, new TextEncoder().encode(message))
    expect((await call("/v1/presence-key", d.token, { platform: "mac", jwk: presence.jwk, signature: b64u(wrong) })).status).toBe(403)
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, d.key.pair.privateKey, new TextEncoder().encode(message))
    const reg = await call("/v1/presence-key", d.token, { platform: "mac", jwk: presence.jwk, signature: b64u(sig) })
    expect(reg.json.ok).toBe(true)
    expect(reg.json.value.usable_from).toBeGreaterThan(Date.now() + 23 * 3_600_000)
    // A session cannot register keys; the platform must match the install.
    expect((await call("/v1/presence-key", d.session, { platform: "mac", jwk: presence.jwk, signature: b64u(sig) })).status).toBe(403)
    expect((await call("/v1/presence-key", d.token, { platform: "ios", jwk: presence.jwk })).status).toBe(400)

    const view = await call("/v1/read", d.session, { op: "user.text_confirm.get", params: {} })
    expect(view.json.value).toMatchObject({ level: "strict", presence_keys: { [d.install]: { platform: "mac", revoked_at: null } } })
    expect(JSON.stringify(view.json.value)).not.toContain(presence.jwk.x)
    // Safer applies; riskier needs the device proof; a fresh key is in its 24 h cooldown.
    expect((await op(d.session, "user.text_confirm.level.set", { level: "strict" })).json.ok).toBe(true)
    expect((await op(d.session, "user.text_confirm.level.set", { level: "off" })).json.error.code).toBe("text_confirm.proof_required")
    expect((await op(d.token, "user.text_confirm.lower.challenge", { level: "off" })).json.ok).toBe(false)
    // A session cannot ask for a challenge (owner device only).
    expect((await op(d.session, "user.text_confirm.lower.challenge", { level: "off" })).json.ok).toBe(false)

    expect((await op(d.token, "install.sign_out", {})).json.ok).toBe(true)
    const after = await call("/v1/read", d.session, { op: "user.text_confirm.get", params: {} })
    expect(after.json.value.presence_keys[d.install].revoked_at).not.toBeNull()
  })

  it("iOS registration refuses an attestation that does not chain to Apple", async () => {
    const d = await device("presence-ios", "ios")
    const presence = await newKey()
    const r = await call("/v1/presence-key", d.token, { platform: "ios", jwk: presence.jwk, attestation: "AAAA", key_id: "AAAA" })
    expect(r.status).toBe(403)
    expect(r.json.error.message).toContain("attestation refused")
  })
})
