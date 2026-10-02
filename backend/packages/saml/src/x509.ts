/**
 * The public key of an X.509 certificate (the IdP's signing certificate an
 * admin configured), read with a minimal DER walk: Certificate ->
 * tbsCertificate -> subjectPublicKeyInfo. Only the key is used; the
 * certificate's validity dates and chain are not (SAML metadata pins the key).
 */
export type IdpKey = { readonly kind: "rsa" | "ec-p256"; readonly spki: Uint8Array }

const OID_RSA = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]
const OID_EC = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]
const OID_P256 = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]

const tlv = (b: Uint8Array, at: number) => {
  if (at + 2 > b.length) throw new Error("x509: truncated")
  const tag = b[at]!
  let len = b[at + 1]!
  let head = 2
  if (len & 0x80) {
    const n = len & 0x7f
    if (n === 0 || n > 4) throw new Error("x509: unsupported length")
    len = 0
    for (let i = 0; i < n; i++) len = len * 256 + b[at + 2 + i]!
    head += n
  }
  const start = at + head
  const end = start + len
  if (end > b.length) throw new Error("x509: truncated")
  return { tag, start, end }
}

const children = (b: Uint8Array, start: number, end: number) => {
  const out: Array<ReturnType<typeof tlv>> = []
  for (let at = start; at < end; ) {
    const t = tlv(b, at)
    out.push(t)
    at = t.end
  }
  return out
}

const contains = (hay: Uint8Array, needle: ReadonlyArray<number>) => {
  outer: for (let i = 0; i + needle.length <= hay.length; i++) {
    for (let j = 0; j < needle.length; j++) if (hay[i + j] !== needle[j]) continue outer
    return true
  }
  return false
}

/** A PEM certificate or its bare base64 body (as SAML metadata carries it). */
export const parseCertificate = (cert: string): IdpKey => {
  const body = cert.replace(/-----(BEGIN|END) CERTIFICATE-----/g, "").replace(/\s+/g, "")
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0))
  const certificate = tlv(der, 0)
  if (certificate.tag !== 0x30) throw new Error("x509: not a certificate")
  const tbs = children(der, certificate.start, certificate.end)[0]
  if (!tbs || tbs.tag !== 0x30) throw new Error("x509: no tbsCertificate")
  const fields = children(der, tbs.start, tbs.end)
  // [0] version is optional; then serial, signature, issuer, validity, subject, subjectPublicKeyInfo.
  const spkiField = fields[fields[0]?.tag === 0xa0 ? 6 : 5]
  if (!spkiField || spkiField.tag !== 0x30) throw new Error("x509: no subjectPublicKeyInfo")
  const headerStart = (() => {
    // Back up to the TLV header of the SPKI SEQUENCE.
    for (let at = tbs.start; at < tbs.end; ) {
      const t = tlv(der, at)
      if (t.start === spkiField.start) return at
      at = t.end
    }
    throw new Error("x509: spki not found")
  })()
  const spki = der.slice(headerStart, spkiField.end)
  const algorithm = children(der, spkiField.start, spkiField.end)[0]!
  const alg = der.slice(algorithm.start, algorithm.end)
  if (contains(alg, OID_RSA)) return { kind: "rsa", spki }
  if (contains(alg, OID_EC) && contains(alg, OID_P256)) return { kind: "ec-p256", spki }
  throw new Error("x509: only RSA and EC P-256 signing keys are supported")
}
