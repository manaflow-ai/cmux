import { tablesFor, type SqlStore } from "@cmux/ownership"
import { conversation } from "@cmux/home-core"

/**
 * Thread reads of one ConversationDO (cx-59n8.6): the replies of a root and its stats, computed
 * at read time from an expression index over the message rows (no reducer state, so the
 * conformance corpus is unchanged). A retracted reply stays in the thread read (shown as deleted)
 * but does not count in the stats (cx-59n8.9). The thread object (title, owner, resolution) is the
 * root's `thread` (thread.update, a reducer op); its status is derived here, so a reply after the
 * resolution reopens the thread without a write.
 */
const ROWS = tablesFor().rows
const MSG = conversation.TABLE_MSG
const AUTHORS = 3
/** Replies of a root that count in its stats (not retracted). */
const LIVE_REPLY = `tbl = ? AND json_extract(json, '$.thread_root') = ? AND json_extract(json, '$.retracted_at') IS NULL`
export const MAX_THREAD_PAGE = 200

export type ThreadSummary = {
  readonly root: string
  readonly reply_count: number
  readonly last_reply_seq: number | null
  readonly last_reply_at: string | null
  readonly authors: ReadonlyArray<string>
  /** Derived (conversation-thread-objects-v1): resolved while the root's resolution is newer than every live reply. */
  readonly status: conversation.ThreadStatus
  readonly title?: string
  readonly owner?: string
  /** Only while resolved. */
  readonly resolved_by?: string
  readonly resolved_at?: string
}

/** Objects whose thread index exists (once per instance; CREATE INDEX IF NOT EXISTS is idempotent anyway). */
const indexed = new WeakSet<SqlStore>()
const ensureIndex = (sql: SqlStore): void => {
  if (indexed.has(sql)) return
  sql.exec(`CREATE INDEX IF NOT EXISTS ${ROWS}_thread ON ${ROWS} (tbl, json_extract(json, '$.thread_root'), n)`)
  indexed.add(sql)
}

/** The stats of root message `root` over its replies that are not retracted, with its thread object. */
export const threadSummary = (sql: SqlStore, root: conversation.Message): ThreadSummary => {
  const stats = threadStats(sql, root.id)
  const thread = root.thread
  if (!thread) return stats
  const status = conversation.threadStatus(thread, stats.last_reply_seq)
  return {
    ...stats,
    status,
    ...(thread.title === undefined ? {} : { title: thread.title }),
    ...(thread.owner === undefined ? {} : { owner: thread.owner }),
    ...(status === "resolved" && thread.resolved ? { resolved_by: thread.resolved.by, resolved_at: thread.resolved.at } : {})
  }
}

/** The stats of `root` over its replies that are not retracted (reply_count 0 when none). */
const threadStats = (sql: SqlStore, root: string): ThreadSummary => {
  ensureIndex(sql)
  const agg = sql.exec<{ c: number; last: number | null }>(`SELECT count(*) AS c, max(n) AS last FROM ${ROWS} WHERE ${LIVE_REPLY}`, MSG, root)[0]
  const count = Number(agg?.c ?? 0)
  if (count === 0 || agg?.last === null || agg?.last === undefined) return { root, reply_count: 0, last_reply_seq: null, last_reply_at: null, authors: [], status: "open" }
  const last = Number(agg.last)
  const lastAt = sql.exec<{ at: string }>(`SELECT json_extract(json, '$.created_at') AS at FROM ${ROWS} WHERE tbl = ? AND n = ?`, MSG, last)[0]?.at ?? null
  const authors = sql
    .exec<{ a: string }>(
      `SELECT json_extract(json, '$.author') AS a, min(n) AS first FROM ${ROWS} WHERE ${LIVE_REPLY} GROUP BY a ORDER BY first LIMIT ?`,
      MSG,
      root,
      AUTHORS
    )
    .map((r) => String(r.a))
  return { root, reply_count: count, last_reply_seq: last, last_reply_at: lastAt === null ? null : String(lastAt), authors, status: "open" }
}

/** Stats of every root in `messages` (no thread_root itself) that has replies or a thread object, in page order. */
export const threadsOf = (sql: SqlStore, messages: ReadonlyArray<unknown>): Array<ThreadSummary> =>
  messages
    .map((m) => m as conversation.Message)
    .filter((m) => typeof m?.id === "string" && m.thread_root === undefined)
    .map((m) => [m, threadSummary(sql, m)] as const)
    .filter(([m, t]) => t.reply_count > 0 || m.thread !== undefined)
    .map(([, t]) => t)

/** Replies of `root` with seq > after, ascending; one extra row decides `has_more` exactly. */
export const threadReplies = (sql: SqlStore, root: string, after: number, limit: number): { replies: Array<conversation.Message>; has_more: boolean } => {
  ensureIndex(sql)
  const rows = sql
    .exec<{ json: string }>(`SELECT json FROM ${ROWS} WHERE tbl = ? AND json_extract(json, '$.thread_root') = ? AND n > ? ORDER BY n LIMIT ?`, MSG, root, after, limit + 1)
    .map((r) => JSON.parse(r.json) as conversation.Message)
  return { replies: rows.slice(0, limit), has_more: rows.length > limit }
}
