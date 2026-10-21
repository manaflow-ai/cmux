import type { ReadResult } from "./owner-do.ts"
import { inbox as homeInbox } from "@cmux/home-core"
import type { SecondaryStream } from "./secondary-stream.ts"
import { reindexInbox } from "./inbox-reindex.ts"
import type { Env } from "./env.ts"

/** Large groups whose rows one `inbox.list` page pulls at most (each is one RPC to its conversation). */
export const MAX_LARGE_PULLS = 50

type InboxViewStub = { inboxView(entity: string, user: string): Promise<{ title: string; rev: number; last_seq: number; last_at: string; preview: string; unread: number; mentions: number; member_count: number } | null> }

/**
 * Pulls the rows of large groups on one `inbox.list` page from their conversations
 * (home-core conversation/large.ts): a large group bumps only the people a commit names, so the
 * stored entry may be behind. The user-owned fields (pin, mute, archive, marked unread) stay; a
 * conversation that no longer counts the user as a member drops out of the page. A failed pull
 * keeps the stored entry.
 */
export const pullLargeRows = async (env: Env, user: string, result: ReadResult): Promise<ReadResult> => {
  if (!result.ok) return result
  const page = result.value as { entries: Array<homeInbox.InboxEntry> }
  const large = page.entries.filter((entry) => entry.large === true).slice(0, MAX_LARGE_PULLS)
  if (large.length === 0) return result
  const views = new Map(
    await Promise.all(
      large.map(async (entry) => {
        const stub = env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(entry.conversation)) as unknown as InboxViewStub
        const view = await stub.inboxView(entry.conversation, user).catch(() => undefined)
        return [entry.conversation, view] as const
      })
    )
  )
  const entries = page.entries.flatMap((entry) => {
    const view = views.get(entry.conversation)
    if (view === undefined) return [entry]
    if (view === null) return []
    const { rev: _rev, member_count, ...fields } = view
    return [{ ...entry, ...fields, member_count }]
  })
  return { ...result, value: { ...page, entries } }
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
