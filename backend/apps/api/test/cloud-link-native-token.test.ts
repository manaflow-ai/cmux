import { decodeJwt, decodeProtectedHeader } from "jose"
import { describe, expect, it } from "vitest"
import { NATIVE_LINK_TOKEN_TYP, signLinkToken, verifyLinkToken, type LinkClaims } from "../src/link-token.ts"
import type { NativeLinkExpected } from "../src/link-token-native.ts"
import vectors from "../../../../schemas/link-token/vectors.json"

const kid = Object.keys(vectors.test_keys)[0]!
const key = vectors.test_keys[kid as keyof typeof vectors.test_keys]
const publicKey = { kty: key.kty, crv: key.crv, x: key.x }
const now = 1_793_424_000
const claims: LinkClaims = {
  iss: "cmux:cloud:development", aud: "host_" + "1".repeat(20), sub: "inst_" + "2".repeat(20),
  team: "team_" + "3".repeat(20), svc: ["daemon", "ssh"], epoch: 1, iat: now, exp: now + 60,
  jti: "A".repeat(22), vmk: "owner",
  network: { version: 1, tenant: "tenant-test", mesh: "mesh_" + "0".repeat(26), device: "dev_" + "0".repeat(26),
    host: "host_" + "4".repeat(20), user: "user_" + "5".repeat(20), wg_public_key: btoa("x".repeat(32)),
    authority_version: "a".repeat(64), acl_version: 1 },
  receiver: { version: 2, generation: "b".repeat(64) }
}
const expected: NativeLinkExpected = {
  issuer: claims.iss, team: claims.team, install: claims.sub, service: "daemon",
  binding: claims.network!, receiver: claims.receiver!
}
const verifier = () => ({ aud: claims.aud, epoch: claims.epoch, now, keyset: { [kid]: publicKey }, seen: new Set<string>(), native: expected })

describe("Native receiving token wire contract", () => {
  it("signs the checked client and receiver generation while preserving the caller's owner answer", async () => {
    const token = await signLinkToken(claims, kid, key)
    expect(decodeProtectedHeader(token).typ).toBe(NATIVE_LINK_TOKEN_TYP)
    expect(decodeJwt(token)).toMatchObject({ network: claims.network, receiver: claims.receiver, vmk: "owner" })
    const v = verifier()
    expect(await verifyLinkToken(token, v)).toMatchObject({ ok: true, claims: { vmk: "owner" } })
    expect(await verifyLinkToken(token, v)).toEqual({ ok: false, error: "replay" })
  })

  it("refuses a replaced receiver generation or client authority before consuming replay state", async () => {
    const token = await signLinkToken(claims, kid, key)
    const v = verifier()
    expect(await verifyLinkToken(token, { ...v, native: { ...expected, receiver: { version: 2, generation: "c".repeat(64) } } }))
      .toEqual({ ok: false, error: "native_identity" })
    expect(await verifyLinkToken(token, { ...v, native: { ...expected, binding: { ...expected.binding, authority_version: "d".repeat(64) } } }))
      .toEqual({ ok: false, error: "native_identity" })
    expect(v.seen.size).toBe(0)
    expect(await verifyLinkToken(token, v)).toMatchObject({ ok: true })
  })

  it("requires a replay owner and rejects Native receiving tokens on a legacy verifier", async () => {
    const token = await signLinkToken(claims, kid, key)
    const v = verifier()
    expect(await verifyLinkToken(token, { ...v, seen: undefined })).toEqual({ ok: false, error: "native_identity" })
    expect(await verifyLinkToken(token, { ...v, native: undefined })).toEqual({ ok: false, error: "typ" })
  })

  it("rejects malformed bindings before signing", async () => {
    await expect(signLinkToken({ ...claims, network: undefined }, kid, key)).rejects.toThrow("invalid link receiving generation")
    await expect(signLinkToken({ ...claims, receiver: { version: 2, generation: "" } }, kid, key)).rejects.toThrow("invalid link receiving generation")
  })
})
