import type { Domain, Principal, Reject, ReduceResult, RowWrite } from "../conversation/engine-types.ts"
import { bumpEntry, INITIAL_INBOX_HEAD, USER_OPS, userOp, validBump, type InboxEntry, type InboxHead } from "./reducer.ts"

/**
 * The inbox as a row-backed Domain for the UserDO stream `inbox:<user>`:
 * entries are rows (table `entry`, key = conversation id, n = null), so a
 * user with thousands of conversations never rewrites one JSON value. The
 * head holds only `next_pin`. `inbox.list` is `listInbox` over the rows,
 * read by the adapter.
 */
export const TABLE_ENTRY = "entry"

export type InboxParams = Readonly<Record<string, unknown>>

const refuse = (code: string): ReduceResult<InboxHead> => ({ ok: false, code, message: code })

const write = (entry: InboxEntry): RowWrite => ({ table: TABLE_ENTRY, op: "upsert", key: entry.conversation, n: null, row: entry })

export const inboxDomain: Domain<InboxHead, InboxParams> = {
  initial: () => INITIAL_INBOX_HEAD,
  // Bumps come only from ConversationDO outboxes; user ops only from the user's sessions and installs.
  authorize: (_head, op, _params, principal: Principal): Reject | undefined => {
    if (op === "inbox.bump") return principal.kind === "system" ? undefined : { code: "forbidden", message: "inbox.bump is a system op" }
    if (USER_OPS.has(op)) return principal.kind === "session" || principal.kind === "install" ? undefined : { code: "forbidden", message: `${op} needs a user session` }
    return { code: "invalid_params", message: `unknown op ${op}` }
  },
  reduce: (head, op, params, ctx) => {
    if (op === "inbox.bump") {
      if (!validBump(params)) return refuse("invalid_params")
      const current = ctx.rows.get<InboxEntry>(TABLE_ENTRY, params.conversation)?.row
      const next = bumpEntry(current, params)
      // A stale or duplicate bump is a valid no-op: no event, no write.
      if (current && JSON.stringify(current) === JSON.stringify(next)) return { ok: true, state: head, value: next, changed: false }
      return { ok: true, state: head, value: next, writes: [write(next)] }
    }
    const conversation = params.conversation
    const current = typeof conversation === "string" ? ctx.rows.get<InboxEntry>(TABLE_ENTRY, conversation)?.row : undefined
    const result = userOp(head, current, op, params, ctx.now)
    if (!result.ok) return refuse(result.code)
    return { ok: true, state: result.value.head, value: result.value.entry, writes: [write(result.value.entry)] }
  }
}
