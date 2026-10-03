import { createHash, createPublicKey, verify as verifySignature } from "node:crypto"

interface JsonWebKey {
  readonly kty?: string
  readonly crv?: string
  readonly x?: string
  readonly y?: string
  readonly d?: string
}

/**
 * Server-checked device proofs for lowering the text confirmation level
 * (decision 2026-10-02, home-messaging.md section 19). The owner's device
 * signs exactly {op, user, install, new_level, nonce, expires_at}:
 * - `presence`: an ES256 signature by a Secure Enclave key created with a
 *   user-presence access control (Face ID, Touch ID or the device passcode),
 *   so the key cannot sign without the person; required on every platform;
 * - `app_attest` (iOS): an App Attest assertion over the same payload, which
 *   proves the genuine cmux app on a genuine device (it does not prove Face ID;
 *   the presence signature does). Required for iOS installs.
 * Pure and synchronous (node:crypto), so a reducer can run it.
 */
export const LOWER_OP = "user.text_confirm.lower"
export const PROOF_DOMAIN = "cmux-text-confirm-v1"

export interface ProofPayload {
  readonly op: typeof LOWER_OP
  readonly user: string
  readonly install: string
  readonly new_level: string
  readonly nonce: string
  readonly expires_at: number
}

/** The exact bytes a device signs: a domain tag line, then canonical JSON (sorted keys). */
export const proofMessage = (p: ProofPayload): Buffer => {
  const keys = Object.keys(p).sort() as Array<keyof ProofPayload>
  return Buffer.from(`${PROOF_DOMAIN}\n${JSON.stringify(Object.fromEntries(keys.map((k) => [k, p[k]])))}`, "utf8")
}

const b64u = (s: string): Buffer | null => (/^[A-Za-z0-9_-]+={0,2}$/.test(s) ? Buffer.from(s, "base64url") : null)

/** A P-256 public key as JWK; anything else is refused. */
export const p256Key = (jwk: unknown) => {
  const k = jwk as JsonWebKey | null
  if (!k || k.kty !== "EC" || k.crv !== "P-256" || typeof k.x !== "string" || typeof k.y !== "string" || k.d !== undefined) return null
  try {
    return createPublicKey({ key: { kty: "EC", crv: "P-256", x: k.x, y: k.y }, format: "jwk" })
  } catch {
    return null
  }
}

/** Presence signature: ES256 over proofMessage, raw r||s (64 bytes) or DER, base64url. */
export const verifyPresence = (jwk: unknown, payload: ProofPayload, signature: string): boolean => {
  const key = p256Key(jwk)
  const sig = b64u(signature)
  if (!key || !sig) return false
  const data = proofMessage(payload)
  try {
    return verifySignature("sha256", data, { key, dsaEncoding: sig.length === 64 ? "ieee-p1363" : "der" }, sig)
  } catch {
    return false
  }
}

// Plain Uint8Array helpers: the Worker's Buffer typings lack Node's read and compare methods.
const u16 = (b: Uint8Array, at: number) => (b[at]! << 8) | b[at + 1]!
const u32 = (b: Uint8Array, at: number) => ((b[at]! << 24) >>> 0) + (b[at + 1]! << 16) + (b[at + 2]! << 8) + b[at + 3]!
const sameBytes = (a: Uint8Array, b: Uint8Array) => a.length === b.length && a.every((x, i) => x === b[i])

/** Minimal CBOR reader for the App Attest assertion: a map of text keys to byte strings. */
const readCborMap = (buf: Buffer): Record<string, Buffer> | null => {
  let i = 0
  const len = (info: number): number | null => {
    if (info < 24) return info
    if (info === 24) return i < buf.length ? buf[i++]! : null
    if (info === 25) return i + 2 <= buf.length ? ((i += 2), u16(buf, i - 2)) : null
    if (info === 26) return i + 4 <= buf.length ? ((i += 4), u32(buf, i - 4)) : null
    return null
  }
  const head = (): [number, number] | null => (i < buf.length ? [buf[i]! >> 5, buf[i++]! & 31] : null)
  const h = head()
  if (!h || h[0] !== 5) return null
  const n = len(h[1])
  if (n === null || n > 8) return null
  const out: Record<string, Buffer> = {}
  for (let k = 0; k < n; k++) {
    const kh = head()
    if (!kh || kh[0] !== 3) return null
    const kl = len(kh[1])
    if (kl === null || i + kl > buf.length) return null
    const key = new TextDecoder().decode(buf.subarray(i, i + kl))
    i += kl
    const vh = head()
    if (!vh || vh[0] !== 2) return null
    const vl = len(vh[1])
    if (vl === null || i + vl > buf.length) return null
    out[key] = buf.subarray(i, i + vl)
    i += vl
  }
  return i === buf.length ? out : null
}

export interface AppAttestKey {
  /** The attested key's public part (P-256 JWK), stored at registration after the Worker verified the attestation. */
  readonly jwk: unknown
  /** sha256 of "<Team ID>.<bundle id>" (base64url). */
  readonly app_id_hash: string
  /** The last accepted counter; an assertion must carry a larger one. */
  readonly counter: number
}

/**
 * App Attest assertion check (Apple's server-side steps): clientDataHash =
 * sha256(proofMessage); nonce = sha256(authenticatorData || clientDataHash);
 * the signature over nonce verifies with the attested key; the RP ID hash is
 * our app id; the counter grew. Returns the new counter to store.
 */
export const verifyAppAttest = (key: AppAttestKey, payload: ProofPayload, assertion: string): { ok: true; counter: number } | { ok: false } => {
  const raw = b64u(assertion)
  const pub = p256Key(key.jwk)
  if (!raw || !pub) return { ok: false }
  const map = readCborMap(raw)
  const auth = map?.authenticatorData
  const sig = map?.signature
  if (!auth || !sig || auth.length < 37) return { ok: false }
  if (!sameBytes(auth.subarray(0, 32), Buffer.from(key.app_id_hash, "base64url"))) return { ok: false }
  const counter = u32(auth, 33)
  if (counter <= key.counter) return { ok: false }
  const clientDataHash = createHash("sha256").update(proofMessage(payload)).digest()
  const nonce = createHash("sha256").update(Buffer.concat([auth, clientDataHash])).digest()
  try {
    return verifySignature("sha256", nonce, { key: pub, dsaEncoding: "der" }, sig) ? { ok: true, counter } : { ok: false }
  } catch {
    return { ok: false }
  }
}
