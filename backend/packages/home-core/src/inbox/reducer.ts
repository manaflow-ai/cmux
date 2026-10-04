import { PREVIEW_ATTACHMENT_KINDS, type PreviewAttachments } from "../conversation/attachments.ts"
import type { ConversationKind } from "../conversation/types.ts"

/**
 * The UserDO inbox (home-messaging.md section 4.2): one entry per
 * conversation. Conversation-owned fields are a projection from
 * ConversationDO, merged by `rev` (max wins), so duplicated and reordered
 * bumps converge to the same entry. Counts merge separately by `counts_rev`
 * because a bump may not carry them. User-owned fields are written only by
 * the user's ops. Pure: the host passes `now` (ms).
 */

export interface InboxEntry {
  readonly conversation: string
  // Conversation-owned (max merge by rev).
  readonly rev: number
  readonly kind: ConversationKind
  readonly title: string
  readonly last_seq: number
  readonly last_at: string
  readonly preview: string
  /** Attachments of the last message ({kind, count}); absent when it has none. */
  readonly preview_attachments?: PreviewAttachments
  readonly dm_peer?: string
  /** The user left or was removed; kept as a tombstone so an older bump cannot resurrect it. */
  readonly removed: boolean
  readonly unread: number
  readonly mentions: number
  readonly counts_rev: number
  // User-owned.
  readonly pinned: boolean
  readonly pin_position?: number
  readonly muted: boolean
  /** Unix ms; absent with `muted` = muted until unmuted. */
  readonly muted_until?: number
  readonly archived: boolean
  /** `last_seq` when archived; a bump past it un-archives. */
  readonly archived_seq: number
  readonly marked_unread: boolean
}

/** Params of `inbox.bump` (outbox item from ConversationDO). */
export interface InboxBumpParams {
  /** The inbox owner (the outbox target). */
  readonly user?: string
  readonly conversation: string
  readonly rev: number
  readonly kind: ConversationKind
  readonly title: string
  readonly last_seq: number
  readonly last_at: string
  readonly preview: string
  readonly preview_attachments?: PreviewAttachments
  readonly unread?: number
  readonly mentions?: number
  readonly dm_peer?: string
  readonly removed?: boolean
}

/** The small per-user head next to the entry rows. */
export interface InboxHead {
  /**
   * The user who owns this inbox. Bound by the first `inbox.bump` (a system
   * op from ConversationDO, whose outbox targets this user's UserDO); user ops
   * from anyone else are refused.
   */
  readonly user?: string
  /** The position the next pin without an explicit position gets. */
  readonly next_pin: number
  /**
   * Badge totals over entries that are not removed (muted and archived included; clients filter):
   * unread messages, mentions, and conversations that are unread or marked unread. Absent in heads
   * written before totals existed; the next change computes them from the rows once.
   */
  readonly totals?: InboxTotals
}

export interface InboxTotals {
  readonly unread: number
  readonly mentions: number
  readonly conversations: number
}

const contribution = (entry: InboxEntry | undefined): InboxTotals =>
  !entry || entry.removed ? { unread: 0, mentions: 0, conversations: 0 } : { unread: entry.unread, mentions: entry.mentions, conversations: entry.unread > 0 || entry.marked_unread ? 1 : 0 }

/** Totals after one entry changes from `before` to `after`. */
export const nextTotals = (totals: InboxTotals, before: InboxEntry | undefined, after: InboxEntry | undefined): InboxTotals => {
  const a = contribution(before)
  const b = contribution(after)
  return {
    unread: Math.max(0, totals.unread - a.unread + b.unread),
    mentions: Math.max(0, totals.mentions - a.mentions + b.mentions),
    conversations: Math.max(0, totals.conversations - a.conversations + b.conversations)
  }
}

/** Totals from every entry (a head written before totals existed). */
export const totalsOf = (entries: Iterable<InboxEntry>): InboxTotals => {
  let t: InboxTotals = { unread: 0, mentions: 0, conversations: 0 }
  for (const e of entries) t = nextTotals(t, undefined, e)
  return t
}

export const INITIAL_INBOX_HEAD: InboxHead = { next_pin: 0 }

export type InboxRejectCode = "invalid_params" | "unknown_conversation" | "forbidden"
export type InboxResult<T> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly code: InboxRejectCode }

const KINDS: ReadonlyArray<ConversationKind> = ["chief", "dm", "group"]
const isCount = (value: unknown): value is number => Number.isInteger(value) && (value as number) >= 0
const isText = (value: unknown, max: number): value is string => typeof value === "string" && value.length <= max

