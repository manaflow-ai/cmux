import type { InboxState } from "./model.ts"

/**
 * An Auto chat's inbox: what every device sends to it through the Cloud, numbered from 1 in arrival order. The
 * holder reads what it has not acked and acks through a number. A message id is taken once: the same id again
 * answers what the first answered, so a retry after a lost answer sends nothing twice.
 */
export const INBOX_TABLE = `CREATE TABLE IF NOT EXISTS inbox (n INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, text TEXT, state TEXT NOT NULL, at INTEGER NOT NULL)`

export type InboxMessage = { readonly n: number; readonly id: string; readonly text: string; readonly at: number }

/** Acked messages keep their id this long (counted in messages), so a late retry of one is still known. */
const KEEP_ACKED = 256
/** The most one read answers; cut once the texts pass the size (the first always fits). */
const MAX_PAGE = 64
const MAX_PAGE_BYTES = 1024 * 1024

export const sentState = (sql: SqlStorage, id: string): InboxState | null => sql.exec<{ state: string }>(`SELECT state FROM inbox WHERE id = ?`, id).toArray()[0]?.state as InboxState ?? null

export const addMessage = (sql: SqlStorage, n: number, id: string, text: string, state: InboxState, at: number): void =>
  void sql.exec(`INSERT INTO inbox (n, id, text, state, at) VALUES (?, ?, ?, ?, ?)`, n, id, text, state, at)

/** The messages after `after` that the holder has not acked. */
export const readInbox = (sql: SqlStorage, after: number, acked: number): ReadonlyArray<InboxMessage> => {
  const out: Array<InboxMessage> = []
  let bytes = 0
  for (const row of sql.exec<{ n: number; id: string; text: string; at: number }>(`SELECT n, id, text, at FROM inbox WHERE n > ? AND text IS NOT NULL ORDER BY n LIMIT ?`, Math.max(after, acked), MAX_PAGE)) {
    bytes += row.text.length
    if (out.length > 0 && bytes > MAX_PAGE_BYTES) break
    out.push({ n: row.n, id: row.id, text: row.text, at: row.at })
  }
  return out
}

/** The holder took every message through `through`: their text goes, their ids stay a while for repeats. */
export const ackInbox = (sql: SqlStorage, through: number): void => {
  sql.exec(`UPDATE inbox SET text = NULL WHERE n <= ? AND text IS NOT NULL`, through)
  sql.exec(`DELETE FROM inbox WHERE n <= ?`, through - KEEP_ACKED)
}

export const dropInbox = (sql: SqlStorage): void => void sql.exec(`UPDATE inbox SET text = NULL`)
