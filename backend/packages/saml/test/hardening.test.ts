import { describe, expect, it } from "vitest"
import { validateSamlResponse } from "../src/index.ts"

/** Unauthenticated inputs must fail fast and typed (review of 652ba898964, P1/P2/P3). */
const EX = { idpEntityId: "i", spEntityId: "s", acsUrl: "https://a/acs", requestId: "r", certificates: [], now: Date.parse("2026-10-02T12:00:00Z") }
const b64 = (s: string) => Buffer.from(s, "utf8").toString("base64")
const skeleton = (body: string, digest = "AAAA") => `<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" Version="2.0"><samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status><s:Assertion xmlns:s="urn:oasis:names:tc:SAML:2.0:assertion" ID="x"><ds:Signature xmlns:ds="http://www.w3.org/2000/09/xmldsig#"><ds:SignedInfo><ds:CanonicalizationMethod Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/><ds:SignatureMethod Algorithm="http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"/><ds:Reference URI="#x"><ds:Transforms><ds:Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/><ds:Transform Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/></ds:Transforms><ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/><ds:DigestValue>${digest}</ds:DigestValue></ds:Reference></ds:SignedInfo><ds:SignatureValue>AAAA</ds:SignatureValue></ds:Signature>${body}</s:Assertion></samlp:Response>`

describe("SAML validator hardening", () => {
  it("refuses deep nesting fast (no O(depth^2) canonicalization, no stack overflow)", async () => {
    const n = 3000
    const started = performance.now()
    const r = await validateSamlResponse(b64(skeleton("<a>".repeat(n) + "</a>".repeat(n))), EX)
    expect(r).toMatchObject({ ok: false, code: "saml.invalid" })
    expect(performance.now() - started).toBeLessThan(1500)
  })
  it("maps malformed base64 in the signature to a typed failure (no exception)", async () => {
    await expect(validateSamlResponse(b64(skeleton("", "!!!")), EX)).resolves.toMatchObject({ ok: false, code: "saml.signature_invalid" })
  })
})
