import type { ReadResult } from "./owner-do.ts"
import { inbox as homeInbox } from "@cmux/home-core"
import type { SecondaryStream } from "./secondary-stream.ts"
import { reindexInbox } from "./inbox-reindex.ts"

/**
 * Inbox reads (after the UserDO's caller check): `inbox.list` pages the entries, migrating an
 * inbox written before the order index first (`onReindex` schedules the drain alarm);
 * `inbox.dm_peer` finds an existing DM with a peer (design Q2).
 */
export const readInboxOp = (inbox: SecondaryStream<homeInbox.InboxHead>, entity: string, op: string, params: Record<string, unknown>, onReindex: () => void): ReadResult => {
  const engine = inbox.open(entity)
  if (op === "inbox.dm_peer") {
    const peer = typeof params.peer === "string" ? params.peer : ""
    return { ok: true, value: { conversation: homeInbox.dmPeer(engine.rows, peer) }, revision: String(engine.currentSeq) }
  }
  if (op === "inbox.list") {
    if (params.cursor !== undefined && (typeof params.cursor !== "string" || params.cursor.length > 256)) return { ok: false, code: "validation.invalid", message: "cursor must be a next_cursor string" }
    if (engine.currentState.ordered !== true) {
      reindexInbox(inbox, entity)
      onReindex()
    }
    const limit = typeof params.limit === "number" && params.limit > 0 ? Math.min(params.limit, homeInbox.INBOX_PAGE_LIMIT) : homeInbox.INBOX_PAGE_LIMIT
    const page = homeInbox.pageInbox(engine.rows, { limit, include_archived: params.include_archived === true, ...(params.cursor === undefined ? {} : { cursor: params.cursor as string }) })
    return { ok: true, value: page, revision: String(engine.currentSeq) }
  }
  return { ok: false, code: "validation.invalid", message: `unknown inbox read ${op}` }
}
