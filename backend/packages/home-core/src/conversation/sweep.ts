import { isOpen } from "./cloud.ts"
import { summary } from "./create.ts"
import type { OutboxItem, ReduceContext, ReduceResult, RowWrite } from "./engine-types.ts"
import { rowsOf } from "./engine-types.ts"
import { previewOf, type FanOut } from "./fanout.ts"
import { formatRfc3339Millis, parseRfc3339Millis } from "./ids.ts"
import { closeExpired } from "./invite-ops.ts"
import { fanOutItems, projectionItems } from "./outbox.ts"
import type { Draft } from "./request.ts"
import { inviteWrites, msgKey, TABLE_MSG, TABLE_MSGKEY } from "./tables.ts"
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
  for (const message of deleted) {
    writes.push({ table: TABLE_MSG, op: "delete", key: message.id }, { table: TABLE_MSGKEY, op: "delete", key: msgKey(message.author, message.client_msg_id) })
  }
  writes.push(...inviteWrites(head.invites ?? [], next.invites ?? []))

  const newest = rows.range<Message>(TABLE_MSG, { limit: 1, desc: true })[0]?.row ?? null
  const through = deleted.at(-1)?.seq ?? 0
  const remaining = newest && newest.seq > through ? newest : null
  const lastAt = newest?.created_at ?? head.created_at
  const fan: FanOut = { bumps: newest && !remaining ? previewBumps(next, lastAt) : [], wakes: [], search: [], deliveries: [] }
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

/** The newest message expired: every current human's inbox row loses its preview (counts unchanged). */
const previewBumps = (head: ConversationHead, lastAt: string): FanOut["bumps"] =>
  head.participants
    .filter((participant) => participant.kind === "human" && participant.left_at === undefined)
    .map((participant) => {
      const peer = head.kind === "dm" ? head.participants.find((other) => other.id !== participant.id)?.id : undefined
      return {
        user: participant.id,
        conversation: head.id,
        rev: head.rev,
        kind: head.kind ?? "group",
        title: head.title,
        last_seq: head.last_seq,
        last_at: lastAt,
        preview: previewOf(head, null),
        ...(peer ? { dm_peer: peer } : {})
      }
    })
