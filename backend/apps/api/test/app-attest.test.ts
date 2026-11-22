import { createHash, X509Certificate } from "node:crypto"
import { describe, expect, it } from "vitest"
import { APPLE_APP_ATTESTATION_ROOT, verifyAttestation, verifyAttestationWithRoot } from "../src/app-attest.ts"
import fixture from "./fixtures-app-attest.json"

/**
 * The attestation check in workerd, on a synthetic chain (test root, intermediate, credCert
 * with the nonce extension, development AAGUID), built by openssl for this fixture.
 */
const rootSha = createHash("sha256").update(new X509Certificate(fixture.root).raw).digest("hex")
const base = { attestation: fixture.attestation, keyId: fixture.keyId, clientData: new TextEncoder().encode(fixture.clientData), appId: fixture.appId, allowDevelopment: true, now: Date.now() }

describe("App Attest attestation (registration)", () => {
  it("accepts a valid chain, nonce, key id, app id and counter, and returns the attested key", () => {
    const r = verifyAttestationWithRoot(fixture.root, rootSha, base)
    expect(r.ok).toBe(true)
    if (r.ok) {
      expect(r.development).toBe(true)
      expect(r.key.counter).toBe(0)
      expect(r.key.app_id_hash).toBe(createHash("sha256").update(fixture.appId).digest("base64url"))
    }
  })

  it("refuses another app id, other client data, a development key in production, and another root", () => {
    expect(verifyAttestationWithRoot(fixture.root, rootSha, { ...base, appId: "7WLXT3NR37.other.app" })).toEqual({ ok: false, reason: "app id" })
    expect(verifyAttestationWithRoot(fixture.root, rootSha, { ...base, clientData: new TextEncoder().encode("other") })).toEqual({ ok: false, reason: "nonce" })
    expect(verifyAttestationWithRoot(fixture.root, rootSha, { ...base, allowDevelopment: false })).toEqual({ ok: false, reason: "aaguid" })
    expect(verifyAttestationWithRoot(fixture.root, rootSha, { ...base, keyId: Buffer.alloc(32).toString("base64") })).toEqual({ ok: false, reason: "key id" })
    expect(verifyAttestation(base)).toEqual({ ok: false, reason: "chain" })
    expect(verifyAttestationWithRoot(fixture.root, "00", base)).toEqual({ ok: false, reason: "root" })
    expect(verifyAttestationWithRoot(fixture.root, rootSha, { ...base, attestation: "AAAA" })).toEqual({ ok: false, reason: "malformed" })
  })

  it("pins Apple's published App Attestation root", () => {
    expect(createHash("sha256").update(new X509Certificate(APPLE_APP_ATTESTATION_ROOT).raw).digest("hex")).toBe("1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932")
  })
})
