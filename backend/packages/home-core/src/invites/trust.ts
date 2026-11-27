/**
 * Message request trust (plans/cmux-next/home-messaging-invites/DESIGN.md section 2.4): a request
 * is trusted when the sender's and the recipient's verified emails share a company domain. A
 * public mailbox provider is never a company, so two strangers on gmail.com stay untrusted.
 */

/** Mailbox providers anyone can sign up at: sharing one says nothing about who someone is. */
const PUBLIC_MAIL_DOMAINS: ReadonlySet<string> = new Set([
  "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "yahoo.com", "ymail.com",
  "icloud.com", "me.com", "mac.com", "aol.com", "proton.me", "protonmail.com", "pm.me", "gmx.com", "gmx.de",
  "mail.com", "zoho.com", "yandex.com", "yandex.ru", "qq.com", "163.com", "126.com", "naver.com", "fastmail.com",
  "hey.com", "tutanota.com", "duck.com", "privaterelay.appleid.com"
])

/** The domain of a well-formed email, lowercased; null otherwise. */
export const emailDomain = (email: string | null | undefined): string | null => {
  if (typeof email !== "string") return null
  const at = email.lastIndexOf("@")
  if (at <= 0 || at === email.length - 1) return null
  return email.slice(at + 1).trim().toLowerCase() || null
}

/**
 * Whether a request from `sender` to `recipient` (both verified email domains, or null when not
 * verified) is trusted: the same domain, and not a public mailbox provider.
 */
export const requestTrusted = (senderDomain: string | null, recipientDomain: string | null): boolean =>
  senderDomain !== null && senderDomain === recipientDomain && !PUBLIC_MAIL_DOMAINS.has(senderDomain)
