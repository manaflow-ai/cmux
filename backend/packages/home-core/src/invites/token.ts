import { createHash, timingSafeEqual } from "node:crypto"
import { crockford, isCrockford } from "./base32.ts"

/**
 * Invite secrets and links (home-messaging.md section 5). The secret is 128
 * random bits as 26 base32 characters; only its sha256 is stored. The link
 * puts the secret in the fragment, so it never reaches a server log, a
 * referrer or a link scanner, and a prefetch cannot consume it.
 */
export const SECRET_CHARS = 26
const CONVERSATION_SUFFIX = 26

export const newInviteSecret = (random: Uint8Array): string => {
  if (random.length < 16) throw new Error("an invite secret needs 16 random bytes")
  return crockford(random.subarray(0, 16), SECRET_CHARS)
}

export const hashInviteSecret = (secret: string): string => createHash("sha256").update(secret).digest("base64url")

/** Constant-time comparison of a presented secret with a stored hash. */
export const secretMatches = (secret: string, storedHash: string): boolean => {
  const a = Buffer.from(hashInviteSecret(secret))
  const b = Buffer.from(storedHash)
  return a.length === b.length && timingSafeEqual(a, b)
}

/** `g` + suffix for `conv_<26>`, `d` + suffix for `conv_dm_<26>`. */
export const linkCode = (conversation: string): string => {
  if (conversation.startsWith("conv_dm_")) return `d${conversation.slice(8)}`
  if (conversation.startsWith("conv_")) return `g${conversation.slice(5)}`
  throw new Error(`not a conversation id: ${conversation}`)
}

export const inviteLink = (origin: string, conversation: string, secret: string): string =>
  `${origin.replace(/\/$/, "")}/i/${linkCode(conversation)}#${secret}`

export interface ParsedInvite {
  readonly conversation: string
  readonly secret: string
}

/** Parses a full link, or the path and fragment the landing page reads. */
export const parseInviteLink = (link: string): ParsedInvite | null => {
  const match = /\/i\/([dg])([0-9A-Z]+)#([0-9A-Z]+)$/.exec(link.trim())
  if (!match) return null
  const [, kind, suffix, secret] = match as unknown as [string, string, string, string]
  if (!isCrockford(suffix, CONVERSATION_SUFFIX) || !isCrockford(secret, SECRET_CHARS)) return null
  return { conversation: kind === "d" ? `conv_dm_${suffix}` : `conv_${suffix}`, secret }
}
