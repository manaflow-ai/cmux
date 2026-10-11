import { messageDeleteWrites } from "./attachments.ts"
import { isOpen } from "./cloud.ts"
import { summary } from "./create.ts"
import type { OutboxItem, ReduceContext, ReduceResult, RowReader, RowWrite } from "./engine-types.ts"
import { rowsOf } from "./engine-types.ts"
import { mentionsOf, previewOf, type FanOut, type UnreadCounts } from "./fanout.ts"
import { formatRfc3339Millis, parseRfc3339Millis } from "./ids.ts"
import { closeExpired } from "./invite-ops.ts"
import { unreadFloor } from "./domain.ts"
import { fanOutItems, projectionItems } from "./outbox.ts"
import type { Draft } from "./request.ts"
import { inviteWrites, TABLE_MSG, TABLE_UNREAD, UNREAD_RECOUNT_LIMIT } from "./tables.ts"
import { SYSTEM_ACTOR, type ConversationHead, type Message } from "./types.ts"

/**
 * Owner hygiene (home-messaging.md section 10), run by the ConversationDO alarm as the system op
 * `conversation.sweep` with no params, so it commits like any op (ledger, event with row
 * deletes, outbox) and mirrors drop the same rows:
 *
 * - Retention: with `retention_days`, messages older than that are deleted oldest first, at most
 *   RETENTION_BATCH per commit (the alarm comes back at once while more are due). The search
 *   projection gets one `home.message.delete_through {conversation_id, seq}` row per commit
 *   (home-scale.md B7), not one delete per message. When the newest message goes, every current
 *   human gets an inbox bump with an empty preview, so no expired text stays in an inbox.
 *   Deleted messages a human had not read leave that human's stored counts (TABLE_UNREAD), the
 *   same as a retract, and that human gets a bump carrying the lower counts (never below what
 *   the remaining messages hold, see countsAfter). Stored counts of humans who left are dropped.
 * - Invites: open invites past `expires_at` become `expired` and their addresses are released,
 *   the same rule every invite op applies lazily (invite-ops.ts closeExpired).
 *
 * The op decides from `ctx.now` and the rows only; the host chooses when to run it with
 * `nextSweepAt`. A sweep with nothing due changes nothing (no event).
 */
export const SWEEP_OP = "conversation.sweep"
export const RETENTION_BATCH = 500
const DAY_MS = 24 * 3600_000

/** When a message passes the retention window (an unreadable time counts as already expired). */
const expiryOf = (days: number, message: Message): number => (parseRfc3339Millis(message.created_at) ?? 0) + days * DAY_MS

/**
 * When the owner next has hygiene work: the oldest message's retention expiry, or the earliest
 * open invite's expiry. `oldest` is the lowest-seq message row (null when there is none).
 */
export const nextSweepAt = (head: ConversationHead | null, oldest: Message | null): number | null => {
  if (!head) return null
  const times: Array<number> = []
  if (head.retention_days !== undefined && oldest) times.push(expiryOf(head.retention_days, oldest))
  for (const invite of head.invites ?? []) if (isOpen(invite)) times.push(parseRfc3339Millis(invite.expires_at) ?? 0)
  return times.length > 0 ? Math.min(...times) : null
}

const refuse = (code: string): ReduceResult<ConversationHead | null> => ({ ok: false, code, message: code })

export const reduceSweep = (head: ConversationHead, ctx: ReduceContext, actor: string): ReduceResult<ConversationHead | null> => {
  if (actor !== SYSTEM_ACTOR) return refuse("forbidden")
  const now = formatRfc3339Millis(ctx.now)
  const rows = rowsOf(ctx)
  const next: Draft = { ...head }
  closeExpired(head, next, now)
  const expired = (next.invites ?? []).filter((invite) => invite.status === "expired" && head.invites?.some((old) => old.id === invite.id && isOpen(old))).length

  const deleted: Array<Message> = []
  if (head.retention_days !== undefined) {
    // Oldest first, stopping at the first message still inside the window (a prefix by seq).
    for (const row of rows.range<Message>(TABLE_MSG, { limit: RETENTION_BATCH })) {
      if (ctx.now < expiryOf(head.retention_days, row.row)) break
      deleted.push(row.row)
    }
  }
  if (expired === 0 && deleted.length === 0) return { ok: true, state: head, value: { rev: head.rev }, changed: false }

  next.rev = head.rev + 1
  const writes: Array<RowWrite> = []
  // The message, its client-id key and its attachment references (the upload becomes collectable).
  for (const message of deleted) writes.push(...messageDeleteWrites(message))
  writes.push(...inviteWrites(head.invites ?? [], next.invites ?? []))

  const newest = rows.range<Message>(TABLE_MSG, { limit: 1, desc: true })[0]?.row ?? null
  const through = deleted.at(-1)?.seq ?? 0
  const remaining = newest && newest.seq > through ? newest : null
  const lastAt = newest?.created_at ?? head.created_at
  const counts = countsAfter(next, rows, deleted)
  for (const [user, row] of counts) writes.push({ table: TABLE_UNREAD, op: "upsert", key: user, n: null, row })
  writes.push(...leftRows(next as ConversationHead, rows))
  const fan: FanOut = { bumps: sweepBumps(next, remaining, lastAt, newest !== null && !remaining, counts), wakes: [], search: [], deliveries: [] }
  const commit = { head: next as ConversationHead, change: { kind: "conversation" as const, conversation: summary(next, remaining) } }
  const outbox: Array<OutboxItem> = [...fanOutItems(fan, undefined, next.kind), ...projectionItems(head, commit, fan, now, lastAt)]
  if (deleted.length > 0) outbox.push({ kind: "home.message.delete_through", entity: `${head.id}:through`, payload: { conversation_id: head.id, seq: through } })

  const state: ConversationHead = next.invites ? { ...next, invites: next.invites.filter(isOpen) } : next
  return {
    ok: true,
    state,
    value: {
      rev: next.rev,
      change: commit.change,
      ...(deleted.length > 0 ? { retention: { through_seq: through, deleted: deleted.length } } : {}),
      ...(expired > 0 ? { invites_expired: expired } : {})
    },
    writes,
    outbox
  }
}

