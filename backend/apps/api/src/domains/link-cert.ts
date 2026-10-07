/**
 * Link key certificates (plans/cmux-next/ios-next/b6-pairing.md section 2): an install's Secure
 * Enclave P-256 key signs the X25519 key it uses for a link (`direct` Noise, `wg` WireGuard) or a
 * WebRTC DTLS fingerprint (`dtls`). Pure helpers; the signature check is WebCrypto (async) and runs
 * outside reducers. `CmuxPairing.LinkCertificate` in Swift builds the same message.
 */

export const LINK_PURPOSES = ["direct", "wg", "dtls"] as const
export type LinkPurpose = (typeof LINK_PURPOSES)[number]
/** Purposes the trust store keeps (dtls proofs are per session and travel in signals). */
export const STORED_PURPOSES: ReadonlySet<string> = new Set(["direct", "wg"])

export interface LinkCert {
  readonly purpose: LinkPurpose
  readonly user: string
  readonly install: string
  /** base64url (no padding) of 32 bytes. */
  readonly key: string
  readonly issued_at: number
  readonly expires_at: number
  /** ES256 raw r||s, base64url. */
  readonly signature: string
}

export const DAY_MS = 86_400_000
export const MAX_LIFETIME_MS: Readonly<Record<LinkPurpose, number>> = { direct: 90 * DAY_MS, wg: 90 * DAY_MS, dtls: 15 * 60_000 }
/** A published cert must be fresh: issued at most this long ago, and not in the future beyond the skew. */
export const PUBLISH_MAX_AGE_MS = 10 * 60_000
export const PUBLISH_SKEW_MS = 5 * 60_000

const KEY = /^[A-Za-z0-9_-]{43}$/
const SIG = /^[A-Za-z0-9_-]{40,120}$/
const ID = /^[A-Za-z0-9_]{3,80}$/

/** The exact bytes the install key signs. */
export const linkCertMessage = (environment: string, c: Pick<LinkCert, "user" | "install" | "purpose" | "key" | "issued_at" | "expires_at">): string =>
  ["cmux-link-cert/1", environment, c.user, c.install, c.purpose, c.key, String(c.issued_at), String(c.expires_at)].join("\n")

/** Shape and lifetime of a cert, before its signature is checked. Returns the cert or a reason. */
export const parseLinkCert = (v: unknown): LinkCert | string => {
  if (typeof v !== "object" || v === null || Array.isArray(v)) return "cert must be an object"
  const c = v as Record<string, unknown>
  if (!LINK_PURPOSES.includes(c.purpose as LinkPurpose)) return "cert.purpose must be direct, wg or dtls"
  if (typeof c.user !== "string" || !ID.test(c.user) || typeof c.install !== "string" || !ID.test(c.install)) return "cert names a user and an install"
  if (typeof c.key !== "string" || !KEY.test(c.key)) return "cert.key must be 32 bytes base64url"
  if (!Number.isSafeInteger(c.issued_at) || !Number.isSafeInteger(c.expires_at)) return "cert times must be integers"
  if (typeof c.signature !== "string" || !SIG.test(c.signature)) return "cert.signature must be base64url"
  const purpose = c.purpose as LinkPurpose
  const issued = c.issued_at as number
  const expires = c.expires_at as number
  if (expires <= issued || expires - issued > MAX_LIFETIME_MS[purpose]) return `cert lifetime must be positive and at most ${MAX_LIFETIME_MS[purpose] / 60_000} minutes`
  return { purpose, user: c.user, install: c.install, key: c.key, issued_at: issued, expires_at: expires, signature: c.signature }
}

/** Publishing needs a fresh, unexpired cert. */
export const freshAt = (c: LinkCert, now: number): string | undefined => {
  if (c.issued_at > now + PUBLISH_SKEW_MS) return "cert issued in the future"
  if (c.issued_at < now - PUBLISH_MAX_AGE_MS) return "cert is not fresh; sign a new one"
  if (c.expires_at <= now) return "cert expired"
  return undefined
}
