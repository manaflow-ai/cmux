import { afterEach, describe, expect, it, vi } from "vitest"
import { b64u, beginPairing, call, inDO, testEnv } from "./pairing-harness.ts"
import { rolesTeam } from "./team-roles-support.ts"
import { deliver } from "./team-stack-support.ts"
import { clearSignInRules } from "../src/policy-gate.ts"

afterEach(() => { vi.restoreAllMocks(); clearSignInRules() })

const fixture = async (kind: "mac" | "ios" | "cli" = "mac") => {
  const t = await rolesTeam()
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey) as JsonWebKey
  const registered = await call("/v1/ops", t.creator.token, {
    op: "install.register", params: { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind, name: "Laptop", device_name: "Laptop", platform: kind === "cli" ? "linux" : kind === "ios" ? "ios" : "macos" }, idempotency_key: crypto.randomUUID(), origin: "cli"
  })
  expect(registered.json.ok).toBe(true)
  const install = registered.json.value.id as string
  const challenge = (team?: string) => call("/v1/auth/challenge", undefined, { user: t.creator.user, install, ...(team === undefined ? {} : { team }) })
  const redeem = async (ch: Awaited<ReturnType<typeof challenge>>, prefix = ch.json.message_prefix, headers: Record<string, string> = {}, agent?: string) => {
    expect(ch.status).toBe(200)
    const signature = b64u(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${prefix}${ch.json.nonce}`)))
    return call("/v1/auth/token", undefined, { user: t.creator.user, install, nonce: ch.json.nonce, signature, ...(agent === undefined ? {} : { agent }) }, headers)
  }
  const userStub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(t.creator.user))
  return { ...t, install, challenge, redeem, userStub }
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

  it.each(["mac", "ios", "cli"] as const)("issues %s tokens with their existing grants and refuses retargeting back to personal", async (kind) => {
    const f = await fixture(kind), personal = await f.redeem(await f.challenge())
    const scoped = await f.redeem(await f.challenge(f.team))
    expect(scoped.status).toBe(200)
    expect(scoped.json).toMatchObject({ team: f.team, install: f.install, grant: personal.json.grant })
    const retargeted = await call("/v1/read", scoped.json.access_token, { op: "team.directory", params: {} }, { "x-cmux-team": personal.json.team })
    expect(retargeted.status).toBe(403)
  })

  it("spends a successful nonce once, and loses shared-team access immediately after membership removal", async () => {
    const f = await fixture(), ch = await f.challenge(f.team), token = await f.redeem(ch)
    expect(token.status).toBe(200)
    expect((await f.redeem(ch)).status).toBe(403)
    f.w.members.delete(`${f.stackTeam}:${f.creator.stackUser}`)
    f.w.perms.delete(`${f.stackTeam}:${f.creator.stackUser}`)
    expect((await deliver("team_membership.deleted", { team_id: f.stackTeam, user_id: f.creator.stackUser })).status).toBe(200)
    expect((await f.redeem(await f.challenge(f.team))).status).toBe(403)
    const read = await call("/v1/read", token.json.access_token, { op: "team.directory", params: {} })
    expect(read.status).toBe(403)
    expect(read.json.code).toBe("team.not_member")
  })

  it("applies the selected team's minimum version at mint instead of the personal team's", async () => {
    const f = await fixture()
    const changed = await call("/v1/ops", f.creator.token, { op: "team.policy.update", params: { changes: [{ key: "updates.minimumVersion", value: { value: "2.4.0", mode: "enforced" } }], expected_version: 0, reason: "test" }, idempotency_key: crypto.randomUUID(), origin: "cli" }, { "x-cmux-team": f.team })
    expect(changed.json.ok).toBe(true)
    clearSignInRules()
    expect((await f.redeem(await f.challenge())).status).toBe(200)
    const old = await f.redeem(await f.challenge(f.team))
    expect(old.status).toBe(403)
    expect(old.json.code).toBe("client.too_old")
    const ch = await f.challenge(f.team)
    expect((await f.redeem(ch, ch.json.message_prefix, { "x-cmux-client-version": "2.4.0" })).status).toBe(200)
  })

  it("keeps the selected team's SSO gate at mint", async () => {
    const f = await fixture(), stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(f.team))
    // Seed a serving connection; its provisioning is covered by team-sso-login. The policy RPC and mint gates run normally.
    await inDO(stub, async (owner) => {
      const state = owner.boundEngine.currentState
      // A verified claim carries its times: without them the weekly re-check time is NaN and the TeamDO alarm throws.
      state.domains = { "client-sso.test": { domain: "client-sso.test", state: "verified", requested_at: Date.now(), verified_at: Date.now() } }
      state.sso_connections = { ssoc_test: { id: "ssoc_test", kind: "oidc", state: "active", domains: ["client-sso.test"], oidc: { issuer: "https://idp.test", client_id: "test", scopes: ["openid"], authorization_endpoint: "https://idp.test/auth", token_endpoint: "https://idp.test/token", jwks_uri: "https://idp.test/jwks" }, secret_set: true, jit: { enabled: false, default_role: "member" }, created_at: Date.now(), updated_at: Date.now() } }
    })
    const changed = await call("/v1/ops", f.creator.token, { op: "team.policy.update", params: { changes: ["sso.enforce", "sso.enforceForOwners"].map((key) => ({ key, value: { value: true, mode: "enforced" } })), expected_version: 0, reason: "test" }, idempotency_key: crypto.randomUUID(), origin: "cli" }, { "x-cmux-team": f.team })
    expect(changed.json.ok).toBe(true)
    clearSignInRules()
    const token = await f.redeem(await f.challenge(f.team))
    expect(token.status).toBe(403)
    expect(token.json.code).toBe("auth.sso_required")
  })

  it("cannot attach a chief to a scoped client challenge", async () => {
    const f = await fixture(), ch = await f.challenge(f.team)
    expect((await f.redeem(ch, ch.json.message_prefix, {}, `agent_${"0".repeat(20)}`)).status).toBe(403)
    expect((await f.redeem(ch)).status).toBe(403)
  })

  it.each(["install", "grant", "expiry"])("rejects %s invalidation while the signed challenge is outstanding", async (kind) => {
    const f = await fixture(), ch = await f.challenge(f.team)
    if (kind === "install") {
      const revoked = await call("/v1/ops", f.creator.token, { op: "install.revoke", params: { install: f.install }, idempotency_key: crypto.randomUUID(), origin: "cli" })
      expect(revoked.json.ok).toBe(true)
    } else await inDO(f.userStub, async (owner) => {
      const state = owner.boundEngine.currentState, grant = state.grants[state.installs[f.install].grant]
      if (kind === "grant") grant.revoked_at = Date.now()
      else grant.expires_at = Date.now() - 1
    })
    expect((await f.redeem(ch)).status).toBe(403)
  })

  it.each(["install", "expiry"])("rechecks %s invalidation committed during membership lookup", async (kind) => {
    const f = await fixture()
    let lookups = 0
    await inDO(f.userStub, async (owner) => {
      const original = owner.tokenTeamMember.bind(owner)
      owner.tokenTeamMember = async (team: string, user: string) => {
        const role = await original(team, user)
        expect(role).not.toBeNull()
        lookups++
        if (kind === "install") {
          const revoked = await call("/v1/ops", f.creator.token, { op: "install.revoke", params: { install: f.install }, idempotency_key: crypto.randomUUID(), origin: "cli" })
          expect(revoked.json.ok).toBe(true)
        } else {
          const state = owner.boundEngine.currentState
          state.grants[state.installs[f.install].grant].expires_at = Date.now() - 1
        }
        return role
      }
    })
    const token = await f.redeem(await f.challenge(f.team))
    expect(lookups).toBe(1)
    expect(token.status).toBe(403)
    expect(token.json.message).toBe("install unknown or revoked")
  })

  it("keeps a paired daemon's bound team and refuses client-style team selection", async () => {
    const f = await fixture(), begun = await beginPairing()
    const approved = await call("/v1/ops", f.creator.token, { op: "server.pair.approve", params: { code: begun.res.json.code, team: f.team, name: "Server" }, idempotency_key: crypto.randomUUID(), origin: "cli" }, { "x-cmux-team": f.team })
    expect(approved.json.ok).toBe(true)
    const { user, install } = approved.json.value
    const refused = await call("/v1/auth/challenge", undefined, { user, install, team: f.team })
    expect(refused.status).toBe(403)
    const ch = await call("/v1/auth/challenge", undefined, { user, install })
    expect(ch.status).toBe(200)
    const signature = b64u(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, begun.pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`)))
    const minted = await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature })
    expect(minted.status).toBe(200)
    expect(minted.json.team).toBe(f.team)
  })
})
