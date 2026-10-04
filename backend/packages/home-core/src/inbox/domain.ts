import type { Domain, Principal, Reject, ReduceResult, RowReader, RowWrite } from "../conversation/engine-types.ts"
import { rowsOf } from "../conversation/engine-types.ts"
import { orderWrites, TABLE_ENTRY, type InboxReindexParams } from "./order.ts"
import { bumpEntry, INITIAL_INBOX_HEAD, nextTotals, totalsOf, USER_OPS, userOp, validBump, type InboxEntry, type InboxHead } from "./reducer.ts"

/**
 * The inbox as a row-backed Domain for the UserDO stream `inbox:<user>`:
 * entries are rows (table `entry`, key = conversation id, n = null), so a
 * user with thousands of conversations never rewrites one JSON value. The
 * head holds the owning user and `next_pin`. Every entry write also moves its
 * row in the order index (order.ts), which `inbox.list` pages with `pageInbox`.
 * An op that changes nothing is `changed: false`.
 */
export { TABLE_ENTRY }
/** One row per DM peer (key = peer participant id): the caller's DM with that peer, if any. */
export const TABLE_PEER = "peer"

export type InboxParams = Readonly<Record<string, unknown>>

const refuse = (code: string): ReduceResult<InboxHead> => ({ ok: false, code, message: code })

/** The entry row plus its order-index move. */
const write = (rows: RowReader, before: InboxEntry | undefined, entry: InboxEntry): Array<RowWrite> => [
  { table: TABLE_ENTRY, op: "upsert", key: entry.conversation, n: null, row: entry },
  ...orderWrites(rows, before, entry)
]

const MAX_REINDEX = 500

const validReindex = (params: unknown): params is InboxReindexParams => {
  if (typeof params !== "object" || params === null) return false
  const p = params as Record<string, unknown>
  return typeof p.done === "boolean" && Array.isArray(p.conversations) && p.conversations.length <= MAX_REINDEX && p.conversations.every((c) => typeof c === "string" && c.length <= 128)
}

const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b)

/** Most entries a head written before totals existed is recounted from (inbox.list reads the same bound). */
const TOTALS_SCAN_LIMIT = 10_000

/** The head with totals moved by one entry change (computed from the rows once for an old head). */
const withTotals = (head: InboxHead, rows: RowReader, before: InboxEntry | undefined, after: InboxEntry): InboxHead => {
  // The rows still hold `before` (reads see the state before this commit).
  const base = head.totals ?? totalsOf(rows.range<InboxEntry>(TABLE_ENTRY, { limit: TOTALS_SCAN_LIMIT }).map((r) => r.row))
  return { ...head, totals: nextTotals(base, before, after) }
}

const userOf = (principal: Principal): string | undefined =>
  principal.user === undefined ? undefined : principal.user.startsWith("user_") ? principal.user : `user_${principal.user}`

/**
 * The `peer` index (design section 17 Q2): the first live DM per peer wins, so a later
 * address-based DM never hides an older one. A DM the user left (a removed entry) releases the
 * peer, and the next bump of another live DM with that peer takes it. Derived from the merged
 * entry, so a stale bump never moves it.
 */
const peerWrites = (rows: RowReader, entry: InboxEntry): Array<RowWrite> => {
  const peer = entry.dm_peer
  if (peer === undefined) return []
  const indexed = rows.get<{ conversation: string }>(TABLE_PEER, peer)?.row.conversation
  if (entry.removed) return indexed === entry.conversation ? [{ table: TABLE_PEER, op: "delete", key: peer }] : []
  if (indexed !== undefined) return []
  return [{ table: TABLE_PEER, op: "upsert", key: peer, n: null, row: { conversation: entry.conversation } }]
}

export const inboxDomain: Domain<InboxHead, InboxParams> = {
  initial: () => INITIAL_INBOX_HEAD,
  // Bumps come only from ConversationDO outboxes; user ops only from the owner's sessions and installs.
  authorize: (head, op, _params, principal): Reject | undefined => {
    if (op === "inbox.bump" || op === "inbox.reindex") return principal.kind === "system" ? undefined : { code: "forbidden", message: `${op} is a system op` }
    if (!USER_OPS.has(op)) return { code: "invalid_params", message: `unknown op ${op}` }
    if (principal.kind !== "session" && principal.kind !== "install") return { code: "forbidden", message: `${op} needs a user session` }
    if (head.user === undefined || userOf(principal) !== head.user) return { code: "forbidden", message: "not this inbox's owner" }
    return undefined
  },
  reduce: (head, op, params, ctx) => {
    if (op === "inbox.bump") {
      if (!validBump(params)) return refuse("invalid_params")
      if (params.user !== undefined && head.user !== undefined && params.user !== head.user) return refuse("forbidden")
      const nextHead: InboxHead = head.user === undefined && params.user !== undefined ? { ...head, user: params.user } : head
      const current = rowsOf(ctx).get<InboxEntry>(TABLE_ENTRY, params.conversation)?.row
      const { user: _user, ...bump } = params
      const next = bumpEntry(current, bump)
      const changedEntry = !(current && same(current, next))
      const headWithTotals = changedEntry ? withTotals(nextHead, rowsOf(ctx), current, next) : nextHead
      const writes: Array<RowWrite> = [...(changedEntry ? write(rowsOf(ctx), current, next) : orderWrites(rowsOf(ctx), current, next)), ...peerWrites(rowsOf(ctx), next)]
      // A stale or duplicate bump is a valid no-op: no event, no write.
      if (writes.length === 0 && nextHead === head) return { ok: true, state: head, value: next, changed: false }
      return { ok: true, state: headWithTotals, value: next, writes }
    }
    if (op === "inbox.reindex") {
      if (!validReindex(params)) return refuse("invalid_params")
      const writes = params.conversations.flatMap((conversation) => {
        const entry = rowsOf(ctx).get<InboxEntry>(TABLE_ENTRY, conversation)?.row
        return entry ? orderWrites(rowsOf(ctx), entry, entry) : []
      })
      const nextHead: InboxHead = params.done && head.ordered !== true ? { ...head, ordered: true } : head
      if (writes.length === 0 && nextHead === head) return { ok: true, state: head, value: null, changed: false }
      return { ok: true, state: nextHead, value: null, writes }
    }
    const conversation = params.conversation
    const current = typeof conversation === "string" ? rowsOf(ctx).get<InboxEntry>(TABLE_ENTRY, conversation)?.row : undefined
    const result = userOp(head, current, op, params, ctx.now)
    if (!result.ok) return refuse(result.code)
    if (same(current, result.value.entry) && same(head, result.value.head)) {
      // Nothing changed, but an entry from before the order index joins it here.
      const writes = current ? orderWrites(rowsOf(ctx), current, current) : []
      return writes.length === 0 ? { ok: true, state: head, value: current, changed: false } : { ok: true, state: head, value: current, writes }
    }
    return { ok: true, state: withTotals(result.value.head, rowsOf(ctx), current, result.value.entry), value: result.value.entry, writes: write(rowsOf(ctx), current, result.value.entry) }
  }
}

/**
 * Read `inbox.dm_peer {peer}` (design section 17 Q2): the caller's existing DM with
 * `peer`, which may have a address-based id after an invite was accepted. The
 * Worker calls it before it derives a DM id with dmConversationId.
 */
export const dmPeer = (rows: RowReader, peer: string): string | null =>
  rows.get<{ conversation: string }>(TABLE_PEER, peer)?.row.conversation ?? null
