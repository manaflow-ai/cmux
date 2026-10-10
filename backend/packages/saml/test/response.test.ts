import { readFileSync } from "node:fs"
import { createSign } from "node:crypto"
import { DOMParser } from "@xmldom/xmldom"
import { ExclusiveCanonicalization, SignedXml } from "xml-crypto"
import { describe, expect, it } from "vitest"
import { validateSamlResponse, type SamlExpectations } from "../src/index.ts"

/**
 * SAML response validation against an independent signer (xml-crypto) and the
 * public SAML attack patterns: XML signature wrapping (Somorovsky et al.,
 * "On Breaking SAML", 2012, XSW1-8), comment injection (Duo Labs, 2018,
 * CVE-2017-11427 family), signature stripping and re-signing, replayed or
 * misaddressed assertions, and DTD entity attacks.
 */
const fx = (f: string) => readFileSync(new URL(`./fixtures/${f}`, import.meta.url), "utf8")
const IDP_KEY = fx("idp-key.pem")
const IDP_CERT = fx("idp-cert.pem")
const OTHER_KEY = fx("other-key.pem")
const EC_KEY = fx("ec-key.pem")
const EC_CERT = fx("ec-cert.pem")

const NOW = Date.parse("2026-10-02T12:00:00Z")
const iso = (ms: number) => new Date(ms).toISOString()
const EX: SamlExpectations = {
  idpEntityId: "https://idp.acme.dev/saml",
  spEntityId: "https://cloud-api.cmux.dev/sso/saml/ssoc_00000000000000000001",
  acsUrl: "https://cloud-api.cmux.dev/v1/sso/saml/ssoc_00000000000000000001/acs",
  requestId: "_req_123",
  certificates: [IDP_CERT],
  now: NOW
}

interface Shape {
  nameId?: string
  audience?: string
  recipient?: string
  inResponseTo?: string
  notOnOrAfter?: number
  issuer?: string
  status?: string
  destination?: string
}
const assertionXml = (s: Shape = {}, id = "_a1") => `<saml:Assertion xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ID="${id}" Version="2.0" IssueInstant="${iso(NOW)}">
<saml:Issuer>${s.issuer ?? EX.idpEntityId}</saml:Issuer>
<saml:Subject><saml:NameID Format="urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress">${s.nameId ?? "alice@acme.dev"}</saml:NameID>
<saml:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer"><saml:SubjectConfirmationData Recipient="${s.recipient ?? EX.acsUrl}" InResponseTo="${s.inResponseTo ?? EX.requestId}" NotOnOrAfter="${iso(s.notOnOrAfter ?? NOW + 300_000)}"/></saml:SubjectConfirmation></saml:Subject>
<saml:Conditions NotBefore="${iso(NOW - 60_000)}" NotOnOrAfter="${iso(s.notOnOrAfter ?? NOW + 300_000)}"><saml:AudienceRestriction><saml:Audience>${s.audience ?? EX.spEntityId}</saml:Audience></saml:AudienceRestriction></saml:Conditions>
<saml:AuthnStatement AuthnInstant="${iso(NOW)}" SessionIndex="_s1"/>
<saml:AttributeStatement><saml:Attribute Name="groups"><saml:AttributeValue>eng</saml:AttributeValue><saml:AttributeValue>admins</saml:AttributeValue></saml:Attribute></saml:AttributeStatement>
</saml:Assertion>`
const responseXml = (inner: string, s: Shape = {}) => `<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" ID="_r1" Version="2.0" IssueInstant="${iso(NOW)}" Destination="${s.destination ?? EX.acsUrl}" InResponseTo="${EX.requestId}">
<saml:Issuer xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion">${EX.idpEntityId}</saml:Issuer>
<samlp:Status><samlp:StatusCode Value="${s.status ?? "urn:oasis:names:tc:SAML:2.0:status:Success"}"/></samlp:Status>
${inner}
</samlp:Response>`

