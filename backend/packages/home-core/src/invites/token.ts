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

/**
 * Where the accept page lives per environment. Fail closed: there is no
 * default, and an environment without an entry (development, previews, local)
 * needs an explicit https origin. Switch production to `https://cmux.com` once
 * the cmux.com/i route ships (D-H1).
 */
export const ACCEPT_ORIGINS: Readonly<Record<string, string>> = {
  production: "https://console.cmux.dev",
  staging: "https://console-staging.cmux.dev"
}

export const inviteOrigin = (environment: string | undefined, override?: string): string => {
  const origin = override ?? (environment ? ACCEPT_ORIGINS[environment] : undefined)
  if (!origin) throw new Error(`no invite accept origin for environment ${JSON.stringify(environment ?? null)}`)
  let url: URL
  try {
    url = new URL(origin)
  } catch {
    throw new Error("invite accept origin is not a URL")
  }
  if (url.protocol !== "https:" || url.pathname !== "/" || url.search || url.hash || url.username) throw new Error("invite accept origin must be a bare https origin")
  return url.origin
}

/** `<origin>/i/<g|d><26>#<secret>` for the environment (inviteOrigin rules). */
export const inviteLink = (environment: string | undefined, conversation: string, secret: string, originOverride?: string): string => {
  if (!/^[0-9A-HJKMNP-TV-Z]{26}$/.test(secret)) throw new Error("invite secret must be 26 base32 characters")
  return `${inviteOrigin(environment, originOverride)}/i/${linkCode(conversation)}#${secret}`
}

/** Matches exactly one accept URL of the environment's origin. */
export const acceptUrlPattern = (environment: string | undefined, originOverride?: string): RegExp =>
  new RegExp(`^${inviteOrigin(environment, originOverride).replace(/[.*+?^${}()|[\]\\/]/g, "\\$&")}/i/[dg][0-9A-HJKMNP-TV-Z]{26}#[0-9A-HJKMNP-TV-Z]{26}$`)

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

/**
 * The invite card image (`/og/invite/<code>.png` on the accept origin): the og:image of the
 * accept page and the attachment of the first text (decision: first contact = contact card,
 * then the text with this image and the link on the last line).
 */
export const inviteImageUrl = (environment: string | undefined, conversation: string, originOverride?: string): string =>
  `${inviteOrigin(environment, originOverride)}/og/invite/${linkCode(conversation)}.png`
