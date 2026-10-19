import { describe, expect, it } from "vitest"
import { b64u, call } from "./pairing-harness.ts"
import { rolesTeam } from "./team-roles-support.ts"

const fixture = async () => {
  const t = await rolesTeam()
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey) as JsonWebKey
  const registered = await call("/v1/ops", t.creator.token, {
    op: "install.register", params: { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "mac", name: "Laptop", device_name: "Laptop", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "cli"
  })
  expect(registered.json.ok).toBe(true)
  const install = registered.json.value.id as string
  const challenge = (team?: string) => call("/v1/auth/challenge", undefined, { user: t.creator.user, install, ...(team === undefined ? {} : { team }) })
  const redeem = async (ch: Awaited<ReturnType<typeof challenge>>, prefix = ch.json.message_prefix) => {
    expect(ch.status).toBe(200)
    const signature = b64u(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${prefix}${ch.json.nonce}`)))
    return call("/v1/auth/token", undefined, { user: t.creator.user, install, nonce: ch.json.nonce, signature })
  }
  return { ...t, install, challenge, redeem }
}

describe("client team-scoped token issuance", () => {
  it("preserves personal issuance by default and refuses header retargeting", async () => {
    const f = await fixture(), token = await f.redeem(await f.challenge())
    expect(token.status).toBe(200)
    expect(token.json.team).not.toBe(f.team)
    const read = await call("/v1/read", token.json.access_token, { op: "team.directory", params: {} }, { "x-cmux-team": f.team })
    expect(read.status).toBe(403)
    expect(read.json.code).toBe("auth.forbidden")
  })

  it("mints a token for a current shared-team member and enrolls their actual install", async () => {
    const f = await fixture(), token = await f.redeem(await f.challenge(f.team))
    expect(token.status).toBe(200)
    expect(token.json.team).toBe(f.team)
    const enrolled = await call("/v1/ops", token.json.access_token, { op: "host.enroll", params: { name: "Laptop", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "cli" })
    expect(enrolled.json.ok).toBe(true)
  })

  it("binds the selected team into the signed challenge, so an ordinary signature cannot authorize it", async () => {
    const f = await fixture(), ordinary = await f.challenge(), scoped = await f.challenge(f.team)
    expect(scoped.json.message_prefix).not.toBe(ordinary.json.message_prefix)
    expect(scoped.json.message_prefix).toContain(f.team)
    expect((await f.redeem(scoped, ordinary.json.message_prefix)).status).toBe(403)
    expect((await f.redeem(scoped)).status).toBe(403)
  })

  it("refuses a signed request for a team the client owner never joined", async () => {
    const f = await fixture(), other = await rolesTeam()
    expect((await f.redeem(await f.challenge(other.team))).status).toBe(403)
  })
})
