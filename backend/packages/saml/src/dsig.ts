import { excC14n } from "./c14n.ts"
import type { IdpKey } from "./x509.ts"

/**
 * Verifies the enveloped XML signature of one element (the SAML Assertion)
 * against the IdP's configured keys. Strict profile, so signature-wrapping
 * tricks have nowhere to go:
 * - exactly one ds:Signature, a direct child of the element;
 * - exactly one Reference, whose URI is "#" + the element's own ID;
 * - transforms exactly enveloped-signature then exclusive c14n;
 * - exclusive c14n for SignedInfo; SHA-256/512 digests; RSA or ECDSA with SHA-256/512;
 * - the signature is checked over the canonical SignedInfo, and the digest
 *   over the canonical element itself (the very node the caller then reads).
 * KeyInfo in the document is ignored: only the configured keys count.
 */
export const DSIG = "http://www.w3.org/2000/09/xmldsig#"
const EXC_C14N = "http://www.w3.org/2001/10/xml-exc-c14n#"
const ENVELOPED = "http://www.w3.org/2000/09/xmldsig#enveloped-signature"
const DIGESTS: Record<string, "SHA-256" | "SHA-512"> = {
  "http://www.w3.org/2001/04/xmlenc#sha256": "SHA-256",
  "http://www.w3.org/2001/04/xmlenc#sha512": "SHA-512"
}
const SIGNATURES: Record<string, { kind: IdpKey["kind"]; hash: "SHA-256" | "SHA-512" }> = {
  "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256": { kind: "rsa", hash: "SHA-256" },
  "http://www.w3.org/2001/04/xmldsig-more#rsa-sha512": { kind: "rsa", hash: "SHA-512" },
  "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256": { kind: "ec-p256", hash: "SHA-256" }
}
const INCLUSIVE_NS = "http://www.w3.org/2001/10/xml-exc-c14n#"

// Loose DOM types: @xmldom/xmldom's nodes.
type El = any

export const elementChildren = (el: El): Array<El> => Array.from(el.childNodes as ArrayLike<El>).filter((n) => n.nodeType === 1)
const only = (el: El, ns: string, local: string): El | undefined => {
  const hits = elementChildren(el).filter((c) => c.namespaceURI === ns && c.localName === local)
  return hits.length === 1 ? hits[0] : undefined
}
const b64 = (s: string) => Uint8Array.from(atob(s.replace(/\s+/g, "")), (c) => c.charCodeAt(0))
const text = (el: El) => Array.from(el.childNodes as ArrayLike<El>).map((n) => (n.nodeType === 3 || n.nodeType === 4 ? n.data : "")).join("")
const prefixList = (method: El): Array<string> => {
  const inc = elementChildren(method).find((c) => c.namespaceURI === INCLUSIVE_NS && c.localName === "InclusiveNamespaces")
  return inc ? String(inc.getAttribute("PrefixList") ?? "").split(/\s+/).filter(Boolean) : []
}

export type SignatureCheck = { ok: true } | { ok: false; reason: string }

export const verifyEnvelopedSignature = async (element: El, id: string, keys: ReadonlyArray<IdpKey>): Promise<SignatureCheck> => {
  const fail = (reason: string): SignatureCheck => ({ ok: false, reason })
  const signature = only(element, DSIG, "Signature")
  if (!signature) return fail("the assertion must carry exactly one signature as its direct child")
  const signedInfo = only(signature, DSIG, "SignedInfo")
  const signatureValue = only(signature, DSIG, "SignatureValue")
  if (!signedInfo || !signatureValue) return fail("malformed signature")
  const canon = only(signedInfo, DSIG, "CanonicalizationMethod")
  const method = only(signedInfo, DSIG, "SignatureMethod")
  const refs = elementChildren(signedInfo).filter((c) => c.namespaceURI === DSIG && c.localName === "Reference")
  if (!canon || !method || refs.length !== 1) return fail("the signature must have exactly one reference")
  if (canon.getAttribute("Algorithm") !== EXC_C14N) return fail("only exclusive canonicalization is accepted")
  const alg = SIGNATURES[String(method.getAttribute("Algorithm"))]
  if (!alg) return fail("signature algorithm not accepted (RSA or ECDSA with SHA-256/512)")
  const ref = refs[0]
  if (ref.getAttribute("URI") !== `#${id}`) return fail("the signature does not reference this assertion")
  const transforms = only(ref, DSIG, "Transforms")
  const list = transforms ? elementChildren(transforms).filter((c) => c.namespaceURI === DSIG && c.localName === "Transform") : []
  if (!transforms || elementChildren(transforms).length !== list.length || list.length !== 2) return fail("transforms must be enveloped-signature and exclusive c14n")
  if (list[0].getAttribute("Algorithm") !== ENVELOPED || list[1].getAttribute("Algorithm") !== EXC_C14N) return fail("transforms must be enveloped-signature and exclusive c14n")
  const digestMethod = only(ref, DSIG, "DigestMethod")
  const digestValue = only(ref, DSIG, "DigestValue")
  const digestAlg = digestMethod ? DIGESTS[String(digestMethod.getAttribute("Algorithm"))] : undefined
  if (!digestAlg || !digestValue) return fail("digest algorithm not accepted (SHA-256/512)")

  const enc = new TextEncoder()
  const canonical = excC14n(element, { skip: signature, inclusivePrefixes: prefixList(list[1]) })
  const digest = new Uint8Array(await crypto.subtle.digest(digestAlg, enc.encode(canonical)))
  const expected = b64(text(digestValue))
  if (digest.length !== expected.length || digest.some((b, i) => b !== expected[i])) return fail("the assertion's digest does not match (it was changed after signing)")

  const signedBytes = enc.encode(excC14n(signedInfo, { inclusivePrefixes: prefixList(canon) }))
  const sig = b64(text(signatureValue))
  for (const key of keys.filter((k) => k.kind === alg.kind)) {
    const params = key.kind === "rsa" ? { name: "RSASSA-PKCS1-v1_5", hash: alg.hash } : { name: "ECDSA", namedCurve: "P-256" }
    const cryptoKey = await crypto.subtle.importKey("spki", key.spki as Uint8Array<ArrayBuffer>, params, false, ["verify"])
    const verifyParams = key.kind === "rsa" ? { name: "RSASSA-PKCS1-v1_5" } : { name: "ECDSA", hash: alg.hash }
    if (await crypto.subtle.verify(verifyParams, cryptoKey, sig, signedBytes)) return { ok: true }
  }
  return fail("the signature is not from the configured identity provider key")
}
