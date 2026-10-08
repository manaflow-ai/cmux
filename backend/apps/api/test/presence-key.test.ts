import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { runInDurableObject as runIn } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"
import { jwkThumbprint } from "../src/domains/user.ts"

/** Presence keys and the text confirmation level through the API (home-messaging.md section 21). */
const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any) => Promise<T>) => Promise<T>
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace }
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
const installToken = async (user: string, install: string, k: Awaited<ReturnType<typeof newKey>>) => {
  const ch = await call("/v1/auth/challenge", undefined, { user, install })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, k.pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
  return (await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig) })).json.access_token as string
}
const device = async (sub: string, kind: "mac" | "ios") => {
  const session = await sessionToken(sub)
  const user = (await op(session, "user.ensure", {})).json.value.id as string
  const k = await newKey()
  const install = (await op(session, "install.register", { public_jwk: k.jwk, kind, name: kind, device_name: kind, platform: kind === "mac" ? "macos" : "ios" })).json.value.id as string
  const token = await installToken(user, install, k)
  return { session, user, install, token, key: k }
}

describe("presence keys and the text confirmation level", { timeout: 60_000 }, () => {
  it("a Mac registers a presence key signed by its install key; sign-out revokes it", async () => {
    const d = await device("presence-mac", "mac")
    const presence = await newKey()
    const thumb = jwkThumbprint(presence.jwk)
    const message = `cmux-presence-key-v1\ntest\n${d.user}\n${d.install}\n${thumb}`
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
    // The owner Mac reaches the domain (install_kind stamped by UserDO): refused only by the 24 h cooldown.
    expect((await op(d.token, "user.text_confirm.lower.challenge", { level: "off" })).json.error.code).toBe("text_confirm.key_cooling_down")
    // A session cannot ask for a challenge (owner device only).
    expect((await op(d.session, "user.text_confirm.lower.challenge", { level: "off" })).json.ok).toBe(false)

    expect((await op(d.token, "install.sign_out", {})).json.ok).toBe(true)
    const after = await call("/v1/read", d.session, { op: "user.text_confirm.get", params: {} })
    expect(after.json.value.presence_keys[d.install].revoked_at).not.toBeNull()
  })

  it("a text-requested level stays until the owner Mac signs a Face ID presence proof; lowering is audited and notifies (H10/H11)", async () => {
    const d = await device("presence-lower", "mac")
    const presence = await newKey()
    const message = `cmux-presence-key-v1\ntest\n${d.user}\n${d.install}\n${jwkThumbprint(presence.jwk)}`
    const regSig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, d.key.pair.privateKey, new TextEncoder().encode(message))
    expect((await call("/v1/presence-key", d.token, { platform: "mac", jwk: presence.jwk, signature: b64u(regSig) })).json.ok).toBe(true)
    const stub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(d.user))
    // Skip the new key's 24 h cooldown (as team-ssh-presence.test.ts does).
    await runInDurableObject(stub, async (i) => {
      const engine = i.boundEngine
      const c = engine.currentState.confirm
      engine.state = { ...engine.currentState, confirm: { ...c, presence_keys: { ...c.presence_keys, [d.install]: { ...c.presence_keys[d.install], usable_from: 0 } } } }
    })
    {
      const session = d.session
      const token = d.token
      const level = async () => (await call("/v1/read", session, { op: "user.text_confirm.get", params: {} })).json.value.level
      expect((await op(session, "user.text_confirm.level.set", { level: "off" })).json.error.code).toBe("text_confirm.proof_required")
      // A challenge without a signature, or signed by the wrong key, spends the nonce and lowers nothing.
      const r1 = (await op(token, "user.text_confirm.lower.challenge", { level: "off" })).json
      expect(r1.error ?? null).toBeNull()
      const c1 = r1.value
      expect((await op(token, "user.text_confirm.lower", { level: "off", nonce: c1.sign.nonce })).json.value).toMatchObject({ lowered: false })
      const c2 = (await op(token, "user.text_confirm.lower.challenge", { level: "off" })).json.value
      const forged = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, d.key.pair.privateKey, Uint8Array.from(atob(c2.message.replace(/-/g, "+").replace(/_/g, "/")), (ch) => ch.charCodeAt(0)))
      expect((await op(token, "user.text_confirm.lower", { level: "off", nonce: c2.sign.nonce, presence_sig: b64u(forged) })).json.value).toMatchObject({ lowered: false, code: "text_confirm.bad_proof" })
      expect(await level()).toBe("strict")
      // The presence key's signature over the exact challenge bytes lowers the level.
      const c3 = (await op(token, "user.text_confirm.lower.challenge", { level: "off" })).json.value
      const proof = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, presence.pair.privateKey, Uint8Array.from(atob(c3.message.replace(/-/g, "+").replace(/_/g, "/")), (ch) => ch.charCodeAt(0)))
      expect((await op(token, "user.text_confirm.lower", { level: "off", nonce: c3.sign.nonce, presence_sig: b64u(proof) })).json.value).toMatchObject({ lowered: true, level: "off" })
      expect(await level()).toBe("off")
      // The same nonce never lowers twice.
      expect((await op(token, "user.text_confirm.lower", { level: "off", nonce: c3.sign.nonce, presence_sig: b64u(proof) })).json.ok).toBe(false)
      // The lowering is audited, and the owner's feed (pushed to every owner device) gets the notice.
      expect(await runInDurableObject(stub, async (i) => JSON.stringify(i.boundEngine.currentState.confirm.audit))).toContain("lowered")
      await fireAlarm(stub)
      const items = (await call("/v1/read", session, { op: "feed.list", params: {} })).json.value.items as Array<{ type: string; title: string; body: string; poster: { kind: string } }>
      const notice = items.find((i) => i.type === "notice" && i.poster.kind === "system")
      expect(notice?.body).toContain("Off")
      // The email notice never waits on a missing object: without a Resend key it is dead-lettered at once.
      const outbox = await runInDurableObject(stub, async (i) => ({ pending: JSON.stringify(i.boundEngine.outbox.allPending(500)), dead: i.boundEngine.outbox.deadCount() as number }))
      expect(outbox.pending).not.toContain("mail.security_notice")
      expect(outbox.pending).not.toContain("MailerDO")
      expect(outbox.dead).toBeGreaterThan(0)
    }
  })

  it("iOS registration refuses an attestation that does not chain to Apple", async () => {
    const d = await device("presence-ios", "ios")
    const presence = await newKey()
    const message = `cmux-presence-key-v1\ntest\n${d.user}\n${d.install}\n${jwkThumbprint(presence.jwk)}`
    // Without the install signature, a bearer token alone is refused.
    expect((await call("/v1/presence-key", d.token, { platform: "ios", jwk: presence.jwk, attestation: "AAAA", key_id: "AAAA" })).json.error.message).toContain("did not sign")
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, d.key.pair.privateKey, new TextEncoder().encode(message))
    const r = await call("/v1/presence-key", d.token, { platform: "ios", jwk: presence.jwk, signature: b64u(sig), attestation: "AAAA", key_id: "AAAA" })
    expect(r.status).toBe(403)
    expect(r.json.error.message).toContain("attestation refused")
  })
})
