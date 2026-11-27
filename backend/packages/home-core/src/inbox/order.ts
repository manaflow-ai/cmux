import { createHash } from "node:crypto"
import type { KeyRange } from "@cmux/ownership"
import type { RowWrite, StoredRow } from "../conversation/engine-types.ts"
import type { InboxEntry } from "./reducer.ts"

/**
 * The inbox list order as an index table (home-messaging.md section 4.2, home-scale.md B5):
 * one row per listed entry in table `entry_order`, keyed by a string that sorts in list order,
 * so `inbox.list` reads one key window per page instead of every entry.
 *
 * Sort key: pinned entries first by `pin_position`, then the others by `last_at` newest first,
 * ties by conversation id:
 *   pinned    `0:<pin_position, 16 digits>:<conversation>`
 *   unpinned  `1:<9999999999999 - last_at ms, 13 digits>:<conversation>`
 * The order key is the sort key behind a band letter: `a` for entries in the default list,
 * `b` for archived ones, so the default list never reads past archived rows. Removed entries
 * have no order row. The cursor of a page is the sort key of its last entry.
 *
 * Scale doc B5 suggested `n = last_at ms` on the entry rows; `n` must be unique per table
 * (the engine refuses a clash), and two conversations can share a millisecond, so the order
 * lives in its own keyed table instead.
 */
export const TABLE_ORDER = "entry_order"

/** One row per conversation (key = conversation id, n = null); see domain.ts. */
export const TABLE_ENTRY = "entry"

/** Tables whose writes stay with the owner (the order index is derived from the entries). */
export const INBOX_PRIVATE_TABLES: ReadonlyArray<string> = [TABLE_ORDER]

/** The largest page `inbox.list` returns (design section 6: "inbox list pages by 200"). */
export const INBOX_PAGE_LIMIT = 200

const MAX_MS = 9_999_999_999_999

const atMs = (lastAt: string): number => {
  const ms = Date.parse(lastAt)
  return Number.isFinite(ms) ? Math.min(MAX_MS, Math.max(0, ms)) : 0
}

/** The entry's position in the list, the same for the row index and the plain-record list. */
export const inboxSortKey = (entry: InboxEntry): string =>
  entry.pinned
    ? `0:${String(entry.pin_position ?? 0).padStart(16, "0")}:${entry.conversation}`
    : `1:${String(MAX_MS - atMs(entry.last_at)).padStart(13, "0")}:${entry.conversation}`

/** The entry's order row key, or null when the entry is never listed (removed). */
export const inboxOrderKey = (entry: InboxEntry): string | null => (entry.removed ? null : `${entry.archived ? "b" : "a"}${inboxSortKey(entry)}`)

export interface InboxOrderRow {
  readonly conversation: string
}

interface OrderRows {
  get<T>(table: string, key: string): StoredRow<T> | undefined
}

/**
 * The order-row writes that move `before` (the stored entry, if any) to `after`. A key that did
 * not change still gets its row when it is missing, so entries written before the index existed
 * join it on their next op.
 */
export const orderWrites = (rows: OrderRows, before: InboxEntry | undefined, after: InboxEntry): Array<RowWrite> => {
  const from = before ? inboxOrderKey(before) : null
  const to = inboxOrderKey(after)
  if (from === to && (to === null || rows.get(TABLE_ORDER, to) !== undefined)) return []
  const writes: Array<RowWrite> = []
  if (from !== null && from !== to) writes.push({ table: TABLE_ORDER, op: "delete", key: from })
  if (to !== null) writes.push({ table: TABLE_ORDER, op: "upsert", key: to, n: null, row: { conversation: after.conversation } satisfies InboxOrderRow })
  return writes
}

/** What `inbox.list` reads: point reads of entries and key windows of the order index (SqlRows, MemoryRows). */
export interface InboxPageRows extends OrderRows {
  keyRange<T>(table: string, range: KeyRange): Array<StoredRow<T>>
}

export interface InboxPageQuery {
  readonly limit: number
  readonly include_archived?: boolean
  /** `next_cursor` of the previous page; absent for the first page. Any string is only a position. */
  readonly cursor?: string
}

export interface InboxPage {
  readonly entries: Array<InboxEntry>
  /** Pass as `cursor` for the next page; null when this page is the last. */
  readonly next_cursor: string | null
}

const BANDS = { a: "b", b: "c" } as const

/**
 * One page of `inbox.list` by keyset: at most `limit + 1` order rows per band and one point
 * read per listed entry, whatever the inbox size. With archived entries the two bands merge
 * by sort key.
 */
export const pageInbox = (rows: InboxPageRows, query: InboxPageQuery): InboxPage => {
  const limit = Math.max(0, Math.min(Math.floor(query.limit), INBOX_PAGE_LIMIT))
  if (limit === 0) return { entries: [], next_cursor: null }
  const cursor = query.cursor ?? ""
  const bands: ReadonlyArray<keyof typeof BANDS> = query.include_archived ? ["a", "b"] : ["a"]
  const candidates = bands
    .flatMap((band) => rows.keyRange<InboxOrderRow>(TABLE_ORDER, { after: `${band}${cursor}`, before: BANDS[band], limit: limit + 1 }))
    .map((r) => ({ key: r.key, sort: r.key.slice(1), conversation: r.row.conversation }))
    .sort((x, y) => (x.sort < y.sort ? -1 : x.sort > y.sort ? 1 : 0))
  const page = candidates.slice(0, limit)
  const entries = page.flatMap((c) => {
    const entry = rows.get<InboxEntry>(TABLE_ENTRY, c.conversation)?.row
    // The index is written with the entry in one commit; a mismatch would be a bug, never shown twice.
    return entry && inboxOrderKey(entry) === c.key ? [entry] : []
  })
  return { entries, next_cursor: candidates.length > limit ? page[page.length - 1]!.sort : null }
}

export interface InboxReindexParams {
  readonly conversations: ReadonlyArray<string>
  /** The last batch: the head records that every entry has its order row. */
  readonly done: boolean
}

/** Conversations per `inbox.reindex` commit. */
export const INBOX_REINDEX_BATCH = 200

/**
 * The `inbox.reindex` system ops that index an inbox written before the order table existed.
 * The owner reads the entry keys once (the only full read, once per inbox) and commits them in
 * batches. Each key names the batch's contents, so a rerun after a crash replays batches that
 * committed, and a batch whose contents shifted runs again instead of replaying an older one.
 */
export const inboxReindexBatches = (conversations: ReadonlyArray<string>, size = INBOX_REINDEX_BATCH): Array<{ readonly key: string; readonly params: InboxReindexParams }> => {
  const batches: Array<{ key: string; params: InboxReindexParams }> = []
  const step = Math.max(1, size)
  for (let i = 0; i < conversations.length || (i === 0 && batches.length === 0); i += step) {
    const chunk = conversations.slice(i, i + step)
    const done = i + step >= conversations.length
    batches.push({ key: `inbox-reindex:${createHash("sha256").update(`${done ? 1 : 0}\u0000${chunk.join("\u0000")}`).digest("hex")}`, params: { conversations: chunk, done } })
  }
  return batches
}
