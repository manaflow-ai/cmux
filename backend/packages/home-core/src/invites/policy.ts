import { isAddress, normalizeEmail, normalizePhone, type Address } from "./normalize.ts"

/**
 * The environment send policy (home-messaging.md section 9). It runs in code
 * before every provider call:
 * - production sends to any recipient that is not suppressed;
 * - every other environment sends only to the private allow list, loaded at
 *   runtime from secret storage (`HOME_INVITE_ALLOWLIST_EMAILS`,
 *   `HOME_INVITE_ALLOWLIST_PHONES`), never from the
 *   repository; any other recipient is refused with no provider call;
 * - outside production, an invite from an inviter on the team inviter list
 *   (`HOME_INVITE_ALLOWED_INVITERS`, decision 2026-10-05) reaches any recipient
 *   that is not suppressed; the rate limits and suppression still apply;
 * - `HOME_INVITES_SEND=off` refuses everything everywhere.
 */
export type Environment = "production" | "staging" | "development" | "preview" | "local"

export interface Allowlist {
  readonly entries: ReadonlyArray<Address>
}

export const EMPTY_ALLOWLIST: Allowlist = { entries: [] }

/**
 * Parses the allow list: one `email <address>` or `phone <number>` per line,
 * `#` comments and blank lines ignored. Invalid lines throw with their line
 * number only (never the content, which is private).
 */
export const parseAllowlist = (text: string): Allowlist => {
  const entries: Array<Address> = []
  text.split(/\r?\n/).forEach((raw, index) => {
    const line = raw.replace(/#.*/, "").trim()
    if (!line) return
    const [kind, ...rest] = line.split(/\s+/)
    const value = rest.join(" ")
    const parsed = kind === "email" ? normalizeEmail(value) : kind === "phone" ? normalizePhone(value) : "address.invalid"
    if (!isAddress(parsed)) throw new Error(`allow list line ${index + 1}: expected "email <address>" or "phone <number>"`)
    entries.push(parsed)
  })
  return { entries }
}

/**
 * The Worker's form: `HOME_INVITE_ALLOWLIST_EMAILS` and
 * `HOME_INVITE_ALLOWLIST_PHONES`: comma, semicolon or newline separated
 * (emails also by spaces; phones may contain spaces). Invalid entries throw
 * with their position only.
 */
export const allowlistFromEnv = (emails: string | undefined, phones: string | undefined): Allowlist => {
  const split = (v: string | undefined, sep: RegExp) => (v ?? "").split(sep).map((x) => x.trim()).filter(Boolean)
  const entries: Array<Address> = []
  split(emails, /[\s,;]+/).forEach((value, index) => {
    const parsed = normalizeEmail(value)
    if (!isAddress(parsed)) throw new Error(`HOME_INVITE_ALLOWLIST_EMAILS entry ${index + 1} is not an email address`)
    entries.push(parsed)
  })
  split(phones, /[,;\n]+/).forEach((value, index) => {
    const parsed = normalizePhone(value)
    if (!isAddress(parsed)) throw new Error(`HOME_INVITE_ALLOWLIST_PHONES entry ${index + 1} is not a phone number`)
    entries.push(parsed)
  })
  return { entries }
}

/** 1-based position in the allow list, for reports that must not show the address; 0 when absent. */
export const allowlistIndex = (allowlist: Allowlist, address: Address): number =>
  allowlist.entries.findIndex((e) => e.channel === address.channel && e.value === address.value) + 1

export interface SendPolicyInput {
  readonly environment: Environment
  /** `HOME_INVITES_SEND`; anything but `off` means on. */
  readonly sendSwitch?: string | undefined
  readonly allowlist: Allowlist
  /** The invite's inviter is on the team inviter list (non-production only; production sends to anyone). */
  readonly trustedInviter?: boolean
}

export type Suppression = "opted_out" | "bounced" | "complained" | "reported" | "admin"

export type SendDecision =
  | { readonly send: true; readonly allowlist_index: number }
  | { readonly send: false; readonly state: "refused_env" | "suppressed" | "disabled"; readonly reason: string }

export const decideSend = (policy: SendPolicyInput, address: Address, suppression: Suppression | null): SendDecision => {
  if ((policy.sendSwitch ?? "").trim().toLowerCase() === "off") return { send: false, state: "disabled", reason: "HOME_INVITES_SEND=off" }
  if (suppression) return { send: false, state: "suppressed", reason: suppression }
  const index = allowlistIndex(policy.allowlist, address)
  if (policy.environment === "production") return { send: true, allowlist_index: index }
  if (index === 0 && policy.trustedInviter === true) return { send: true, allowlist_index: 0 }
  if (index === 0) return { send: false, state: "refused_env", reason: `${policy.environment} sends only to the allow list` }
  return { send: true, allowlist_index: index }
}

/** The team inviter list: user ids (`user_...`) and email addresses. */
export interface InviterList {
  readonly users: ReadonlySet<string>
  readonly emails: ReadonlySet<string>
}

/**
 * `HOME_INVITE_ALLOWED_INVITERS`: comma, semicolon, space or newline separated user ids and
 * emails. Invalid entries throw with their position only.
 */
export const allowedInvitersFromEnv = (text: string | undefined): InviterList => {
  const users = new Set<string>()
  const emails = new Set<string>()
  ;(text ?? "").split(/[\s,;]+/).map((x) => x.trim()).filter(Boolean).forEach((value, index) => {
    if (/^user_[A-Za-z0-9_-]{1,64}$/.test(value)) return void users.add(value)
    const parsed = normalizeEmail(value)
    if (!isAddress(parsed)) throw new Error(`HOME_INVITE_ALLOWED_INVITERS entry ${index + 1} is not a user id or an email address`)
    emails.add(parsed.value)
  })
  return { users, emails }
}

/** `email` must be the inviter's verified email; pass none when it is not verified. */
export const isAllowedInviter = (list: InviterList, inviter: { readonly user?: string | null; readonly email?: string | null }): boolean => {
  if (inviter.user && list.users.has(inviter.user)) return true
  if (!inviter.email) return false
  const parsed = normalizeEmail(inviter.email)
  return isAddress(parsed) && list.emails.has(parsed.value)
}

export const parseEnvironment = (value: string | undefined): Environment => {
  switch (value) {
    case "production":
    case "staging":
    case "development":
    case "preview":
      return value
    default:
      return "local"
  }
}
