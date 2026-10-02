import type { Domain, Principal, Reject, ReduceResult, RowWrite } from "../conversation/engine-types.ts"
import { bumpEntry, INITIAL_INBOX_HEAD, USER_OPS, userOp, validBump, type InboxEntry, type InboxHead } from "./reducer.ts"

/**
 * The inbox as a row-backed Domain for the UserDO stream `inbox:<user>`:
 * entries are rows (table `entry`, key = conversation id, n = null), so a
 * user with thousands of conversations never rewrites one JSON value. The
 * head holds the owning user and `next_pin`. `inbox.list` is `listInbox` over
 * the rows, read by the adapter. An op that changes nothing is `changed: false`.
 */
export const TABLE_ENTRY = "entry"

export type InboxParams = Readonly<Record<string, unknown>>

const refuse = (code: string): ReduceResult<InboxHead> => ({ ok: false, code, message: code })

const write = (entry: InboxEntry): RowWrite => ({ table: TABLE_ENTRY, op: "upsert", key: entry.conversation, n: null, row: entry })

const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b)

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
      const current = ctx.rows.get<InboxEntry>(TABLE_ENTRY, params.conversation)?.row
      const { user: _user, ...bump } = params
      const next = bumpEntry(current, bump)
      // A stale or duplicate bump is a valid no-op: no event, no write.
      if (current && same(current, next) && nextHead === head) return { ok: true, state: head, value: next, changed: false }
      return { ok: true, state: nextHead, value: next, writes: current && same(current, next) ? [] : [write(next)] }
    }
    const conversation = params.conversation
    const current = typeof conversation === "string" ? ctx.rows.get<InboxEntry>(TABLE_ENTRY, conversation)?.row : undefined
    const result = userOp(head, current, op, params, ctx.now)
    if (!result.ok) return refuse(result.code)
    if (same(current, result.value.entry) && same(head, result.value.head)) return { ok: true, state: head, value: current, changed: false }
    return { ok: true, state: result.value.head, value: result.value.entry, writes: [write(result.value.entry)] }
  }
}
