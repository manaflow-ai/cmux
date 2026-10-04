import type { Domain, Principal, Reject, ReduceResult, RowReader, RowWrite } from "../conversation/engine-types.ts"
import { rowsOf } from "../conversation/engine-types.ts"
import { bumpEntry, INITIAL_INBOX_HEAD, nextTotals, totalsOf, USER_OPS, userOp, validBump, type InboxEntry, type InboxHead } from "./reducer.ts"

/**
 * The inbox as a row-backed Domain for the UserDO stream `inbox:<user>`:
 * entries are rows (table `entry`, key = conversation id, n = null), so a
 * user with thousands of conversations never rewrites one JSON value. The
 * head holds the owning user and `next_pin`. `inbox.list` is `listInbox` over
 * the rows, read by the adapter. An op that changes nothing is `changed: false`.
 */
export const TABLE_ENTRY = "entry"
/** One row per DM peer (key = peer participant id): the caller's DM with that peer, if any. */
export const TABLE_PEER = "peer"

export type InboxParams = Readonly<Record<string, unknown>>

const refuse = (code: string): ReduceResult<InboxHead> => ({ ok: false, code, message: code })

const write = (entry: InboxEntry): RowWrite => ({ table: TABLE_ENTRY, op: "upsert", key: entry.conversation, n: null, row: entry })

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

export const inboxDomain: Domain<InboxHead, InboxParams> = {
  initial: () => INITIAL_INBOX_HEAD,
  // Bumps come only from ConversationDO outboxes; user ops only from the owner's sessions and installs.
  authorize: (head, op, _params, principal): Reject | undefined => {
    if (op === "inbox.bump") return principal.kind === "system" ? undefined : { code: "forbidden", message: "inbox.bump is a system op" }
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
      // The first DM per peer wins the index, so a later address-based DM never hides an older one.
      const peer = next.dm_peer
      const indexPeer = peer !== undefined && rowsOf(ctx).get(TABLE_PEER, peer) === undefined
      const changedEntry = !(current && same(current, next))
      const headWithTotals = changedEntry ? withTotals(nextHead, rowsOf(ctx), current, next) : nextHead
      const writes: Array<RowWrite> = [
        ...(changedEntry ? [write(next)] : []),
        ...(indexPeer ? [{ table: TABLE_PEER, op: "upsert" as const, key: peer!, n: null, row: { conversation: next.conversation } }] : [])
      ]
      // A stale or duplicate bump is a valid no-op: no event, no write.
      if (writes.length === 0 && nextHead === head) return { ok: true, state: head, value: next, changed: false }
      return { ok: true, state: headWithTotals, value: next, writes }
    }
    const conversation = params.conversation
    const current = typeof conversation === "string" ? rowsOf(ctx).get<InboxEntry>(TABLE_ENTRY, conversation)?.row : undefined
    const result = userOp(head, current, op, params, ctx.now)
    if (!result.ok) return refuse(result.code)
    if (same(current, result.value.entry) && same(head, result.value.head)) return { ok: true, state: head, value: current, changed: false }
    return { ok: true, state: withTotals(result.value.head, rowsOf(ctx), current, result.value.entry), value: result.value.entry, writes: [write(result.value.entry)] }
  }
}

/**
 * Read `inbox.dm_peer {peer}` (design section 17 Q2): the caller's existing DM with
 * `peer`, which may have a address-based id after an invite was accepted. The
 * Worker calls it before it derives a DM id with dmConversationId.
 */
export const dmPeer = (rows: RowReader, peer: string): string | null =>
  rows.get<{ conversation: string }>(TABLE_PEER, peer)?.row.conversation ?? null
