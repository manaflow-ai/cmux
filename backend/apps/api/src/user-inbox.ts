import type { Principal } from "@cmux/ownership"
import type { ReadResult } from "./owner-do.ts"
import { inbox as homeInbox } from "@cmux/home-core"
import type { SecondaryStream } from "./secondary-stream.ts"

/**
 * One-time migration of an inbox written before the list order index (home-core order.ts):
 * reads the entry keys once, in key windows, and commits them as `inbox.reindex` system ops.
 * Batch keys name their contents, so a rerun after a crash replays what committed. The caller
 * schedules the alarm for the outbox drain.
 */
export const reindexInbox = (inbox: SecondaryStream<homeInbox.InboxHead>, entity: string): void => {
  const engine = inbox.open(entity)
  const keys: Array<string> = []
  for (let window = engine.rows.keyRange(homeInbox.TABLE_ENTRY, { limit: 1000 }); window.length > 0; window = engine.rows.keyRange(homeInbox.TABLE_ENTRY, { after: keys[keys.length - 1]!, limit: 1000 })) {
    keys.push(...window.map((r) => r.key))
  }
  const principal: Principal = { identity: "system:inbox", kind: "system" }
  for (const batch of homeInbox.inboxReindexBatches(keys)) {
    inbox.submit(principal, { t: "op", op: "inbox.reindex", params: batch.params, idempotency_key: batch.key, origin: "script" }, () => {})
  }
}

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
