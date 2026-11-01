import { expect, it } from "vitest"
import { b64u, call, testEnv } from "./pairing-harness.ts"
import { rolesTeam } from "./team-roles-support.ts"

/** The Worker-facing UserDO projection must carry the live grant and opaque authority, never a bare key. */
it("returns current client network identity and fences an invalid grant", async () => {
  const t = await rolesTeam()
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey) as JsonWebKey
  const registered = await call("/v1/ops", t.creator.token, {
    op: "install.register", params: { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "mac", name: "Network client", device_name: "Network client", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "cli"
  })
  expect(registered.json.ok).toBe(true)
  const install = registered.json.value.id as string
  const challenge = await call("/v1/auth/challenge", undefined, { user: t.creator.user, install, team: t.team })
  const signature = b64u(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${challenge.json.message_prefix}${challenge.json.nonce}`)))
  const issued = await call("/v1/auth/token", undefined, { user: t.creator.user, install, nonce: challenge.json.nonce, signature })
  expect(issued.status).toBe(200)
  const grant = issued.json.grant as string
  const user = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(t.creator.user)) as unknown as {
    networkIdentity(entity: string, install: string, grant: string, team: string): Promise<{ key: JsonWebKey; kind: string; expires_at: number | null; authority_version: string; op_classes: ReadonlyArray<string> } | null>
  }
  const identity = await user.networkIdentity(t.creator.user, install, grant, t.team)
  expect(identity).toMatchObject({ kind: "mac", key: { kty: "EC", crv: "P-256" }, authority_version: expect.stringMatching(/^[0-9a-f]{64}$/) })
  expect(identity?.op_classes).toEqual(expect.arrayContaining(["read", "mutate-own"]))
  expect(await user.networkIdentity(t.creator.user, install, `grant_${"9".repeat(20)}`, t.team)).toBeNull()
  const revoked = await call("/v1/ops", t.creator.token, { op: "install.revoke", params: { install }, idempotency_key: crypto.randomUUID(), origin: "cli" })
  expect(revoked.json.ok, JSON.stringify(revoked.json)).toBe(true)
  expect(await user.networkIdentity(t.creator.user, install, grant, t.team)).toBeNull()
})
