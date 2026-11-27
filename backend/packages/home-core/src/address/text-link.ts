import { createHash, timingSafeEqual } from "node:crypto"

/**
 * Linking a phone number to an account for texting Chief (home-messaging.md
 * section 19, decision T1): the user asks in the app, we text a sign-in link
 * with a single-use 128-bit code (fragment only, fixed cmux origin, 10
 * minutes), and the link binds only when the SAME signed-in account that asked
 * opens it. AddressDO owns the state; these functions are pure.
 */
export const LINK_TTL_MS = 10 * 60_000
export const LINK_MAX_ATTEMPTS = 5
/** Link requests per (number, account) per hour, and per number per day (each one sends a text). */
export const LINK_REQUESTS_PER_HOUR = 3
export const LINK_REQUESTS_PER_DAY = 6
/** Accounts with a pending link at once; a new one drops the oldest. */
export const MAX_PENDING_LINKS = 3
export const BINDING_TTL_MS = 180 * 24 * 3_600_000
/** After this much silence, the next text needs a fresh link before anything beyond read and reply. */
export const BINDING_IDLE_MS = 90 * 24 * 3_600_000

export interface PendingLink {
  readonly user: string
  /** sha256(proof), where proof = sha256(code) is what the page sends. */
  readonly code_hash: string
  readonly expires_at: number
  readonly attempts: number
}

export interface TextBinding {
  readonly user: string
  readonly bound_at: number
  readonly expires_at: number
  readonly last_inbound_at: number | null
}

export interface LinkState {
  /** One pending link per requesting account, so a stranger's request never replaces the owner's. */
  readonly pending: ReadonlyArray<PendingLink>
  readonly binding: TextBinding | null
  /** Requests in the last day. */
  readonly requests: ReadonlyArray<{ readonly user: string; readonly at: number }>
}

export const EMPTY_LINK_STATE: LinkState = { pending: [], binding: null, requests: [] }

/** `user_<id>` from a principal's user (one rule for every op). */
export const userIdOf = (user: string | undefined): string | null => (user ? (user.startsWith("user_") ? user : `user_${user}`) : null)

const sha = (v: string) => createHash("sha256").update(v).digest("base64url")
const same = (a: string, b: string) => a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b))

export type LinkResult<T> = { readonly ok: true; readonly state: LinkState; readonly value: T } | { readonly ok: false; readonly code: string; readonly state?: LinkState }

/**
 * A new request replaces only the same account's pending link. Limits: 3 per hour per
 * (number, account), 6 per day per number. Per-account limits across numbers belong to the
 * Worker/UserDO (5 per day, 2 numbers per day). The Worker answers every outcome the same way
 * ("if this number can be linked, we sent a text"), so refusals do not reveal a number's state.
 */
export const requestLink = (s: LinkState, user: string, codeHash: string, now: number): LinkResult<{ expires_at: number }> => {
  const day = s.requests.filter((r) => r.at > now - 24 * 3_600_000)
  if (day.length >= LINK_REQUESTS_PER_DAY) return { ok: false, code: "link.rate_limited" }
  if (day.filter((r) => r.user === user && r.at > now - 3_600_000).length >= LINK_REQUESTS_PER_HOUR) return { ok: false, code: "link.rate_limited" }
  // A number bound to another account is not taken over by a new request; that account unlinks first.
  if (s.binding && s.binding.user !== user && s.binding.expires_at > now) return { ok: false, code: "link.bound_elsewhere" }
  const mine: PendingLink = { user, code_hash: codeHash, expires_at: now + LINK_TTL_MS, attempts: 0 }
  const others = s.pending.filter((p) => p.user !== user && p.expires_at > now)
  const pending = [...others, mine].slice(-MAX_PENDING_LINKS)
  return { ok: true, state: { ...s, pending, requests: [...day, { user, at: now }] }, value: { expires_at: mine.expires_at } }
}

/**
 * The signed-in account opens the link. Any failure that could come from a
 * forwarded link (another account) burns the pending link; a wrong proof
 * counts an attempt and burns it at LINK_MAX_ATTEMPTS.
 */
export const confirmLink = (s: LinkState, user: string, proof: string, now: number): LinkResult<TextBinding> => {
  const hash = sha(proof)
  // The proof selects the pending link; a link opened by another account is burned, never bound.
  const p = s.pending.find((x) => same(hash, x.code_hash))
  if (!p) {
    // Count a wrong proof against the signed-in account's own pending link.
    const own = s.pending.find((x) => x.user === user)
    if (!own) return { ok: false, code: "link.none" }
    const attempts = own.attempts + 1
    const pending = s.pending.filter((x) => x !== own).concat(attempts >= LINK_MAX_ATTEMPTS ? [] : [{ ...own, attempts }])
    return { ok: false, code: "link.invalid", state: { ...s, pending } }
  }
  const rest = s.pending.filter((x) => x !== p)
  if (now >= p.expires_at) return { ok: false, code: "link.expired", state: { ...s, pending: rest } }
  if (user !== p.user) return { ok: false, code: "link.wrong_account", state: { ...s, pending: rest } }
  // A number bound to another account stays bound; a pending link never takes it over.
  if (s.binding && s.binding.user !== user && s.binding.expires_at > now) return { ok: false, code: "link.bound_elsewhere", state: { ...s, pending: rest } }
  const binding: TextBinding = { user, bound_at: now, expires_at: now + BINDING_TTL_MS, last_inbound_at: null }
  // Binding drops every other account's pending link.
  return { ok: true, state: { ...s, pending: [], binding }, value: binding }
}

export const unlink = (s: LinkState, user: string | null): LinkResult<null> => {
  if (!s.binding) return { ok: true, state: s, value: null }
  if (user !== null && s.binding.user !== user) return { ok: false, code: "forbidden" }
  return { ok: true, state: { ...s, binding: null, pending: [] }, value: null }
}

/** How much an inbound text from this number may do (decision T3 plus the idle and SMS rules). */
export type TextAuthority = "none" | "relink" | "read_reply" | "full"

export const textAuthority = (
  s: LinkState,
  now: number,
  service: "iMessage" | "SMS" | string,
  userScope: "full" | "read_reply" | "off" = "full",
  group = false
): TextAuthority => {
  const b = s.binding
  if (!b || now >= b.expires_at || userScope === "off") return b && now < b.expires_at ? "none" : "relink"
  const idle = (b.last_inbound_at ?? b.bound_at) < now - BINDING_IDLE_MS
  if (idle) return "relink"
  // Plain SMS sender numbers can be forged by some gateways; iMessage senders are account-bound.
  if (service !== "iMessage") return "read_reply"
  // In a group thread other people read the replies: no full authority there.
  return userScope === "read_reply" || group ? "read_reply" : "full"
}

/** Records use of a live binding. An idle or expired binding is not revived by a text: only a new link does that. */
export const noteInbound = (s: LinkState, now: number): LinkState => {
  const b = s.binding
  if (!b || now >= b.expires_at || (b.last_inbound_at ?? b.bound_at) < now - BINDING_IDLE_MS) return s
  return { ...s, binding: { ...b, last_inbound_at: now } }
}
