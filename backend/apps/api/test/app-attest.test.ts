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

  it("refuses another app id, other client data, a development key in production, and another root", () => {
    expect(verifyAttestationWithRoot(fixture.root, rootSha, { ...base, appId: "7WLXT3NR37.other.app" })).toEqual({ ok: false, reason: "app id" })
    expect(verifyAttestationWithRoot(fixture.root, rootSha, { ...base, clientData: new TextEncoder().encode("other") })).toEqual({ ok: false, reason: "nonce" })
    expect(verifyAttestationWithRoot(fixture.root, rootSha, { ...base, allowDevelopment: false })).toEqual({ ok: false, reason: "aaguid" })
    expect(verifyAttestationWithRoot(fixture.root, rootSha, { ...base, keyId: Buffer.alloc(32).toString("base64") })).toEqual({ ok: false, reason: "key id" })
    expect(verifyAttestation(base)).toEqual({ ok: false, reason: "chain" })
    expect(verifyAttestationWithRoot(fixture.root, "00", base)).toEqual({ ok: false, reason: "root" })
    expect(verifyAttestationWithRoot(fixture.root, rootSha, { ...base, attestation: "AAAA" })).toEqual({ ok: false, reason: "malformed" })
  })

})
