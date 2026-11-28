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
/** Non-approval pushes per user per rolling hour (B10); approvals are exempt and do not count. */
export const HOURLY_PUSH_CAP = 60
export const HOUR_MS = 3600_000
/** While the user's Mac is active, a row is checked again this often (a read in the meantime clears it). */
export const FOREGROUND_RECHECK_MS = 60_000
/** A row held back by an active Mac this long settles as seen at the Mac (no late push for an old message). */
export const FOREGROUND_MAX_WAIT_MS = 30 * 60_000
/** APNs retry_later (429, 5xx, network): the row comes back after 30 s, 60 s, 120 s, then the loss is accepted. */
export const RETRY_LIMIT = 3
export const retryBackoffMs = (attempts: number) => 30_000 * 2 ** attempts
/** Rows one drain sends at most; the rest wait for the next alarm. */
const DRAIN_LIMIT = 50

export type PushSkip = "removed" | "no_message" | "own" | "before_join" | "stale" | "read" | "muted" | "agent"

export type PushCandidate = { readonly push: true; readonly seq: number; readonly approval: boolean } | { readonly push: false; readonly reason: PushSkip }

/** The committed-state rules for one applied bump. `user` is the inbox owner; `entry` is the entry after the bump. */
export const pushCandidate = (user: string, bump: homeInbox.InboxBumpParams, entry: homeInbox.InboxEntry, now: number): PushCandidate => {
  // Only an agent asks for approval (fanout.ts sets the fact only for the agent's owner); a human's flag is ignored.
  const approval = bump.last_approval === true && bump.last_author_kind === "agent"
  if (entry.removed || bump.removed === true) return { push: false, reason: "removed" }
  if (bump.last_author === undefined || bump.last_seq === 0) return { push: false, reason: "no_message" }
  if (bump.last_author === user) return { push: false, reason: "own" }
  if (bump.last_seq <= (bump.joined_seq ?? 0)) return { push: false, reason: "before_join" }
  // A redelivered older bump: the entry already shows a newer message.
  if (bump.last_seq < entry.last_seq) return { push: false, reason: "stale" }
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

/** What the alert shows, captured from the bump that queued the row (a later message never replaces it). */
export interface PushText {
  readonly title: string
  readonly preview: string
}

/**
 * The alert for one queued message: the conversation title (groups, chiefs) and the preview
 * line ("Author: text"). Null when both are empty (nothing to show, and no fallback copy exists yet).
 */
export const homeApnsMessage = (conversation: string, text: PushText, seq: number, approval: boolean, now: number): ApnsMessage | null => {
  const title = cut(text.title.trim(), 120)
  const body = cut(text.preview, 240)
  if (!title && !body) return null
  const payload = {
    aps: {
      alert: { ...(title ? { title } : {}), ...(body ? { body } : {}) },
      sound: "default",
      "thread-id": conversation,
      category: approval ? "HOME_APPROVAL" : "HOME_MESSAGE",
      ...(approval ? { "interruption-level": "time-sensitive" } : {})
    },
    cmux: { home_conversation: conversation, seq }
  }
  return { body: JSON.stringify(payload), collapseId: conversation, priority: "10", expiresAt: now + 24 * 3600_000 }
}

export interface QueuedPush extends PushText {
  readonly conversation: string
  readonly seq: number
  readonly approval: boolean
  /** The settled seq before this row (restored when APNs asks to retry). */
  readonly notified_seq: number
  /** When the row was first queued (bounds the wait behind an active Mac). */
  readonly queued_at: number
  /** APNs retry_later attempts so far. */
  readonly attempts: number
}

interface Row {
  readonly conversation: string
  readonly seq: number
  readonly notified_seq: number
  readonly approval: number
  readonly due_at: number | null
  readonly sent_at: number | null
  readonly title: string
  readonly preview: string
  readonly queued_at: number
  readonly attempts: number
}

const queued = (r: Row): QueuedPush => ({
  conversation: r.conversation,
  seq: r.seq,
  approval: r.approval === 1,
  title: r.title,
  preview: r.preview,
  notified_seq: r.notified_seq,
  queued_at: r.queued_at,
  attempts: r.attempts
})

/** The push queue of one UserDO (its SQLite; never another object's). */
export class HomePushQueue {
  constructor(private readonly sql: SqlStore) {
    sql.exec(
      `CREATE TABLE IF NOT EXISTS inbox_push (conversation TEXT PRIMARY KEY, seq INTEGER NOT NULL, notified_seq INTEGER NOT NULL DEFAULT 0, approval INTEGER NOT NULL DEFAULT 0, due_at INTEGER, sent_at INTEGER, title TEXT NOT NULL DEFAULT '', preview TEXT NOT NULL DEFAULT '', queued_at INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0)`
    )
    // Non-approval sends of the last hour (the B10 per-user cap); at most HOURLY_PUSH_CAP rows stay.
    sql.exec(`CREATE TABLE IF NOT EXISTS inbox_push_sent (at INTEGER NOT NULL)`)
  }

  private row(conversation: string): Row | undefined {
    return this.sql.exec<Row>(`SELECT * FROM inbox_push WHERE conversation = ?`, conversation)[0]
  }

  private pending(row: Row | undefined): row is Row {
    return row !== undefined && row.due_at !== null && row.seq > row.notified_seq
  }

  /**
   * Queues a push for `seq` unless the conversation already notified (or settled) that far.
   * A pending row keeps the newest message, with its text; a pending approval is never
   * replaced by a plain message (it goes at once), and an approval replaces a plain one.
   * Returns true when the row changed.
   */
  offer(conversation: string, seq: number, approval: boolean, text: PushText, now: number): boolean {
    const row = this.row(conversation)
    const notified = row?.notified_seq ?? 0
    if (seq <= notified) return false
    const pending = this.pending(row)
    if (pending) {
      if (row.approval === 1 && !approval) return false
      // Same class: an older message arriving late changes nothing.
      if ((row.approval === 1) === approval && seq <= row.seq) return false
    }
    const windowEnd = row?.sent_at === null || row?.sent_at === undefined ? now : row.sent_at + COLLAPSE_WINDOW_MS
    const due = approval ? now : Math.max(now, windowEnd)
    const dueAt = pending && row.due_at !== null ? Math.min(row.due_at, due) : due
    this.sql.exec(
      `INSERT INTO inbox_push (conversation, seq, notified_seq, approval, due_at, sent_at, title, preview, queued_at, attempts) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
       ON CONFLICT (conversation) DO UPDATE SET seq = excluded.seq, approval = excluded.approval, due_at = excluded.due_at, title = excluded.title, preview = excluded.preview, queued_at = excluded.queued_at, attempts = excluded.attempts`,
      conversation,
      seq,
      notified,
      approval ? 1 : 0,
      dueAt,
      row?.sent_at ?? null,
      text.title,
      text.preview,
      pending ? row.queued_at : now
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

  /**
   * A message the rules skipped (muted, a chief's stream, history before the join): settled
   * so a later row change for the same seq (a rename, an edit) never notifies for it. A
   * pending row is left alone: its drain rechecks the mute, and it may be an approval.
   */
  skip(conversation: string, seq: number, now: number): void {
    if (this.pending(this.row(conversation))) return
    this.settle(conversation, seq, now, false)
  }

  /** Holds a pending row until `at` (an active Mac, the hourly cap). */
  defer(conversation: string, at: number): void {
    this.sql.exec(`UPDATE inbox_push SET due_at = ? WHERE conversation = ? AND due_at IS NOT NULL AND seq > notified_seq`, at, conversation)
  }

  /**
   * APNs asked to retry the send of `row`, already settled: the row is due again at `at`,
   * unless a newer message queued since (its push supersedes this one).
   */
  reopen(row: QueuedPush, at: number): boolean {
    const now = this.row(row.conversation)
    if (!now || now.due_at !== null || now.notified_seq !== row.seq) return false
    this.sql.exec(
      `UPDATE inbox_push SET notified_seq = ?, seq = ?, approval = ?, due_at = ?, title = ?, preview = ?, attempts = ? WHERE conversation = ?`,
      row.notified_seq,
      row.seq,
      row.approval ? 1 : 0,
      at,
      row.title,
      row.preview,
      row.attempts + 1,
      row.conversation
    )
    return true
  }

  /** Non-approval sends in the hour before `now`, and when the oldest of them leaves the window. */
  budget(now: number): { readonly sent: number; readonly freeAt: number | null } {
    this.sql.exec(`DELETE FROM inbox_push_sent WHERE at <= ?`, now - HOUR_MS)
    const r = this.sql.exec<{ n: number; oldest: number | null }>(`SELECT COUNT(*) AS n, MIN(at) AS oldest FROM inbox_push_sent`)[0]
    return { sent: r?.n ?? 0, freeAt: r?.oldest === null || r?.oldest === undefined ? null : r.oldest + HOUR_MS }
  }

  recordSend(now: number): void {
    this.sql.exec(`INSERT INTO inbox_push_sent (at) VALUES (?)`, now)
  }

  /**
   * The row of `conversation` if it is still due at `now`. A drain re-reads each row after
   * its awaits: two drains can overlap (the alarm and a retried one), and the second must not
   * send what the first settled while it waited.
   */
  dueRow(conversation: string, now: number): QueuedPush | undefined {
    const row = this.row(conversation)
    return this.pending(row) && row.due_at !== null && row.due_at <= now ? queued(row) : undefined
  }

  /** Rows due now, oldest first. */
  due(now: number): ReadonlyArray<QueuedPush> {
    return this.sql.exec<Row>(`SELECT * FROM inbox_push WHERE due_at IS NOT NULL AND due_at <= ? AND seq > notified_seq ORDER BY due_at LIMIT ?`, now, DRAIN_LIMIT).map(queued)
  }

  /** When the next row is due, or null. */
  nextDueAt(): number | null {
    return this.sql.exec<{ at: number | null }>(`SELECT MIN(due_at) AS at FROM inbox_push WHERE due_at IS NOT NULL AND seq > notified_seq`)[0]?.at ?? null
  }
}
