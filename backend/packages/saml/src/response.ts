import { DOMParser } from "@xmldom/xmldom"
import { elementChildren, verifyEnvelopedSignature } from "./dsig.ts"
import { parseCertificate, type IdpKey } from "./x509.ts"

/**
 * Validates a SAML 2.0 Response from the HTTP-POST binding for an SP-initiated
 * sign-in (spec/enterprise.md 3.3 step 3). Data is read only from the one
 * signed Assertion node whose signature was checked, so a wrapped or injected
 * assertion is never read. Modeled on better-auth's SSO plugin checks
 * (single assertion, assertion-level signature, XSW patterns), with our own
 * canonicalization and signature verification instead of samlify.
 */
export const SAMLP = "urn:oasis:names:tc:SAML:2.0:protocol"
export const SAML = "urn:oasis:names:tc:SAML:2.0:assertion"
const SUCCESS = "urn:oasis:names:tc:SAML:2.0:status:Success"
const BEARER = "urn:oasis:names:tc:SAML:2.0:cm:bearer"
const MAX_BYTES = 256 * 1024

export interface SamlExpectations {
  /** The IdP's entity id (Issuer of the assertion). */
  readonly idpEntityId: string
  /** Our SP entity id for this connection (Audience). */
  readonly spEntityId: string
  /** Our assertion consumer service URL (Destination, Recipient). */
  readonly acsUrl: string
  /** The AuthnRequest ID we sent; IdP-initiated responses (no request) are refused. */
  readonly requestId: string
  /** The IdP signing certificates configured for the connection (PEM or base64 DER), at most two during rotation. */
  readonly certificates: ReadonlyArray<string>
  readonly now: number
  readonly clockSkewMs?: number
}

export interface SamlIdentity {
  readonly nameId: string
  readonly nameIdFormat: string | null
  readonly attributes: Readonly<Record<string, ReadonlyArray<string>>>
  readonly sessionIndex: string | null
  /** For the caller's replay cache: refuse this assertion ID until this time. */
  readonly assertionId: string
  readonly replayUntil: number
}

export type SamlResult = { ok: true; identity: SamlIdentity } | { ok: false; code: string; message: string }

type El = any

const fail = (code: string, message: string): SamlResult => ({ ok: false, code, message })
const child = (el: El, ns: string, local: string): Array<El> => elementChildren(el).filter((c) => c.namespaceURI === ns && c.localName === local)
const one = (el: El, ns: string, local: string): El | undefined => {
  const hits = child(el, ns, local)
  return hits.length === 1 ? hits[0] : undefined
}
const allElements = (doc: El): Array<El> => Array.from(doc.getElementsByTagName("*") as ArrayLike<El>)
/**
 * The text of an element that must hold only text. A comment or element
 * inside (comment injection: "admin@acme.com<!---->.evil.com" canonicalizes,
 * and so signs, as one string) is refused rather than read partially.
 */
const textOnly = (el: El): string | undefined => {
  let s = ""
  for (const n of Array.from(el.childNodes as ArrayLike<El>)) {
    if (n.nodeType !== 3 && n.nodeType !== 4) return undefined
    s += n.data
  }
  return s
}
const time = (v: string | null | undefined): number | undefined => {
  if (!v) return undefined
  const t = Date.parse(v)
  return Number.isNaN(t) ? undefined : t
}

