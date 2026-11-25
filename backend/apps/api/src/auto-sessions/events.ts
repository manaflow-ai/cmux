/**
 * An Auto chat's events: its log records in order, `seq` from 1, as its holder sends them. Any device of the owner
 * reads them to show the chat; a new holder imports them. One row per event (a record is at most one request body,
 * 1 MiB, under the storage row limit).
 */
export const EVENTS_TABLE = `CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY, record TEXT NOT NULL)`

/** One event as the holder sent it: `record` is its JSON text. */
export type EventIn = { readonly seq: number; readonly record: string }
/** One stored event: `record` is still its JSON text, which the route puts into the answer as it is. */
export type EventOut = EventIn

/** The most one read answers: a page of events, cut once their records pass this size (the first always fits). */
export const MAX_EVENTS_PAGE = 256
const MAX_PAGE_BYTES = 1024 * 1024

/**
 * Which events of a request are new, given the last one stored. A repeat of stored seqs is accepted and skipped
 * (a retry after a lost answer); the rest must go on from `lastSeq + 1` with no hole. Pure.
 */
export const planAppend = <E extends { readonly seq: number }>(lastSeq: number, events: ReadonlyArray<E>): { readonly fresh: ReadonlyArray<E> } | { readonly gap: number } => {
  const fresh: Array<E> = []
  let expected = lastSeq + 1
  for (const e of events) {
    if (e.seq < expected) continue
    if (e.seq > expected) return { gap: e.seq }
    fresh.push(e)
    expected += 1
  }
  return { fresh }
}

/** Stores new events; answers the bytes they take. */
export const appendEvents = (sql: SqlStorage, events: ReadonlyArray<EventIn>): number => {
  let bytes = 0
  for (const e of events) {
    sql.exec(`INSERT INTO events (seq, record) VALUES (?, ?)`, e.seq, e.record)
    bytes += e.record.length
  }
  return bytes
}

export const readEvents = (sql: SqlStorage, after: number, limit: number): ReadonlyArray<EventOut> => {
  const out: Array<EventOut> = []
  let bytes = 0
  for (const row of sql.exec<{ seq: number; record: string }>(`SELECT seq, record FROM events WHERE seq > ? ORDER BY seq LIMIT ?`, after, Math.max(1, Math.min(limit, MAX_EVENTS_PAGE)))) {
    bytes += row.record.length
    if (out.length > 0 && bytes > MAX_PAGE_BYTES) break
    out.push({ seq: row.seq, record: row.record })
  }
  return out
}

export const dropEvents = (sql: SqlStorage): void => void sql.exec(`DELETE FROM events`)
