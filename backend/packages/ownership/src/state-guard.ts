import type { Principal, SettledFrame } from "./types.ts"

/** Small engine helpers: the JSON head guard, settled frames, the TrustClaimedOwner mutant. */

/** Largest committed head (one SQLite row; Durable Object rows are at most 2 MB). */
export const STATE_MAX_BYTES = 1_500_000
export const utf8Length = (text: string): number => {
  let n = 0
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i)
    if (c < 0x80) n += 1
    else if (c < 0x800) n += 2
    else if (c >= 0xd800 && c <= 0xdbff) {
      n += 4
      i++
    } else n += 3
  }
  return n
}


/** A refusal message when `json` (a head about to be committed) is past STATE_MAX_BYTES, else undefined. */
export const stateFull = (json: string, stream: string, op: string): string | undefined => {
  const bytes = utf8Length(json)
  if (bytes <= STATE_MAX_BYTES) return undefined
  console.error(JSON.stringify({ msg: "owner state full", stream, op, bytes }))
  return `the owner's state would be ${bytes} bytes (limit ${STATE_MAX_BYTES})`
}

export const settled = (stream: string, tx: string, key: string, sequence: number, ok: boolean): SettledFrame => ({ t: "request-settled", tx, idempotency_key: key, stream, sequence, ok })

/** The TrustClaimedOwner mutant: identity taken from the request body. */
export const claimedPrincipal = (p: Principal, params: unknown): Principal => {
  const claimed = (params as { claimed_identity?: unknown } | null)?.claimed_identity
  return typeof claimed === "string" ? { ...p, identity: claimed } : p
}
