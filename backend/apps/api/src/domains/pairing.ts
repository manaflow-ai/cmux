/**
 * Pure helpers for cmux server pairing (plans/cmux-next/server.md 6.2). The
 * Rust crate `cmux-server-core::pairing` implements the same code alphabet and
 * normalization; tests share the golden values.
 */

const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

/** Lifetime of a pending code. */
export const PAIRING_TTL_MS = 10 * 60_000

/** 8 Crockford base32 symbols from 5 random bytes (40 bits). */
export const codeFromRandom = (bytes: Uint8Array): string => {
  if (bytes.length !== 5) throw new Error("pairing code needs 5 random bytes")
  let bits = 0n
  for (const b of bytes) bits = (bits << 8n) | BigInt(b)
  let out = ""
  for (let i = 7; i >= 0; i--) out += CROCKFORD[Number((bits >> BigInt(i * 5)) & 31n)]
  return out
}

/** Accepts `7kq4-m2xd`, spaces and the usual look-alikes (O->0, I/L->1); refuses anything else. */
export const normalizeCode = (input: string): string | null => {
  let out = ""
  for (const raw of input.toUpperCase()) {
    if (raw === "-" || raw === " ") continue
    const c = raw === "O" ? "0" : raw === "I" || raw === "L" ? "1" : raw
    if (!CROCKFORD.includes(c)) return null
    out += c
  }
  return out.length === 8 ? out : null
}

export const displayCode = (code: string): string => `${code.slice(0, 4)}-${code.slice(4)}`

/** The message a server signs to prove it holds the install key it asks to pair. */
export const beginProofMessage = (environment: string, thumbprint: string, wgPublicKey: string, issuedAt: number): string =>
  `cmux-pair-begin\n${environment}\n${thumbprint}\n${wgPublicKey}\n${issuedAt}`

/** A begin request older or newer than this is refused (clock skew bound). */
export const BEGIN_SKEW_MS = 5 * 60_000

export const hex = (bytes: ArrayBuffer): string => [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("")

export const sha256Hex = async (text: string): Promise<string> => hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)))