/** Signs the assertion (enveloped, exclusive c14n, placed after its Issuer) with xml-crypto. */
const sign = (xml: string, key = IDP_KEY, alg = "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256", id = "_a1") => {
  const sig = new SignedXml({ privateKey: key, canonicalizationAlgorithm: "http://www.w3.org/2001/10/xml-exc-c14n#", signatureAlgorithm: alg })
  sig.addReference({
    xpath: `//*[local-name(.)='Assertion' and @ID='${id}']`,
    transforms: ["http://www.w3.org/2000/09/xmldsig#enveloped-signature", "http://www.w3.org/2001/10/xml-exc-c14n#"],
    digestAlgorithm: "http://www.w3.org/2001/04/xmlenc#sha256"
  })
  sig.computeSignature(xml, { location: { reference: `//*[local-name(.)='Assertion' and @ID='${id}']/*[local-name(.)='Issuer']`, action: "after" } })
  return sig.getSignedXml()
}
const b64 = (s: string) => Buffer.from(s, "utf8").toString("base64")
const signedAssertion = (s: Shape = {}) => {
  // Sign the assertion standalone, then place it in a response (the signature covers the assertion only).
  const signed = sign(assertionXml(s))
  return signed
}
const validate = (xml: string, ex: Partial<SamlExpectations> = {}) => validateSamlResponse(b64(xml), { ...EX, ...ex })

