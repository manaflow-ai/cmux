import { importJWK, SignJWT } from "jose"
import { expect, it } from "vitest"
import { verifyLinkToken } from "../src/link-token.ts"
import vectors from "../../../../schemas/link-token/vectors.json"

const now = 1_792_000_000, team = "team_00000000000000000001", install = "inst_00000000000000000001"
const binding = { version: 1 as const, tenant: "team_native", mesh: "mesh_" + "0".repeat(26), device: "dev_" + "0".repeat(26),
  host: "host_00000000000000000001", user: "user_00000000000000000001", wg_public_key: btoa("a".repeat(32)), authority_version: "a".repeat(64), acl_version: 1 }
const claims = { iss: "cmux:cloud:test", aud: "host_00000000000000000002", sub: install, team, svc: ["ssh"], epoch: 2,
  iat: now, exp: now + 300, jti: "A".repeat(22), network: binding }
const options = () => ({ aud: claims.aud, epoch: 2, now, keyset: vectors.keysets.both,
  native: { issuer: claims.iss, team, install, service: "ssh", binding } })
// Independent signing keeps malformed-but-authentic claim cases outside the producer's validator.
const sign = async (value: Record<string, unknown>) => new SignJWT(value)
  .setProtectedHeader({ alg: "EdDSA", typ: "cmux-link+jwt", kid: "test-k1" })
  .sign(await importJWK(vectors.test_keys["test-k1"], "EdDSA"))

it("accepts a valid signature only for the current Native receiver identity and requested service", async () => {
  expect(await verifyLinkToken(await sign(claims), options())).toMatchObject({ ok: true })
})

it.each(["version", "tenant", "mesh", "device", "host", "user", "wg_public_key", "authority_version", "acl_version"] as const)("refuses a signed Native %s from an older or different authority", async (field) => {
  const value = { ...binding, [field]: field === "version" || field === "acl_version" ? 2 : "different" }
  expect(await verifyLinkToken(await sign({ ...claims, network: value }), options())).toMatchObject({ ok: false, error: "native_identity" })
})

it("never accepts an unbound legacy token on a Native receiving path", async () => {
  const { network: _network, ...legacy } = claims
  expect(await verifyLinkToken(await sign(legacy), options())).toMatchObject({ ok: false, error: "native_identity" })
  const { native: _native, ...oldReceiver } = options()
  expect(await verifyLinkToken(await sign(legacy), oldReceiver)).toMatchObject({ ok: true })
})

it.each(["iss", "team", "sub", "svc"] as const)("refuses an authentic token with an unapproved %s", async (field) => {
  const value = { ...claims, [field]: field === "svc" ? ["daemon"] : "different" }
  expect(await verifyLinkToken(await sign(value), options())).toMatchObject({ ok: false, error: "native_identity" })
})

it("does not spend a token on a failed authority match and refuses it after successful use", async () => {
  const token = await sign(claims), seen = new Set<string>(), expected = options()
  const stale = { ...expected, seen, native: { ...expected.native, binding: { ...binding, authority_version: "b".repeat(64) } } }
  expect(await verifyLinkToken(token, stale)).toMatchObject({ ok: false })
  expect(seen.size).toBe(0)
  expect(await verifyLinkToken(token, { ...expected, seen })).toMatchObject({ ok: true })
  expect(await verifyLinkToken(token, { ...expected, seen })).toMatchObject({ ok: false, error: "replay" })
})
