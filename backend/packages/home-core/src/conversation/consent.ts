import type { ReduceContext, ReduceResult, RowReader, RowWrite } from "./engine-types.ts"
import { rowsOf } from "./engine-types.ts"
import { formatRfc3339Millis } from "./ids.ts"
import type { ConversationHead } from "./types.ts"

/**
 * DM consent markers (home-messaging.md 16.8 and section 10). A pair is connected once both
 * have written in their DM (or one accepted the other's invite). The proof must outlive the
 * messages, because retention deletes `msg` and `msgkey` rows. So each human author of a DM
 * gets one private `consent` row (key = author id, row = { at }), written in the commit of
 * their first message there. No sweep or retention pass touches the table.
 *
 * DMs from before the markers have `msgkey` rows only. The rule is generic: any commit in a DM
 * that writes or deletes a human author's `msgkey` row adds that author's marker when it is
 * missing, in the same commit. A retention delete therefore always leaves a marker behind, and
 * the reader (ConversationDO.homeDmLink) may fall back to `msgkey` rows only while they still
 * exist. Groups get no markers (a shared group is no connection, 16.3).
 */
export const TABLE_CONSENT = "consent"
/** Same name as domain.ts TABLE_MSGKEY (kept here so this module has no import cycle). */
const MSGKEY = "msgkey"

export const hasConsentMarker = (rows: RowReader, author: string): boolean => rows.get(TABLE_CONSENT, author) !== undefined

/** `<author>:<client_msg_id>` -> author (ids never contain a colon). */
const authorOf = (key: string): string | null => {
  const i = key.indexOf(":")
  return i > 0 ? key.slice(0, i) : null
}

/** The marker upserts a commit with `writes` needs in `head` (empty outside DMs). */
export const consentMarkerWrites = (head: ConversationHead | null, writes: ReadonlyArray<RowWrite>, rows: RowReader, now: string): Array<RowWrite> => {
  if (head?.kind !== "dm") return []
  const authors = new Set<string>()
  for (const w of writes) {
    if (w.table !== MSGKEY) continue
    const author = authorOf(w.key)
    if (author && head.participants.some((p) => p.id === author && p.kind === "human")) authors.add(author)
  }
  for (const w of writes) if (w.table === TABLE_CONSENT) authors.delete(w.key)
  return [...authors].filter((author) => !hasConsentMarker(rows, author)).map((author) => ({ table: TABLE_CONSENT, op: "upsert" as const, key: author, n: null, row: { at: now } }))
}

/** Adds the markers to a successful commit's writes (domain.ts wraps every reduce with this). */
export const withConsentMarkers = <S extends ConversationHead | null>(result: ReduceResult<S>, before: ConversationHead | null, ctx: ReduceContext): ReduceResult<S> => {
  if (!result.ok || !result.writes || result.writes.length === 0) return result
  const markers = consentMarkerWrites(result.state ?? before, result.writes, rowsOf(ctx), formatRfc3339Millis(ctx.now))
  return markers.length === 0 ? result : { ...result, writes: [...result.writes, ...markers] }
}
