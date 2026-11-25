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


/** The head's largest top-level keys by JSON size, with entry counts; names and sizes only, never values. */
export const stateLargest = (head: unknown, top = 5): { key: string; bytes: number; entries?: number }[] => {
  if (head === null || typeof head !== "object" || Array.isArray(head)) return []
  return Object.entries(head as Record<string, unknown>)
    .map(([key, value]) => {
      const bytes = utf8Length(JSON.stringify(value) ?? "")
      const entries = Array.isArray(value) ? value.length : value !== null && typeof value === "object" ? Object.keys(value).length : undefined
      return entries === undefined ? { key, bytes } : { key, bytes, entries }
    })
    .sort((a, b) => b.bytes - a.bytes)
    .slice(0, top)
}

/** A refusal message when `json` (a head about to be committed) is past STATE_MAX_BYTES, else undefined.
 * It names the head's largest parts so a refusal in a probe or log shows which part grew. */
export const stateFull = (json: string, stream: string, op: string): string | undefined => {
  const bytes = utf8Length(json)
  if (bytes <= STATE_MAX_BYTES) return undefined
  let largest: ReturnType<typeof stateLargest> = []
  try {
    largest = stateLargest(JSON.parse(json))
  } catch {
    largest = []
  }
  console.error(JSON.stringify({ msg: "owner state full", stream, op, bytes, largest }))
  const parts = largest.map((p) => `${p.key} ${p.bytes}${p.entries === undefined ? "" : `/${p.entries}`}`).join(", ")
  return `the owner's state would be ${bytes} bytes (limit ${STATE_MAX_BYTES})${parts ? `; largest (bytes/entries): ${parts}` : ""}`
}

export const settled = (stream: string, tx: string, key: string, sequence: number, ok: boolean): SettledFrame => ({ t: "request-settled", tx, idempotency_key: key, stream, sequence, ok })

/** The TrustClaimedOwner mutant: identity taken from the request body. */
export const claimedPrincipal = (p: Principal, params: unknown): Principal => {
  const claimed = (params as { claimed_identity?: unknown } | null)?.claimed_identity
  return typeof claimed === "string" ? { ...p, identity: claimed } : p
}
