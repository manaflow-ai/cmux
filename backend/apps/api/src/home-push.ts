import { inbox as homeInbox } from "@cmux/home-core"
import type { SqlStore } from "@cmux/ownership"
import { cut, type ApnsMessage } from "./push/apns.ts"

/**
 * Home push (home-messaging.md section 5 step 3, home-scale.md B10). The user's UserDO
 * decides from each delivered `inbox.bump`: not removed, a message after the user joined,
 * not the user's own, not already read, not muted (an approval notifies through mute), and a
 * chief's message only for an approval or a mention (a chief streams; turn-end push needs a
 * turn-end fact on the bump, which ConversationDO does not send yet). Device facts (a push
 * token, no foreground socket) are checked when the queue drains.
 *
 * The queue (table `inbox_push`, one row per conversation, written only by this UserDO) is
 * the dedupe: a conversation notifies at most once per seq, so a redelivered, coalesced or
 * late bump never notifies twice, and a drain marks a row settled before it sends (at most
 * once, as FeedDO), so a retried drain after a crash sends nothing again.
 */

/** At most one push per conversation in this window while messages keep arriving; approvals go at once (B10). */
export const COLLAPSE_WINDOW_MS = 10_000
/** Rows one drain sends at most; the rest wait for the next alarm. */
const DRAIN_LIMIT = 50

export type PushSkip = "removed" | "no_message" | "own" | "before_join" | "read" | "muted" | "agent"

export type PushCandidate = { readonly push: true; readonly seq: number; readonly approval: boolean } | { readonly push: false; readonly reason: PushSkip }

/** The committed-state rules for one applied bump. `user` is the inbox owner. */
export const pushCandidate = (user: string, bump: homeInbox.InboxBumpParams, entry: homeInbox.InboxEntry, now: number): PushCandidate => {
  const approval = bump.last_approval === true
  if (entry.removed || bump.removed === true) return { push: false, reason: "removed" }
  if (bump.last_author === undefined || bump.last_seq === 0) return { push: false, reason: "no_message" }
  if (bump.last_author === user) return { push: false, reason: "own" }
  if (bump.last_seq <= (bump.joined_seq ?? 0)) return { push: false, reason: "before_join" }
  // Only counts this bump carries: a bump without counts leaves the entry's older ones.
  if (bump.unread === 0) return { push: false, reason: "read" }
  if (!approval && homeInbox.isMuted(entry, now)) return { push: false, reason: "muted" }
  if (!approval && bump.last_author_kind === "agent" && bump.last_mention !== true) return { push: false, reason: "agent" }
  return { push: true, seq: bump.last_seq, approval }
}

/** Rules rechecked when a queued row drains (the user may have muted, left or read it since). */
export const stillPushable = (entry: homeInbox.InboxEntry | undefined, approval: boolean, now: number): PushSkip | null => {
  if (!entry || entry.removed) return "removed"
  if (!approval && homeInbox.isMuted(entry, now)) return "muted"
  return null
}

/**
 * The alert for one conversation: its title (groups, chiefs) and the preview line ("Author:
 * text"). Null when both are empty (nothing to show, and no fallback copy exists yet).
 */
export const homeApnsMessage = (entry: homeInbox.InboxEntry, seq: number, approval: boolean, now: number): ApnsMessage | null => {
  const title = cut(entry.title.trim(), 120)
  const body = cut(entry.preview, 240)
  if (!title && !body) return null
  const payload = {
    aps: {
      alert: { ...(title ? { title } : {}), ...(body ? { body } : {}) },
      sound: "default",
      "thread-id": entry.conversation,
      category: approval ? "HOME_APPROVAL" : "HOME_MESSAGE",
      ...(approval ? { "interruption-level": "time-sensitive" } : {})
    },
    cmux: { home_conversation: entry.conversation, seq }
  }
  return { body: JSON.stringify(payload), collapseId: entry.conversation, priority: "10", expiresAt: now + 24 * 3600_000 }
}

