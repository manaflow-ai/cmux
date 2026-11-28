import { createHash, X509Certificate } from "node:crypto"

/**
 * App Attest attestation check (Apple, "Validating apps that connect to your server"), run once
 * when an iPhone registers its presence key (home-messaging.md section 21):
 *
 * 1. x5c = [credCert, intermediate] chains to the pinned Apple App Attestation Root CA, and each
 *    certificate is within its validity window.
 * 2. nonce = sha256(authData || sha256(clientData)) equals the credCert extension
 *    1.2.840.113635.100.8.2.
 * 3. sha256(credCert public key, uncompressed point) equals the key id, and so does the
 *    credential id in authData.
 * 4. authData: rpIdHash = sha256("<Team ID>.<bundle id>"), counter 0, AAGUID appattest
 *    (production) or appattestdevelop (development builds, accepted only when allowed).
 *
 * Returns the attested key (JWK) for UserDO to store; later assertions verify against it.
 */

/** Apple App Attestation Root CA, from https://www.apple.com/certificateauthority/ (SHA-256 1CB9823B...C932). */
export const APPLE_APP_ATTESTATION_ROOT = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`
const ROOT_SHA256 = "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932"

const AAGUID_PROD = new TextEncoder().encode("appattest\0\0\0\0\0\0\0")
const AAGUID_DEV = new TextEncoder().encode("appattestdevelop")
/** DER of OID 1.2.840.113635.100.8.2 (tag, length, value). */
const NONCE_OID = Uint8Array.from([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x08, 0x02])

export interface AttestedKey {
  readonly jwk: { kty: "EC"; crv: "P-256"; x: string; y: string }
  readonly app_id_hash: string
  readonly counter: number
}
export type AttestResult = { readonly ok: true; readonly key: AttestedKey; readonly development: boolean } | { readonly ok: false; readonly reason: string }

const sha256 = (...parts: Array<Uint8Array>) => {
  const h = createHash("sha256")
  for (const p of parts) h.update(p)
  return new Uint8Array(h.digest())
}
const same = (a: Uint8Array, b: Uint8Array) => a.length === b.length && a.every((x, i) => x === b[i])
const b64 = (s: string) => new Uint8Array(Buffer.from(s, /[-_]/.test(s) ? "base64url" : "base64"))

/** Minimal CBOR decoder for the attestation object: maps, arrays, byte and text strings, unsigned ints. */
const decodeCbor = (buf: Uint8Array): unknown => {
  let i = 0
  const len = (info: number): number => {
    if (info < 24) return info
    const n = info === 24 ? 1 : info === 25 ? 2 : info === 26 ? 4 : 0
    if (!n || i + n > buf.length) throw new Error("cbor length")
    let v = 0
    for (let k = 0; k < n; k++) v = v * 256 + buf[i++]!
    return v
  }
  const item = (depth: number): unknown => {
    if (depth > 8 || i >= buf.length) throw new Error("cbor depth")
    const b = buf[i++]!
    const major = b >> 5
    const n = len(b & 31)
    switch (major) {
      case 0:
        return n
      case 2:
      case 3: {
        if (i + n > buf.length) throw new Error("cbor bytes")
        const v = buf.subarray(i, i + n)
        i += n
        return major === 2 ? v : new TextDecoder().decode(v)
      }
      case 4:
        return Array.from({ length: n }, () => item(depth + 1))
      case 5: {
        const m = new Map<unknown, unknown>()
        for (let k = 0; k < n; k++) m.set(item(depth + 1), item(depth + 1))
        return m
      }
      default:
        throw new Error("cbor type")
    }
  }
  const v = item(0)
  if (i !== buf.length) throw new Error("cbor trailing")
  return v
}

/** Reads a DER TLV at `at`; definite lengths only. */
const tlv = (d: Uint8Array, at: number): { tag: number; start: number; end: number } => {
  const tag = d[at]!
  let n = d[at + 1]!
  let start = at + 2
  if (n & 0x80) {
    const k = n & 0x7f
    if (k < 1 || k > 3) throw new Error("der length")
    n = 0
    for (let j = 0; j < k; j++) n = n * 256 + d[start + j]!
    start += k
  }
  if (start + n > d.length) throw new Error("der bounds")
  return { tag, start, end: start + n }
}

/** The 32-byte nonce in credCert extension 1.2.840.113635.100.8.2: OCTET STRING { SEQUENCE { [1] { OCTET STRING } } }. */
const certNonce = (der: Uint8Array): Uint8Array | null => {
  let at = -1
  for (let k = 0; k + NONCE_OID.length <= der.length; k++) {
    if (same(der.subarray(k, k + NONCE_OID.length), NONCE_OID)) {
      if (at !== -1) return null
      at = k
    }
  }
  if (at === -1) return null
  let next = tlv(der, at + NONCE_OID.length)
  if (next.tag === 0x01) next = tlv(der, next.end)
  if (next.tag !== 0x04) return null
  const seq = tlv(der, next.start)
  if (seq.tag !== 0x30) return null
  const ctx = tlv(der, seq.start)
  if (ctx.tag !== 0xa1) return null
  const oct = tlv(der, ctx.start)
  return oct.tag === 0x04 && oct.end - oct.start === 32 ? der.subarray(oct.start, oct.end) : null
}

const within = (cert: X509Certificate, now: number) => Date.parse(cert.validFrom) <= now && now <= Date.parse(cert.validTo)

export interface AttestInput {
  readonly attestation: string
  readonly keyId: string
  readonly clientData: Uint8Array
  readonly appId: string
  readonly allowDevelopment: boolean
  readonly now: number
}

/** Production entry: Apple's pinned root. */
export const verifyAttestation = (input: AttestInput): AttestResult => verifyAttestationWithRoot(APPLE_APP_ATTESTATION_ROOT, ROOT_SHA256, input)

/** Exported for tests, which build a chain under their own root; production always uses verifyAttestation. */
export const verifyAttestationWithRoot = (rootPem: string, rootSha256: string, input: {
  readonly attestation: string
  readonly keyId: string
  readonly clientData: Uint8Array
  readonly appId: string
  readonly allowDevelopment: boolean
  readonly now: number
}): AttestResult => {
  const fail = (reason: string): AttestResult => ({ ok: false, reason })
  try {
    const obj = decodeCbor(b64(input.attestation))
    if (!(obj instanceof Map) || obj.get("fmt") !== "apple-appattest") return fail("format")
    const stmt = obj.get("attStmt")
    const authData = obj.get("authData")
    if (!(stmt instanceof Map) || !(authData instanceof Uint8Array)) return fail("format")
    const x5c = stmt.get("x5c")
    if (!Array.isArray(x5c) || x5c.length !== 2 || !x5c.every((c) => c instanceof Uint8Array)) return fail("chain")
    const root = new X509Certificate(rootPem)
    if (Buffer.from(sha256(new Uint8Array(root.raw))).toString("hex") !== rootSha256) return fail("root")
    const leaf = new X509Certificate(Buffer.from(x5c[0] as Uint8Array))
    const intermediate = new X509Certificate(Buffer.from(x5c[1] as Uint8Array))
    if (!intermediate.verify(root.publicKey) || !leaf.verify(intermediate.publicKey)) return fail("chain")
    if (!within(root, input.now) || !within(intermediate, input.now) || !within(leaf, input.now)) return fail("validity")

    const nonce = sha256(authData, sha256(input.clientData))
    const certNonceBytes = certNonce(new Uint8Array(leaf.raw))
    if (!certNonceBytes || !same(certNonceBytes, nonce)) return fail("nonce")

    const jwk = leaf.publicKey.export({ format: "jwk" }) as { kty?: string; crv?: string; x?: string; y?: string }
    if (jwk.kty !== "EC" || jwk.crv !== "P-256" || !jwk.x || !jwk.y) return fail("key")
    const point = Uint8Array.from([0x04, ...Buffer.from(jwk.x, "base64url"), ...Buffer.from(jwk.y, "base64url")])
    const keyId = b64(input.keyId)
    if (!same(sha256(point), keyId)) return fail("key id")

    if (authData.length < 55) return fail("auth data")
    const appIdHash = sha256(new TextEncoder().encode(input.appId))
    if (!same(authData.subarray(0, 32), appIdHash)) return fail("app id")
    const counter = ((authData[33]! << 24) >>> 0) + (authData[34]! << 16) + (authData[35]! << 8) + authData[36]!
    if (counter !== 0) return fail("counter")
    const aaguid = authData.subarray(37, 53)
    const development = same(aaguid, AAGUID_DEV)
    if (!same(aaguid, AAGUID_PROD) && !(development && input.allowDevelopment)) return fail("aaguid")
    const credLen = (authData[53]! << 8) + authData[54]!
    if (55 + credLen > authData.length || !same(authData.subarray(55, 55 + credLen), keyId)) return fail("credential id")

    return {
      ok: true,
      development,
      key: { jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, app_id_hash: Buffer.from(appIdHash).toString("base64url"), counter: 0 }
    }
  } catch {
    return fail("malformed")
  }
}