export const validateSamlResponse = async (base64Response: string, ex: SamlExpectations): Promise<SamlResult> => {
  const skew = ex.clockSkewMs ?? 120_000
  let xml: string
  try {
    const bytes = Uint8Array.from(atob(base64Response.replace(/\s+/g, "")), (c) => c.charCodeAt(0))
    if (bytes.length > MAX_BYTES) return fail("saml.invalid", "the SAML response is too large")
    xml = new TextDecoder("utf-8", { fatal: true }).decode(bytes)
  } catch {
    return fail("saml.invalid", "the SAML response is not base64-encoded UTF-8")
  }
  // No DTDs at all: no entity expansion, no external entities.
  if (/<!DOCTYPE|<!ENTITY/i.test(xml)) return fail("saml.invalid", "the SAML response must not contain a DTD")

  let doc: El
  try {
    doc = new DOMParser({
      onError: (level: string, message: string) => {
        if (level !== "warning") throw new Error(message)
      }
    }).parseFromString(xml, "text/xml")
  } catch {
    return fail("saml.invalid", "the SAML response is not well-formed XML")
  }
  const root = doc.documentElement
  if (!root || root.namespaceURI !== SAMLP || root.localName !== "Response") return fail("saml.invalid", "not a SAML Response")
  if (root.getAttribute("Version") !== "2.0") return fail("saml.invalid", "only SAML 2.0 is accepted")

  // Exactly one assertion in the whole document, plaintext, a direct child of the Response.
  // Counted by local name in any namespace, so no wrapper (XSW 3-8) hides a second one.
  const assertions = allElements(doc).filter((e) => e.localName === "Assertion" || e.localName === "EncryptedAssertion")
  if (assertions.length !== 1) return fail("saml.invalid", `the SAML response must contain exactly one assertion (found ${assertions.length})`)
  const assertion = assertions[0]
  if (assertion.localName === "EncryptedAssertion") return fail("saml.invalid", "encrypted assertions are not supported yet")
  if (assertion.namespaceURI !== SAML || assertion.parentNode !== root) return fail("saml.invalid", "the assertion must be a direct child of the Response")

  // Its ID must be unique in the document, or a reference could point at a different node.
  const id = assertion.getAttribute("ID")
  if (!id) return fail("saml.invalid", "the assertion has no ID")
  const sameId = allElements(doc).filter((e) => ["ID", "Id", "id"].some((a) => e.getAttribute(a) === id))
  if (sameId.length !== 1) return fail("saml.invalid", "duplicate IDs in the SAML response")

  const status = one(root, SAMLP, "Status")
  const statusCode = status ? one(status, SAMLP, "StatusCode") : undefined
  if (!statusCode || statusCode.getAttribute("Value") !== SUCCESS) return fail("saml.idp_error", "the identity provider did not report success")
  const destination = root.getAttribute("Destination")
  if (destination && destination !== ex.acsUrl) return fail("saml.invalid", "the response is addressed to another service")
  const responseTo = root.getAttribute("InResponseTo")
  if (responseTo && responseTo !== ex.requestId) return fail("saml.invalid", "the response answers another sign-in")

  let keys: Array<IdpKey>
  try {
    keys = ex.certificates.map(parseCertificate)
  } catch (e) {
    return fail("saml.not_configured", `the connection's certificate is unusable: ${e instanceof Error ? e.message : String(e)}`)
  }
  const signature = await verifyEnvelopedSignature(assertion, id, keys)
  if (!signature.ok) return fail("saml.signature_invalid", signature.reason)

  // From here on, read only from `assertion`, the node that was verified.
  const issuer = one(assertion, SAML, "Issuer")
  if (!issuer || textOnly(issuer)?.trim() !== ex.idpEntityId) return fail("saml.invalid", "the assertion is from another identity provider")

  const conditions = one(assertion, SAML, "Conditions")
  if (!conditions) return fail("saml.invalid", "the assertion has no conditions")
  const notBefore = time(conditions.getAttribute("NotBefore"))
  const notOnOrAfter = time(conditions.getAttribute("NotOnOrAfter"))
  if (notOnOrAfter === undefined) return fail("saml.invalid", "the assertion has no expiry")
  if (notBefore !== undefined && notBefore > ex.now + skew) return fail("saml.expired", "the assertion is not valid yet")
  if (notOnOrAfter <= ex.now - skew) return fail("saml.expired", "the assertion has expired")
  // Every AudienceRestriction must name us (multiple restrictions are a conjunction).
  const restrictions = child(conditions, SAML, "AudienceRestriction")
  if (restrictions.length === 0) return fail("saml.invalid", "the assertion has no audience restriction")
  for (const r of restrictions) {
    if (!child(r, SAML, "Audience").some((a) => textOnly(a)?.trim() === ex.spEntityId)) return fail("saml.invalid", "the assertion is meant for another service")
  }

  const subject = one(assertion, SAML, "Subject")
  const nameIdEl = subject ? one(subject, SAML, "NameID") : undefined
  const nameId = nameIdEl ? textOnly(nameIdEl)?.trim() : undefined
  if (!nameIdEl || !nameId) return fail("saml.invalid", "the assertion has no usable NameID (comments or markup inside it are refused)")
  const confirmed = child(subject, SAML, "SubjectConfirmation").some((sc) => {
    if (sc.getAttribute("Method") !== BEARER) return false
    const data = one(sc, SAML, "SubjectConfirmationData")
    if (!data || data.getAttribute("NotBefore")) return false
    const until = time(data.getAttribute("NotOnOrAfter"))
    return data.getAttribute("Recipient") === ex.acsUrl && data.getAttribute("InResponseTo") === ex.requestId && until !== undefined && until > ex.now - skew
  })
  if (!confirmed) return fail("saml.invalid", "no bearer confirmation for this sign-in (recipient, request or expiry mismatch)")

  const authn = one(assertion, SAML, "AuthnStatement")
  if (!authn) return fail("saml.invalid", "the assertion has no authentication statement")

  const attributes: Record<string, Array<string>> = {}
  for (const statement of child(assertion, SAML, "AttributeStatement")) {
    for (const attr of child(statement, SAML, "Attribute")) {
      const name = attr.getAttribute("Name")
      if (!name) continue
      const values: Array<string> = []
      for (const v of child(attr, SAML, "AttributeValue")) {
        const t = textOnly(v)
        if (t === undefined) return fail("saml.invalid", `attribute ${name} has markup or comments in a value`)
        values.push(t.trim())
      }
      attributes[name] = [...(attributes[name] ?? []), ...values]
    }
  }
  const confirmationUntil = child(subject, SAML, "SubjectConfirmation")
    .map((sc: El) => time(one(sc, SAML, "SubjectConfirmationData")?.getAttribute("NotOnOrAfter")))
    .filter((t: number | undefined): t is number => t !== undefined)
  return {
    ok: true,
    identity: {
      nameId,
      nameIdFormat: nameIdEl.getAttribute("Format") || null,
      attributes,
      sessionIndex: authn.getAttribute("SessionIndex") || null,
      assertionId: id,
      replayUntil: Math.max(notOnOrAfter, ...confirmationUntil) + skew
    }
  }
}