describe("SAML response validation", () => {
  it("accepts a correctly signed response and reads the identity from the signed assertion", async () => {
    const r = await validate(responseXml(signedAssertion()))
    expect(r).toMatchObject({ ok: true, identity: { nameId: "alice@acme.dev", sessionIndex: "_s1", assertionId: "_a1", attributes: { groups: ["eng", "admins"] } } })
  })

  it("accepts ECDSA P-256 and a second configured certificate (rotation)", async () => {
    // xml-crypto cannot sign with ECDSA: take its RSA output, switch the method, and sign SignedInfo
    // (canonicalized by xml-crypto's own exclusive canonicalizer) with Node's ECDSA (IEEE P1363, r||s).
    const rsa = sign(assertionXml()).replace("http://www.w3.org/2001/04/xmldsig-more#rsa-sha256", "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256")
    const doc = new DOMParser().parseFromString(rsa, "text/xml")
    const signedInfo = doc.getElementsByTagName("SignedInfo")[0]!
    const canonical = new ExclusiveCanonicalization().process(signedInfo as never, {}) as unknown as string
    const value = createSign("sha256").update(canonical).sign({ key: EC_KEY, dsaEncoding: "ieee-p1363" }).toString("base64")
    const signed = rsa.replace(/<SignatureValue>[^<]*<\/SignatureValue>/, `<SignatureValue>${value}</SignatureValue>`)
    expect((await validate(responseXml(signed), { certificates: [IDP_CERT, EC_CERT] })).ok).toBe(true)
  })

  describe("signature attacks", () => {
    it("refuses an unsigned assertion and a stripped signature", async () => {
      expect(await validate(responseXml(assertionXml()))).toMatchObject({ ok: false, code: "saml.signature_invalid" })
      const stripped = signedAssertion().replace(/<Signature[\s\S]*<\/Signature>/, "")
      expect(await validate(responseXml(stripped))).toMatchObject({ ok: false, code: "saml.signature_invalid" })
    })

    it("refuses an assertion signed by another key (attacker re-signing)", async () => {
      expect(await validate(responseXml(sign(assertionXml(), OTHER_KEY)))).toMatchObject({ ok: false, code: "saml.signature_invalid" })
    })

    it("refuses a changed NameID after signing (digest)", async () => {
      const tampered = signedAssertion().replace("alice@acme.dev", "mallory@acme.dev")
      expect(await validate(responseXml(tampered))).toMatchObject({ ok: false, code: "saml.signature_invalid" })
    })

    it("refuses comment injection in the NameID (signed text differs from naive reading)", async () => {
      // The IdP signs "admin@acme.dev.evil.com" for an attacker-registered account; a comment splits it.
      const signed = sign(assertionXml({ nameId: "admin@acme.dev<!---->.evil.com" }))
      expect(await validate(responseXml(signed))).toMatchObject({ ok: false, code: "saml.invalid" })
    })

    it("refuses RSA-SHA1 and other weak or unknown algorithms", async () => {
      const weak = sign(assertionXml(), IDP_KEY, "http://www.w3.org/2000/09/xmldsig#rsa-sha1")
      expect(await validate(responseXml(weak))).toMatchObject({ ok: false, code: "saml.signature_invalid" })
    })
  })

  describe("XML signature wrapping (XSW)", () => {
    const evil = assertionXml({ nameId: "mallory@acme.dev" }, "_evil")
    it("XSW3: an unsigned evil assertion before the signed one", async () => {
      expect(await validate(responseXml(evil + signedAssertion()))).toMatchObject({ ok: false, code: "saml.invalid" })
    })
    it("XSW4: the signed assertion wrapped inside the evil one", async () => {
      const wrapped = evil.replace("</saml:Assertion>", `${signedAssertion()}</saml:Assertion>`)
      expect(await validate(responseXml(wrapped))).toMatchObject({ ok: false, code: "saml.invalid" })
    })
    it("XSW5/6: an evil assertion reusing the signed assertion's ID", async () => {
      const sameId = assertionXml({ nameId: "mallory@acme.dev" }, "_a1")
      expect(await validate(responseXml(sameId + signedAssertion()))).toMatchObject({ ok: false, code: "saml.invalid" })
    })
    it("XSW7: the signed assertion hidden in Extensions", async () => {
      const ext = `<samlp:Extensions>${signedAssertion()}</samlp:Extensions>${evil}`
      expect(await validate(responseXml(ext))).toMatchObject({ ok: false, code: "saml.invalid" })
    })
    it("XSW8: the signed assertion hidden in the signature's Object", async () => {
      const signed = signedAssertion()
      const hidden = signed.replace("</Signature>", `<Object>${signed.replace(/ ID="_a1"/, ' ID="_a1copy"')}</Object></Signature>`)
      expect(await validate(responseXml(hidden.replace("alice@acme.dev", "mallory@acme.dev")))).toMatchObject({ ok: false })
    })
    it("refuses an element with the assertion's ID elsewhere (reference confusion)", async () => {
      const decoy = `<samlp:Extensions><x ID="_a1"/></samlp:Extensions>${signedAssertion()}`
      expect(await validate(responseXml(decoy))).toMatchObject({ ok: false, code: "saml.invalid" })
    })
  })

  describe("binding and replay checks", () => {
    const cases: Array<[string, Shape, Partial<SamlExpectations>?]> = [
      ["wrong audience", { audience: "https://someone-else.example/sp" }],
      ["wrong recipient", { recipient: "https://evil.example/acs" }],
      ["answers another request", { inResponseTo: "_other_req" }],
      ["expired", { notOnOrAfter: NOW - 10 * 60_000 }],
      ["another issuer", { issuer: "https://evil.example/idp" }],
      ["IdP reported failure", { status: "urn:oasis:names:tc:SAML:2.0:status:Responder" }],
      ["addressed to another service", { destination: "https://evil.example/acs" }]
    ]
    for (const [name, shape] of cases) {
      it(`refuses: ${name}`, async () => {
        const r = await validate(responseXml(signedAssertion(shape), shape))
        expect(r.ok).toBe(false)
      })
    }
    it("returns the assertion ID and a replay window for the caller's replay cache", async () => {
      const r = await validate(responseXml(signedAssertion()))
      expect(r.ok && r.identity.replayUntil).toBeGreaterThan(NOW + 300_000)
    })
  })

  describe("parser attacks", () => {
    it("refuses any DTD (entity expansion, external entities)", async () => {
      const bomb = `<?xml version="1.0"?><!DOCTYPE r [<!ENTITY a "aaaa"><!ENTITY b "&a;&a;&a;&a;">]>${responseXml(signedAssertion())}`
      expect(await validate(bomb)).toMatchObject({ ok: false, code: "saml.invalid" })
    })
    it("refuses encrypted assertions (not supported yet) and malformed XML", async () => {
      expect(await validate(responseXml(`<saml:EncryptedAssertion xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion"/>`))).toMatchObject({ ok: false })
      expect(await validate("<samlp:Response")).toMatchObject({ ok: false, code: "saml.invalid" })
      expect(await validateSamlResponse("%%%not-base64", EX)).toMatchObject({ ok: false, code: "saml.invalid" })
    })
  })
})