const validPreviewAttachments = (v: unknown): v is PreviewAttachments => {
  if (typeof v !== "object" || v === null) return false
  const o = v as Record<string, unknown>
  return Object.keys(o).length === 2 && PREVIEW_ATTACHMENT_KINDS.includes(o.kind as never) && Number.isInteger(o.count) && (o.count as number) > 0 && (o.count as number) <= 16
}

export const validBump = (params: unknown): params is InboxBumpParams => {
  if (typeof params !== "object" || params === null) return false
  const p = params as Record<string, unknown>
  return (
    isText(p.conversation, 128) &&
    p.conversation.startsWith("conv_") &&
    isCount(p.rev) &&
    (p.rev as number) > 0 &&
    KINDS.includes(p.kind as ConversationKind) &&
    isText(p.title, 1024) &&
    isCount(p.last_seq) &&
    isText(p.last_at, 32) &&
    isText(p.preview, 1024) &&
    (p.preview_attachments === undefined || validPreviewAttachments(p.preview_attachments)) &&
    (p.unread === undefined || isCount(p.unread)) &&
    (p.mentions === undefined || isCount(p.mentions)) &&
    (p.unread === undefined) === (p.mentions === undefined) &&
    (p.dm_peer === undefined || isText(p.dm_peer, 128)) &&
    (p.removed === undefined || typeof p.removed === "boolean") &&
    (p.user === undefined || isText(p.user, 128))
  )
}

const conversationFields = (bump: InboxBumpParams) => ({
  // `user` is routing, not entry data.
  rev: bump.rev,
  kind: bump.kind,
  title: bump.title,
  last_seq: bump.last_seq,
  last_at: bump.last_at,
  preview: bump.preview,
  ...(bump.preview_attachments === undefined ? {} : { preview_attachments: { kind: bump.preview_attachments.kind, count: bump.preview_attachments.count } }),
  ...(bump.dm_peer === undefined ? {} : { dm_peer: bump.dm_peer }),
  removed: bump.removed === true
})

/**
 * Max merge of one bump. Returns the same object when nothing changes, so a
 * duplicate or stale bump is a no-op. A bump whose `last_seq` passes the
 * archive point un-archives the entry.
 */
export const bumpEntry = (entry: InboxEntry | undefined, bump: InboxBumpParams): InboxEntry => {
  if (!entry) {
    const counts = bump.unread !== undefined && bump.mentions !== undefined
    return {
      conversation: bump.conversation,
      ...conversationFields(bump),
      unread: counts ? bump.unread! : 0,
      mentions: counts ? bump.mentions! : 0,
      counts_rev: counts ? bump.rev : 0,
      pinned: false,
      muted: false,
      archived: false,
      archived_seq: 0,
      marked_unread: false
    }
  }
  let next = entry
  if (bump.rev > entry.rev) {
    const { dm_peer: _peer, preview_attachments: _files, ...withoutPeer } = entry
    next = { ...withoutPeer, ...conversationFields(bump) }
  }
  // Checked for every bump, also a stale one, so the result does not depend on arrival order.
  if (next.archived && bump.last_seq > next.archived_seq) next = { ...next, archived: false }
  if (bump.unread !== undefined && bump.mentions !== undefined && bump.rev > entry.counts_rev) {
    next = { ...next, unread: bump.unread, mentions: bump.mentions, counts_rev: bump.rev }
  }
  return next
}

export type InboxUserOp =
  | { readonly op: "inbox.pin"; readonly conversation: string; readonly pinned: boolean; readonly position?: number }
  | { readonly op: "inbox.mute"; readonly conversation: string; readonly muted: boolean; readonly until?: number }
  | { readonly op: "inbox.archive"; readonly conversation: string; readonly archived: boolean }
  | { readonly op: "inbox.mark_unread"; readonly conversation: string; readonly unread: boolean }

export const USER_OPS: ReadonlySet<string> = new Set(["inbox.pin", "inbox.mute", "inbox.archive", "inbox.mark_unread"])

