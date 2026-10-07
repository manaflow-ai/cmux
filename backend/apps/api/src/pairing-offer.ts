import type { LinkCert } from "./domains/link-cert.ts"
import type { PublicJwk, TrustPeerDevice } from "./domains/user-trust.ts"

/**
 * Device pairing offers (plans/cmux-next/ios-next/b6-pairing.md section 4): one row in the
 * PairingDO named `offer:<offer id>`, where the offer id is the base64url SHA-256 of the QR code.
 * Single writer of the offer's state: open, then claimed by one device, then done or declined,
 * forgotten by the object's alarm at expiry. The code is never stored.
 */

/** A QR offer is claimable for this long. */
export const OFFER_TTL_MS = 5 * 60_000
/** After a cross-account claim the host owner has this long to accept. */
export const ACCEPT_TTL_MS = 10 * 60_000

export interface OfferHost {
  readonly host: string
  readonly team: string
  readonly owner_user: string
  readonly host_install: string
  readonly host_name: string
  readonly host_jwk: PublicJwk
  readonly host_cert: LinkCert
}

export interface OfferRow extends OfferHost {
  readonly state: "open" | "claimed" | "done" | "declined"
  readonly claimant: TrustPeerDevice | null
  readonly expires_at: number
}

export type ClaimOutcome = { ok: true; offer: OfferRow; same_account: boolean } | { ok: false; code: string; message: string }

type Row = { body: string }

export const ensureOfferTable = (sql: SqlStorage) => sql.exec(`CREATE TABLE IF NOT EXISTS offer (id INTEGER PRIMARY KEY CHECK (id = 1), body TEXT NOT NULL)`)

export const readOffer = (sql: SqlStorage, now: number): OfferRow | undefined => {
  const r = sql.exec<Row>(`SELECT body FROM offer WHERE id = 1`).toArray()[0]
  const o = r ? (JSON.parse(r.body) as OfferRow) : undefined
  return o && o.expires_at > now ? o : undefined
}

const write = (sql: SqlStorage, o: OfferRow) => sql.exec(`INSERT OR REPLACE INTO offer (id, body) VALUES (1, ?)`, JSON.stringify(o))

/** A fresh offer. Refuses when this object already holds a live one (the caller mints another code). */
export const createOffer = (sql: SqlStorage, host: OfferHost, now: number): { ok: true; expires_at: number } | { ok: false } => {
  if (readOffer(sql, now)) return { ok: false }
  const expires_at = now + OFFER_TTL_MS
  write(sql, { ...host, state: "open", claimant: null, expires_at })
  return { ok: true, expires_at }
}

/**
 * The QR binds the host and its direct key: a claim naming another host or key is refused, so a
 * swapped code cannot pin the phone to a key the offering host did not publish. The first
 * claimant wins; the same device may claim again (a retry).
 */
export const claimOffer = (sql: SqlStorage, claim: { host: string; host_key: string; claimant: TrustPeerDevice }, now: number): ClaimOutcome => {
  const o = readOffer(sql, now)
  if (!o) return { ok: false, code: "pairing.offer_unknown", message: "pairing code expired or unknown" }
  if (o.host !== claim.host || o.host_cert.key !== claim.host_key) return { ok: false, code: "pairing.key_mismatch", message: "the pairing code does not match this Mac's key" }
  const same = o.owner_user === claim.claimant.user
  if (o.claimant && o.claimant.install !== claim.claimant.install) return { ok: false, code: "pairing.offer_used", message: "pairing code already used" }
  if (o.state === "declined") return { ok: false, code: "pairing.declined", message: "the Mac's owner declined" }
  if (o.claimant) return { ok: true, offer: o, same_account: same }
  const next: OfferRow = same ? { ...o, state: "done", claimant: claim.claimant } : { ...o, state: "claimed", claimant: claim.claimant, expires_at: now + ACCEPT_TTL_MS }
  write(sql, next)
  return { ok: true, offer: next, same_account: same }
}

/** The host owner accepts the claimed device (single use; a retry with the same device is a no-op). */
export const completeOffer = (sql: SqlStorage, owner: string, install: string, now: number): ClaimOutcome => {
  const o = readOffer(sql, now)
  if (!o || !o.claimant) return { ok: false, code: "pairing.offer_unknown", message: "pairing request expired or unknown" }
  if (o.owner_user !== owner) return { ok: false, code: "auth.forbidden", message: "only the Mac's owner accepts" }
  if (o.claimant.install !== install) return { ok: false, code: "pairing.offer_used", message: "pairing code already used" }
  if (o.state === "declined") return { ok: false, code: "pairing.declined", message: "the request was declined" }
  if (o.state !== "done") write(sql, { ...o, state: "done" })
  return { ok: true, offer: { ...o, state: "done" }, same_account: false }
}

export const declineOffer = (sql: SqlStorage, owner: string, now: number): boolean => {
  const o = readOffer(sql, now)
  if (!o || o.owner_user !== owner || o.state === "done") return false
  write(sql, { ...o, state: "declined" })
  return true
}

/** 16 random bytes as 26 Crockford base32 symbols (the top 2 of 130 bits are zero). */
export const offerCode = (bytes: Uint8Array = crypto.getRandomValues(new Uint8Array(16))): string => {
  const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  let bits = 0n
  for (const b of bytes) bits = (bits << 8n) | BigInt(b)
  let out = ""
  for (let i = 25; i >= 0; i--) out += alphabet[Number((bits >> BigInt(i * 5)) & 31n)]
  return out
}

export const OFFER_CODE = /^[0-9A-HJKMNP-TV-Z]{26}$/

/** base64url SHA-256 of the code: the PairingDO name and the id in the trust stream. */
export const offerId = async (code: string): Promise<string> => {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`cmux-pair-offer\n${code}`)))
  return btoa(String.fromCharCode(...d)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

/** The QR link (b6-pairing.md 4.1). */
export const offerLink = (code: string, o: { host: string; team: string; host_key: string; expires_at: number; name: string }): string => {
  // Percent-encoding only (never `+` for a space), so every URL parser reads the same name.
  const q = Object.entries({ o: code, h: o.host, t: o.team, k: o.host_key, e: String(Math.floor(o.expires_at / 1000)), n: [...o.name].slice(0, 64).join("") })
  return `cmux://pair/1?${q.map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join("&")}`
}
