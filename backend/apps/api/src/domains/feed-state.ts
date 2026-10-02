import type { Principal } from "@cmux/ownership"
import type { FeedItem, FeedPrefs } from "@cmux/protocol"

/**
 * FeedDO state and the pure helpers its reducer shares (plans/cmux-next/feed.md
 * sections 3 to 5). Size bounds keep the whole-state commit small (section 4).
 */

export interface FeedState {
  /** The user this feed belongs to; set by the first op. */
  readonly user: string | null
  readonly items: Readonly<Record<string, FeedItem>>
  /** `${poster scope}\u0000${dedupe key}` -> id, only while the item is active (3.5). */
  readonly dedupe: Readonly<Record<string, string>>
  readonly next_order: number
  readonly prefs: FeedPrefs
  /** Posts per poster scope in the current minute (rate limit). */
  readonly rate: Readonly<Record<string, { readonly minute: number; readonly count: number }>>
}

export const MAX_ITEMS = 500
export const MAX_OPEN_REQUESTS = 100
export const MAX_POSTS_PER_MINUTE = 60
/** Posts per minute for all scopes of one install together (a daemon posts for many agents). */
export const MAX_INSTALL_POSTS_PER_MINUTE = 240
/** One item, serialized, before its answer (prompt, actions, open target, attachments included). */
export const MAX_ITEM_BYTES = 24 * 1024
/**
 * The engine commits the whole state as one row (Durable Object rows are at
 * most 2 MB). Items plus a reserve for the answer of every open request stay
 * under this, so answering can never push the row past the limit.
 */
export const MAX_STATE_BYTES = 1_500_000
export const ANSWER_RESERVE_BYTES = 8 * 1024
export const RETENTION_MS = 7 * 24 * 3600_000
export const DEFAULT_REQUEST_EXPIRY_MS = 24 * 3600_000
export const DEFAULT_NOTICE_EXPIRY_MS = 7 * 24 * 3600_000

export const DEFAULT_PREFS: FeedPrefs = {
  push_enabled: true,
  push_delay: { urgent: 0, high: 20_000, normal: 120_000, low: null },
  push_skip_when_mac_active: true
}

export const initialFeedState = (): FeedState => ({ user: null, items: {}, dedupe: {}, next_order: 1, prefs: DEFAULT_PREFS, rate: {} })

/**
 * The poster scope: dedupe keys, threads and agent reads are scoped to it. A
 * daemon install posts for its agents with `agent` (its launch credential), so
 * two agents on one Mac never share a scope.
 */
export const posterScope = (p: Principal, declaredAgent?: string): string => {
  if (p.kind === "system") return p.identity
  const base = p.install ? `inst:${p.install}` : `user:${p.user ?? p.identity}`
  const agent = p.agent ?? declaredAgent
  return agent ? `${base}/agent:${agent}` : base
}

/** Install kinds that are a person's own app (UserDO's registered kind, resolved with the grant). */
export const USER_APP_KINDS: ReadonlySet<string> = new Set(["mac", "ios", "web"])

/**
 * A person's client: a human session, or the Mac, iPhone or web app install
 * acting for no agent. Daemons, CLIs and VMs post and cancel their own items
 * but never answer or triage: that is how an agent's own install cannot
 * approve its requests (the actor stamp later narrows this further).
 */
export const isUserClient = (p: Principal) => p.kind === "session" || (p.kind === "install" && !p.agent && USER_APP_KINDS.has(p.install_kind ?? ""))

/** Serialized size, the unit of every byte bound. */
export const jsonBytes = (v: unknown) => (v === undefined ? 0 : new TextEncoder().encode(JSON.stringify(v)).length)

/** True when the state can take `extraBytes` more with `openRequests` open requests after the change. */
export const fitsBudget = (s: FeedState, extraBytes: number, openRequests: number) =>
  jsonBytes(s.items) + extraBytes + openRequests * ANSWER_RESERVE_BYTES <= MAX_STATE_BYTES

export const isActive = (i: FeedItem) => i.state === "open" && i.archived_at === null