export interface QueuedPush {
  readonly conversation: string
  readonly seq: number
  readonly approval: boolean
}

interface Row {
  readonly conversation: string
  readonly seq: number
  readonly notified_seq: number
  readonly approval: number
  readonly due_at: number | null
  readonly sent_at: number | null
}

/** The push queue of one UserDO (its SQLite; never another object's). */
export class HomePushQueue {
  constructor(private readonly sql: SqlStore) {
    sql.exec(
      `CREATE TABLE IF NOT EXISTS inbox_push (conversation TEXT PRIMARY KEY, seq INTEGER NOT NULL, notified_seq INTEGER NOT NULL DEFAULT 0, approval INTEGER NOT NULL DEFAULT 0, due_at INTEGER, sent_at INTEGER)`
    )
  }

  private row(conversation: string): Row | undefined {
    return this.sql.exec<Row>(`SELECT * FROM inbox_push WHERE conversation = ?`, conversation)[0]
  }

  /**
   * Queues a push for `seq` unless the conversation already notified (or settled) that far.
   * A pending row keeps the highest seq and an approval stays until sent. Returns true when queued.
   */
  offer(conversation: string, seq: number, approval: boolean, now: number): boolean {
    const row = this.row(conversation)
    const notified = row?.notified_seq ?? 0
    if (seq <= notified) return false
    const pending = row !== undefined && row.seq > notified && row.due_at !== null
    const nextApproval = approval || (pending && row.approval === 1)
    const windowEnd = row?.sent_at === null || row?.sent_at === undefined ? now : row.sent_at + COLLAPSE_WINDOW_MS
    const due = nextApproval ? now : Math.max(now, windowEnd)
    const dueAt = pending && row.due_at !== null ? Math.min(row.due_at, due) : due
    this.sql.exec(
      `INSERT INTO inbox_push (conversation, seq, notified_seq, approval, due_at, sent_at) VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT (conversation) DO UPDATE SET seq = excluded.seq, approval = excluded.approval, due_at = excluded.due_at`,
      conversation,
      Math.max(seq, pending ? row.seq : 0),
      notified,
      nextApproval ? 1 : 0,
      dueAt,
      row?.sent_at ?? null
    )
    return true
  }

  /** Settles the conversation through `seq` (sent or skipped); a later seq can queue again. */
  settle(conversation: string, seq: number, now: number, sent: boolean): void {
    const row = this.row(conversation)
    const notified = Math.max(row?.notified_seq ?? 0, seq)
    const rest = row !== undefined && row.seq > notified
    this.sql.exec(
      `INSERT INTO inbox_push (conversation, seq, notified_seq, approval, due_at, sent_at) VALUES (?, ?, ?, 0, NULL, ?)
       ON CONFLICT (conversation) DO UPDATE SET notified_seq = excluded.notified_seq, approval = CASE WHEN ? THEN approval ELSE 0 END, due_at = CASE WHEN ? THEN due_at ELSE NULL END, sent_at = COALESCE(excluded.sent_at, sent_at)`,
      conversation,
      Math.max(row?.seq ?? 0, seq),
      notified,
      sent ? now : null,
      rest ? 1 : 0,
      rest ? 1 : 0
    )
  }

  /** Rows due now, oldest first. */
  due(now: number): ReadonlyArray<QueuedPush> {
    return this.sql
      .exec<Row>(`SELECT * FROM inbox_push WHERE due_at IS NOT NULL AND due_at <= ? AND seq > notified_seq ORDER BY due_at LIMIT ?`, now, DRAIN_LIMIT)
      .map((r) => ({ conversation: r.conversation, seq: r.seq, approval: r.approval === 1 }))
  }

  /** When the next row is due, or null. */
  nextDueAt(): number | null {
    return this.sql.exec<{ at: number | null }>(`SELECT MIN(due_at) AS at FROM inbox_push WHERE due_at IS NOT NULL AND seq > notified_seq`)[0]?.at ?? null
  }
}
