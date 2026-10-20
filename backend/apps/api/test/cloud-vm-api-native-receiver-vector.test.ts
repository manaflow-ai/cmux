import { expect, it } from "vitest"
import vectors from "../../../../schemas/link-token/vectors.json"
import native from "../../../../schemas/link-token/native.json"
import { signLinkToken, verifyLinkToken, type LinkClaims } from "../src/link-token.ts"

it("the Rust receiver fixture is byte-exact output of the production Native signer", async () => {
  expect(await signLinkToken(native.claims as LinkClaims, native.kid, vectors.test_keys["test-k1"])).toBe(native.token)
})

it("the shared Native fixture verifies against the current binding and is single use", async () => {
  const c = native.claims, seen = new Set<string>()
  const options = { aud: c.aud, epoch: c.epoch, now: c.iat + 10, keyset: vectors.keysets.both, seen,
    native: { issuer: c.iss, team: c.team, install: c.sub, service: "daemon", binding: { ...c.network, version: 1 as const } } }
  expect(await verifyLinkToken(native.token, options)).toMatchObject({ ok: true })
  expect(await verifyLinkToken(native.token, options)).toMatchObject({ ok: false, error: "replay" })
})