export const dedupeSlot = (i: FeedItem) => (i.dedupe_key === null ? null : `${i.poster.scope}\u0000${i.dedupe_key}`)

/** Removes an item's dedupe entry when it points at the item. */
export const releaseDedupe = (dedupe: Readonly<Record<string, string>>, i: FeedItem): Readonly<Record<string, string>> => {
  const slot = dedupeSlot(i)
  if (slot === null || dedupe[slot] !== i.id) return dedupe
  const { [slot]: _, ...rest } = dedupe
  return rest
}

/** Claims the dedupe slot for an active item when it is free. */
export const claimDedupe = (dedupe: Readonly<Record<string, string>>, i: FeedItem): Readonly<Record<string, string>> => {
  const slot = dedupeSlot(i)
  if (slot === null || !isActive(i) || dedupe[slot] !== undefined) return dedupe
  return { ...dedupe, [slot]: i.id }
}

/** Push applies to open requests and unread active notices that no one saw. */
export const pushEligible = (i: FeedItem) =>
  (i.type === "request" ? i.state === "open" : isActive(i) && i.read_at === null) && i.seen_at === null && i.snoozed_until === null

export const pushDueAt = (prefs: FeedPrefs, priority: FeedItem["priority"], from: number): number | null => {
  const delay = prefs.push_delay[priority]
  return prefs.push_enabled && delay !== null ? from + delay : null
}

/** One change to an item: bumps revision and updated_at. */
export const touch = (i: FeedItem, now: number, patch: Partial<FeedItem>): FeedItem => ({ ...i, ...patch, revision: i.revision + 1, updated_at: now })

export const openRequestCount = (s: FeedState) => Object.values(s.items).filter((i) => i.type === "request" && i.state === "open").length

/** When an item may leave the state (closed or archived plus retention), else null. */
export const prunableAt = (i: FeedItem): number | null => {
  // Open, unarchived items never leave by retention (expiry closes them first).
  const end = i.state !== "open" ? i.closed_at : i.archived_at
  return end === null ? null : end + RETENTION_MS
}

/**
 * Makes room for one more item: drops closed or archived items first (oldest
 * end first), then read notices, then unread notices. Open requests are never
 * dropped (posting a request beyond MAX_OPEN_REQUESTS is refused instead).
 */
export const evictForInsert = (s: FeedState): FeedState => {
  const items = Object.values(s.items)
  if (items.length < MAX_ITEMS) return s
  const rank = (i: FeedItem): [number, number] | null => {
    if (i.state !== "open" || i.archived_at !== null) return [0, i.closed_at ?? i.archived_at ?? i.updated_at]
    if (i.type === "notice") return [i.read_at === null ? 2 : 1, i.order]
    return null
  }
  const candidates = items
    .map((i) => ({ i, r: rank(i) }))
    .filter((c): c is { i: FeedItem; r: [number, number] } => c.r !== null)
    .sort((a, b) => a.r[0] - b.r[0] || a.r[1] - b.r[1] || a.i.order - b.i.order)
  const drop = candidates.slice(0, items.length - MAX_ITEMS + 1)
  let dedupe = s.dedupe
  const kept = { ...s.items }
  for (const { i } of drop) {
    dedupe = releaseDedupe(dedupe, i)
    delete kept[i.id]
  }
  return { ...s, items: kept, dedupe }
}

/** The earliest time the owner must wake for this state, or null. */
export const nextFeedWake = (s: FeedState): number | null => {
  let at: number | null = null
  const min = (t: number | null) => {
    if (t !== null && (at === null || t < at)) at = t
  }
  for (const i of Object.values(s.items)) {
    if (i.state === "open") min(i.expires_at)
    min(i.snoozed_until)
    min(i.push_due_at)
    min(prunableAt(i))
  }
  return at
}

/**
 * Items a principal may read: the user's apps see everything; an agent sees
 * what its scope posted; a daemon, CLI or VM install sees what it or its
 * agents posted.
 */
export const visibleTo = (p: Principal, i: FeedItem) =>
  isUserClient(p) || p.kind === "system" || i.poster.scope === posterScope(p) || (!p.agent && p.install !== undefined && i.poster.install === p.install)
