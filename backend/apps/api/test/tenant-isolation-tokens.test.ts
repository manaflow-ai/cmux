import { SignJWT, importJWK, type JWK } from "jose"
import { env } from "cloudflare:workers"
import { beforeAll, describe, expect, it } from "vitest"
import { callOp, callRead, makeTenant, mintInstallToken, post, stackSession, succeeded, worker, type Tenant } from "./setup/tenant.ts"

/**
 * Tenant isolation, credentials (plans/cmux-next/tenant-isolation-DESIGN.md sections 5.2 to 5.5): forged,
 * tampered and replayed tokens, a challenge signed with the wrong key, a revoked install, a team named by a
 * stranger and WebSockets on another tenant's ids.
 */
let a: Tenant
let b: Tenant
let conversation: string
const b64u = (buf: ArrayBuffer | Uint8Array) => btoa(String.fromCharCode(...new Uint8Array(buf as ArrayBuffer))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const wireOpen = (path: string, token: string, extra: Array<string> = []) =>
  worker.fetch(`https://api.test${path}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": ["cmux.wire.v1", ...extra].join(", "), authorization: `Bearer ${token}` } })

beforeAll(async () => {
  a = await makeTenant("d")
  b = await makeTenant("e")
  const dm = await callOp(a.session, "dm.open", { peer: { email: `peer-${a.sub}@tenant.test` } })
  conversation = dm.body.value.conversation.id
}, 120_000)

describe("forged and replayed credentials", { timeout: 120_000 }, () => {
  it("rejects a session token with a foreign signature, a wrong audience, a wrong issuer, an expired time and alg none", async () => {
    const stack = (env as unknown as { STACK_PROJECT_ID: string }).STACK_PROJECT_ID
    const rogue = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    void rogue
    const stackKey = (await importJWK(JSON.parse((env as unknown as { STACK_TEST_PRIVATE_JWK: string }).STACK_TEST_PRIVATE_JWK) as JWK, "ES256")) as CryptoKey
    const claims = { email: a.email, email_verified: true, name: a.name }
    const sign = (key: CryptoKey, over: { iss?: string; aud?: string; exp?: string | number }) =>
      new SignJWT(claims).setProtectedHeader({ alg: "ES256", kid: "stack-test" }).setIssuer(over.iss ?? `https://api.stack-auth.com/api/v1/projects/${stack}`).setAudience(over.aud ?? stack).setSubject(a.sub).setIssuedAt().setExpirationTime(over.exp ?? "10m").sign(key)
    const forged = [
      await sign(rogue.privateKey, {}),
      await sign(rogue.privateKey, { iss: "https://api.stack-auth.com/api/v1/projects/other" }),
      await stackSession(a.sub, a.email, a.name, {}, "-5m"),
      await sign(stackKey, { aud: "someone-else" }),
      await sign(stackKey, { iss: "https://evil.example/api/v1/projects/x" }),
      `${b64u(new TextEncoder().encode(JSON.stringify({ alg: "none", typ: "JWT" })))}.${b64u(new TextEncoder().encode(JSON.stringify({ sub: a.sub, aud: stack })))}.`
    ]
    for (const [i, token] of forged.entries()) {
      const r = await callRead(token, "inbox.list", { limit: 5 })
      expect(r.status, `forged #${i}: ${r.raw.slice(0, 120)}`).toBe(401)
      expect(r.raw).not.toContain(a.canary)
    }
  })

  it("rejects A's token with its payload edited to B's subject or team (signature covers the payload)", async () => {
    for (const token of [a.session, a.installToken]) {
      const [h, p, s] = token.split(".") as [string, string, string]
      const payload = JSON.parse(atob(p.replace(/-/g, "+").replace(/_/g, "/")))
      for (const edit of [{ sub: b.sub }, { sub: b.user }, { team: b.team }, { email: b.email }]) {
        const tampered = `${h}.${b64u(new TextEncoder().encode(JSON.stringify({ ...payload, ...edit })))}.${s}`
        const r = await callRead(tampered, "install.list", {})
        expect(r.status, JSON.stringify(edit)).toBe(401)
      }
    }
  })

  it("an install token is not a session token for another user: B's install cannot act with A's user or install named in the body", async () => {
    // user.ensure / install.list answer for the TOKEN's user, whatever the params say.
    const listed = await callRead(b.installToken, "install.list", { user: a.user, team: a.team })
    expect(listed.raw).not.toContain(a.canary)
    expect(listed.raw).not.toContain(a.install)
    const revoke = await callOp(b.session, "install.revoke", { install: a.install })
    expect(succeeded(revoke) && revoke.body?.value?.revoked_at, revoke.raw).toBeFalsy()
    // A's install still works.
    expect(succeeded(await callRead(a.installToken, "install.list", {}))).toBe(true)
  })

  it("a challenge signed with B's key for A's install, and a replayed nonce, mint nothing", async () => {
    const ch = await post("/v1/auth/challenge", undefined, { user: a.user, install: a.install })
    expect(ch.status).toBe(200)
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, b.keyPair.privateKey, new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`))
    const wrong = await post("/v1/auth/token", undefined, { user: a.user, install: a.install, nonce: ch.body.nonce, signature: b64u(sig) })
    expect(wrong.status).not.toBe(200)
    expect(wrong.raw).not.toContain("access_token")
    // The right key now, but the nonce was spent by the failed attempt or is used a second time.
    const ch2 = await post("/v1/auth/challenge", undefined, { user: a.user, install: a.install })
    const ok = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, a.keyPair.privateKey, new TextEncoder().encode(`${ch2.body.message_prefix}${ch2.body.nonce}`))
    const body = { user: a.user, install: a.install, nonce: ch2.body.nonce, signature: b64u(ok) }
    expect((await post("/v1/auth/token", undefined, body)).status).toBe(200)
    expect((await post("/v1/auth/token", undefined, body)).status, "a nonce is single use").not.toBe(200)
    // B's challenge for B's own install cannot be redeemed against A's install id.
    const chB = await post("/v1/auth/challenge", undefined, { user: b.user, install: b.install })
    const sigB = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, b.keyPair.privateKey, new TextEncoder().encode(`${chB.body.message_prefix}${chB.body.nonce}`))
    expect((await post("/v1/auth/token", undefined, { user: a.user, install: a.install, nonce: chB.body.nonce, signature: b64u(sigB) })).status).not.toBe(200)
    expect((await post("/v1/auth/challenge", undefined, { user: b.user, install: a.install })).status, "a challenge for a mismatched user/install pair").not.toBe(200)
  })

  it("a revoked install's token stops working at once (not at its 10 minute expiry)", async () => {
    const t = await makeTenant("f")
    expect(succeeded(await callRead(t.installToken, "install.list", {}))).toBe(true)
    const revoked = await callOp(t.session, "install.revoke", { install: t.install })
    expect(succeeded(revoked), revoked.raw).toBe(true)
    const after = await callRead(t.installToken, "install.list", {})
    expect(after.status, after.raw).not.toBe(200)
    expect(await mintInstallToken({ user: t.user, install: t.install, keyPair: t.keyPair }), "a revoked install mints no new token").toBeUndefined()
  })

  it("a stranger cannot name A's team or conversation on a WebSocket", async () => {
    expect([401, 403, 404]).toContain((await wireOpen(`/v1/wire/conv/${conversation}`, b.session)).status)
    for (const scope of ["team", "feed"]) {
      const r = await wireOpen(`/v1/wire/${scope}`, b.session, [`team.${a.team}`])
      expect([401, 403], `${scope}: ${r.status}`).toContain(r.status)
    }
    // A itself still connects to its own conversation (the test would pass if the route were simply dead).
    expect((await wireOpen(`/v1/wire/conv/${conversation}`, a.session)).status).toBe(101)
  })
})

// Cloud machines, VM tokens and snapshots across tenants: cmux-platform owns CloudDO and tests them there.