/**
 * Stored counts of each current human after `deleted` go, for the humans whose counts drop (a
 * deleted unseen message counts down like a retract). Unseen means above the human's unread floor
 * (unreadFloor: the read cursor, or the join under since_join), the floor every count uses. A
 * human with no stored row is skipped: the next commit recounts from the message rows, which no
 * longer hold the deleted messages.
 *
 * A stored row may be a lower bound: a recount reads at most UNREAD_RECOUNT_LIMIT messages. So the
 * lowered count is never below what the remaining messages hold, counted by one scan of at most
 * that many rows after the deleted prefix. An exact row stays exact (the subtraction is the larger
 * value), and a capped row becomes exact when the remaining messages fit in the scan.
 */
const countsAfter = (head: ConversationHead, rows: RowReader, deleted: ReadonlyArray<Message>): Map<string, UnreadCounts> => {
  const counts = new Map<string, UnreadCounts>()
  const through = deleted.at(-1)?.seq ?? 0
  let remaining: ReadonlyArray<Message> | undefined
  for (const participant of head.participants) {
    if (participant.kind !== "human" || participant.left_at !== undefined) continue
    const prior = rows.get<UnreadCounts>(TABLE_UNREAD, participant.id)?.row
    if (!prior) continue
    // The same floor as every count (domain.ts unreadFloor): the read cursor, raised to the join under since_join.
    const floor = unreadFloor(head, participant.id)
    const unseen = deleted.filter((m) => m.author !== participant.id && m.seq > floor && m.retracted_at === undefined)
    if (unseen.length === 0) continue
    const mentioned = unseen.filter((m) => mentionsOf(m).has(participant.id)).length
    // Every row at or below `through` is deleted and this human's floor is below `through`, so every remaining row is after the floor.
    remaining ??= rows.range<Message>(TABLE_MSG, { after: through, limit: UNREAD_RECOUNT_LIMIT }).map((r) => r.row)
    const left = remaining.filter((m) => m.author !== participant.id && m.seq > floor && m.retracted_at === undefined)
    counts.set(participant.id, {
      unread: Math.max(prior.unread - unseen.length, left.length),
      mentions: Math.max(prior.mentions - mentioned, left.filter((m) => mentionsOf(m).has(participant.id)).length)
    })
  }
  return counts
}

/**
 * Stored rows of humans who left: bumps no longer reach them, so the row would only go stale (it
 * already misses every message since the leave). Dropping it makes a rejoin recount from the
 * remaining messages, the same as a conversation older than the table.
 */
const leftRows = (head: ConversationHead, rows: RowReader): Array<RowWrite> =>
  head.participants
    .filter((participant) => participant.kind === "human" && participant.left_at !== undefined && rows.get(TABLE_UNREAD, participant.id) !== undefined)
    .map((participant) => ({ table: TABLE_UNREAD, op: "delete" as const, key: participant.id }))

/**
 * Inbox bumps for a sweep: every current human when the newest message expired (the preview
 * empties), otherwise only the humans whose counts dropped (the preview stays the newest message).
 */
const sweepBumps = (head: ConversationHead, newest: Message | null, lastAt: string, newestGone: boolean, counts: ReadonlyMap<string, UnreadCounts>): FanOut["bumps"] =>
  head.participants
    .filter((participant) => participant.kind === "human" && participant.left_at === undefined && (newestGone || counts.has(participant.id)))
    .map((participant) => {
      const peer = head.kind === "dm" ? head.participants.find((other) => other.id !== participant.id)?.id : undefined
      const count = counts.get(participant.id)
      return {
        user: participant.id,
        conversation: head.id,
        rev: head.rev,
        kind: head.kind ?? "group",
        title: head.title,
        last_seq: head.last_seq,
        last_at: lastAt,
        preview: previewOf(head, newest),
        ...(count ? { unread: count.unread, mentions: count.mentions } : {}),
        ...(peer ? { dm_peer: peer } : {})
      }
    })
