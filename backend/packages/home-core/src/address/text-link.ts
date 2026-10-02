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
/** Link requests per number per hour (each one sends a text). */
export const LINK_REQUESTS_PER_HOUR = 3
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
  readonly pending: PendingLink | null
  readonly binding: TextBinding | null
  /** Request times in the last hour. */
  readonly requests: ReadonlyArray<number>
}

export const EMPTY_LINK_STATE: LinkState = { pending: null, binding: null, requests: [] }

const sha = (v: string) => createHash("sha256").update(v).digest("base64url")
const same = (a: string, b: string) => a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b))

export type LinkResult<T> = { readonly ok: true; readonly state: LinkState; readonly value: T } | { readonly ok: false; readonly code: string; readonly state?: LinkState }

/** A new request replaces any pending one (only the newest link works). */
export const requestLink = (s: LinkState, user: string, codeHash: string, now: number): LinkResult<{ expires_at: number }> => {
  const recent = s.requests.filter((t) => t > now - 3_600_000)
  if (recent.length >= LINK_REQUESTS_PER_HOUR) return { ok: false, code: "link.rate_limited" }
  // A number bound to another account is not taken over by a new request; that account unlinks first.
  if (s.binding && s.binding.user !== user && s.binding.expires_at > now) return { ok: false, code: "link.bound_elsewhere" }
  const pending = { user, code_hash: codeHash, expires_at: now + LINK_TTL_MS, attempts: 0 }
  return { ok: true, state: { ...s, pending, requests: [...recent, now] }, value: { expires_at: pending.expires_at } }
}

/**
 * The signed-in account opens the link. Any failure that could come from a
 * forwarded link (another account) burns the pending link; a wrong proof
 * counts an attempt and burns it at LINK_MAX_ATTEMPTS.
 */
export const confirmLink = (s: LinkState, user: string, proof: string, now: number): LinkResult<TextBinding> => {
  const p = s.pending
  if (!p) return { ok: false, code: "link.none" }
  if (now >= p.expires_at) return { ok: false, code: "link.expired", state: { ...s, pending: null } }
  if (!same(sha(proof), p.code_hash)) {
    const attempts = p.attempts + 1
    return { ok: false, code: "link.invalid", state: { ...s, pending: attempts >= LINK_MAX_ATTEMPTS ? null : { ...p, attempts } } }
  }
  if (user !== p.user) return { ok: false, code: "link.wrong_account", state: { ...s, pending: null } }
  const binding: TextBinding = { user, bound_at: now, expires_at: now + BINDING_TTL_MS, last_inbound_at: null }
  return { ok: true, state: { ...s, pending: null, binding }, value: binding }
}

export const unlink = (s: LinkState, user: string | null): LinkResult<null> => {
  if (!s.binding) return { ok: true, state: s, value: null }
  if (user !== null && s.binding.user !== user) return { ok: false, code: "forbidden" }
  return { ok: true, state: { ...s, binding: null, pending: null }, value: null }
}

/** How much an inbound text from this number may do (decision T3 plus the idle and SMS rules). */
export type TextAuthority = "none" | "relink" | "read_reply" | "full"

export const textAuthority = (s: LinkState, now: number, service: "iMessage" | "SMS" | string, userScope: "full" | "read_reply" | "off" = "full"): TextAuthority => {
  const b = s.binding
  if (!b || now >= b.expires_at || userScope === "off") return b && now < b.expires_at ? "none" : "relink"
  const idle = (b.last_inbound_at ?? b.bound_at) < now - BINDING_IDLE_MS
  if (idle) return "relink"
  // Plain SMS sender numbers can be forged by some gateways; iMessage senders are account-bound.
  if (service !== "iMessage") return "read_reply"
  return userScope === "read_reply" ? "read_reply" : "full"
}

export const noteInbound = (s: LinkState, now: number): LinkState => (s.binding ? { ...s, binding: { ...s.binding, last_inbound_at: now } } : s)
