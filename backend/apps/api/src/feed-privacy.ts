import type { LedgerReplyRedaction } from "@cmux/ownership"
import type { FeedState } from "./domains/feed.ts"

/**
 * Feed text (title, body, prompt, poster label) lives only in the item, which the owner prunes
 * (feed.md 4, privacy review 2026-10-03). Two stores outlive items and keep none of it:
 * - events (30 days / 10,000 events): feed.post keeps only its type and kind, feed.adopt only the
 *   item id. Clients mirror the owner-written items attached to each event, never ops.
 * - the request ledger (decided keys, 7 days; an item can be evicted sooner): feed.post and
 *   feed.adopt replies keep only the item id. A retried key answers with the current item, or
 *   `selector.not_found` once the item is gone.
 */
export const redactFeedParams = (op: string, params: unknown): unknown => {
  const p = (params ?? {}) as { type?: unknown; kind?: unknown; item?: { id?: unknown } }
  if (op === "feed.post") return { type: p.type, kind: p.kind, redacted: true }
  if (op === "feed.adopt") return { item: { id: p.item?.id }, redacted: true }
  return params
}

const itemReplyOps: ReadonlySet<string> = new Set(["feed.post", "feed.adopt"])

export const feedLedgerReply: LedgerReplyRedaction = {
  store: (op, value) => {
    if (!itemReplyOps.has(op)) return value
    const v = (value ?? {}) as { item?: { id?: unknown }; deduped?: unknown }
    return { item: { id: v.item?.id }, ...(v.deduped === undefined ? {} : { deduped: v.deduped }) }
  },
  replay: (op, stored, state) => {
    if (!itemReplyOps.has(op)) return { ok: true, value: stored }
    const v = (stored ?? {}) as { item?: { id?: unknown }; deduped?: unknown }
    const item = typeof v.item?.id === "string" ? (state as FeedState).items[v.item.id] : undefined
    if (!item) return { ok: false, code: "selector.not_found", message: "the item of this request is gone" }
    return { ok: true, value: { item, ...(v.deduped === undefined ? {} : { deduped: v.deduped }) } }
  }
}

export const FEED_ENGINE_OPTIONS = { eventsNotReplayed: true, redact: { params: redactFeedParams }, ledgerReply: feedLedgerReply }

/**
 * Text written without the redaction (before it existed, or by a stale deploy) is scrubbed on
 * bind past a per-object high-water mark. v2: the v1 run-once markers missed events a stale
 * build wrote after the first scrub (2026-10-03), so v2 rescans once.
 */
export const scrubFeedText = (engine: { scrubStored(op: string, marker: string): number }): void => {
  engine.scrubStored("feed.post", "feed-text-v2")
  engine.scrubStored("feed.adopt", "feed-text-v2-adopt")
}