/** A user op on one entry. Approvals still notify a muted conversation (the push layer reads `kind` of the item). */
export const userOp = (
  head: InboxHead,
  entry: InboxEntry | undefined,
  op: string,
  params: unknown,
  now: number
): InboxResult<{ readonly head: InboxHead; readonly entry: InboxEntry }> => {
  if (typeof params !== "object" || params === null) return { ok: false, code: "invalid_params" }
  const p = params as Record<string, unknown>
  if (!entry || entry.removed) return { ok: false, code: "unknown_conversation" }
  switch (op) {
    case "inbox.pin": {
      if (typeof p.pinned !== "boolean" || (p.position !== undefined && !isCount(p.position))) return { ok: false, code: "invalid_params" }
      if (!p.pinned) {
        const { pin_position: _position, ...rest } = entry
        return { ok: true, value: { head, entry: { ...rest, pinned: false } } }
      }
      const position = (p.position as number | undefined) ?? (entry.pinned && entry.pin_position !== undefined ? entry.pin_position : head.next_pin)
      return { ok: true, value: { head: { ...head, next_pin: Math.max(head.next_pin, position + 1) }, entry: { ...entry, pinned: true, pin_position: position } } }
    }
    case "inbox.mute": {
      if (typeof p.muted !== "boolean" || (p.until !== undefined && (!isCount(p.until) || (p.until as number) <= now))) return { ok: false, code: "invalid_params" }
      const { muted_until: _until, ...rest } = entry
      const until = p.muted && p.until !== undefined ? { muted_until: p.until as number } : {}
      return { ok: true, value: { head, entry: { ...rest, muted: p.muted, ...until } } }
    }
    case "inbox.archive":
      if (typeof p.archived !== "boolean") return { ok: false, code: "invalid_params" }
      return { ok: true, value: { head, entry: { ...entry, archived: p.archived, archived_seq: p.archived ? entry.last_seq : entry.archived_seq } } }
    case "inbox.mark_unread":
      if (typeof p.unread !== "boolean") return { ok: false, code: "invalid_params" }
      return { ok: true, value: { head, entry: { ...entry, marked_unread: p.unread } } }
    default:
      return { ok: false, code: "invalid_params" }
  }
}

export const isMuted = (entry: InboxEntry, now: number): boolean => entry.muted && (entry.muted_until === undefined || now < entry.muted_until)

export interface InboxListQuery {
  readonly limit: number
  readonly include_archived?: boolean
}

/** `inbox.list`: pinned by position, then `last_at` newest first; ties by conversation id. Removed entries never show. */
export const listInbox = (entries: Iterable<InboxEntry>, query: InboxListQuery): Array<InboxEntry> => {
  const visible = [...entries].filter((entry) => !entry.removed && (query.include_archived || !entry.archived))
  visible.sort((a, b) => {
    if (a.pinned !== b.pinned) return a.pinned ? -1 : 1
    if (a.pinned && b.pinned && a.pin_position !== b.pin_position) return (a.pin_position ?? 0) - (b.pin_position ?? 0)
    if (!a.pinned && a.last_at !== b.last_at) return a.last_at < b.last_at ? 1 : -1
    return a.conversation < b.conversation ? -1 : a.conversation > b.conversation ? 1 : 0
  })
  return visible.slice(0, Math.max(0, query.limit))
}

/** A plain-record inbox (tests, a self-hosted owner without row tables). */
export interface InboxRecord {
  readonly head: InboxHead
  readonly entries: Readonly<Record<string, InboxEntry>>
}

export const emptyInbox = (): InboxRecord => ({ head: INITIAL_INBOX_HEAD, entries: {} })

/** Applies one op to a plain-record inbox; the same rules as the row-backed domain. */
export const reduceInbox = (record: InboxRecord, op: string, params: unknown, now: number): InboxResult<InboxRecord> => {
  if (op === "inbox.bump") {
    if (!validBump(params)) return { ok: false, code: "invalid_params" }
    if (params.user !== undefined && record.head.user !== undefined && params.user !== record.head.user) return { ok: false, code: "forbidden" }
    const head = record.head.user === undefined && params.user !== undefined ? { ...record.head, user: params.user } : record.head
    const entry = bumpEntry(record.entries[params.conversation], params)
    return { ok: true, value: { head, entries: { ...record.entries, [params.conversation]: entry } } }
  }
  if (!USER_OPS.has(op)) return { ok: false, code: "invalid_params" }
  const conversation = (params as { conversation?: unknown } | null)?.conversation
  const entry = typeof conversation === "string" ? record.entries[conversation] : undefined
  const result = userOp(record.head, entry, op, params, now)
  if (!result.ok) return result
  return { ok: true, value: { head: result.value.head, entries: { ...record.entries, [result.value.entry.conversation]: result.value.entry } } }
}
