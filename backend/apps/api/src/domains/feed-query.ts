import type { FeedItem, FeedList } from "@cmux/protocol"
import { isActive } from "./feed-state.ts"

/**
 * Owner-side reads of the feed (plans/cmux-next/feed.md 6 and 11): one order
 * and one grouping for every client, so views never rank items themselves.
 * Pure; the local feed server uses the same rules.
 */

export interface FeedFilterValue {
  readonly poster_kind?: string
  readonly thread?: string
  readonly workspace?: string
  readonly kind?: string
}

export const matchesFilter = (i: FeedItem, f: FeedFilterValue) =>
  (f.poster_kind === undefined || i.poster.kind === f.poster_kind) &&
  (f.thread === undefined || i.thread === f.thread) &&
  (f.workspace === undefined || i.context.workspace === f.workspace) &&
  (f.kind === undefined || i.kind === f.kind)

const PRIORITY_RANK: Readonly<Record<string, number>> = { urgent: 0, high: 1, normal: 2, low: 3 }

/** Urgent order: open requests (priority, then oldest first), then unread active items, then the rest newest first. */
export const urgentCompare = (a: FeedItem, b: FeedItem) => {
  const tier = (i: FeedItem) => (i.type === "request" && i.state === "open" ? 0 : isActive(i) && i.read_at === null ? 1 : 2)
  const ta = tier(a)
  const tb = tier(b)
  if (ta !== tb) return ta - tb
  if (ta === 0) return PRIORITY_RANK[a.priority]! - PRIORITY_RANK[b.priority]! || a.order - b.order
  return b.order - a.order
}

type ListParams = typeof FeedList.params.Type

export const listItems = (items: ReadonlyArray<FeedItem>, f: ListParams, now: number) => {
  const q = f.query?.toLowerCase()
  const selected = items
    .filter((i) => (f.state === undefined || f.state === "all" ? true : f.state === "open" ? i.state === "open" : i.state !== "open"))
    .filter((i) => f.type === undefined || i.type === f.type)
    .filter((i) => matchesFilter(i, f))
    .filter((i) => f.unread === undefined || (i.read_at === null) === f.unread)
    .filter((i) => f.needs_response === undefined || (i.type === "request" && i.state === "open") === f.needs_response)
    .filter((i) => (f.archived === true ? i.archived_at !== null : i.archived_at === null))
    // A snoozed item leaves the active list until it wakes (the owner's alarm brings it back).
    .filter((i) => f.archived === true || i.snoozed_until === null || i.snoozed_until <= now)
    .filter((i) => q === undefined || i.title.toLowerCase().includes(q) || i.body.toLowerCase().includes(q))
    .sort(f.order === "recent" ? (a, b) => b.order - a.order : urgentCompare)
  const start = f.after === undefined ? 0 : selected.findIndex((i) => i.id === f.after) + 1
  const limit = f.limit ?? 100
  const page = selected.slice(start, start + limit)
  const next = start + limit < selected.length ? page[page.length - 1]!.id : null
  const groups = f.group_by === undefined ? undefined : groupItems(page, f.group_by)
  return { items: page, next, ...(groups ? { groups } : {}) }
}

/** Groups in first-appearance order of the page, so the groups follow the owner's ranking. */
export const groupItems = (items: ReadonlyArray<FeedItem>, by: "thread" | "poster" | "workspace") => {
  const groups = new Map<string, { key: string; label: string; items: Array<string> }>()
  for (const i of items) {
    const key = by === "thread" ? (i.thread === null ? `item:${i.id}` : `thread:${i.poster.scope}:${i.thread}`) : by === "poster" ? i.poster.scope : (i.context.workspace ?? "")
    const label = by === "workspace" ? (i.context.workspace ?? "") : i.poster.label || i.poster.kind
    const g = groups.get(key) ?? { key, label, items: [] }
    g.items.push(i.id)
    groups.set(key, g)
  }
  return [...groups.values()]
}
