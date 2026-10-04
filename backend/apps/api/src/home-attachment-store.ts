import { conversation } from "@cmux/home-core"
import type { SqlStore } from "@cmux/ownership"

/**
 * ConversationDO's attachment store (home-messaging.md section 2): one row per verified upload,
 * in the object's SQLite, outside the op stream (never in events or snapshots). Single writer:
 * the ConversationDO, after the Worker hashed the bytes. Reference rows (`attref`) live in the
 * engine's row table and are written in each message's own commit (home-core attachments.ts),
 * so "is this object referenced" is exact when collection runs.
 */
type Sql = Pick<SqlStore, "exec">
type Record = conversation.AttachmentRecord
type Row = { hash: string; object_key: string; mime_type: string; byte_count: number; name: string; uploaders: string; created_at: number }

const TABLE = "home_attachments"
/** The main engine's row table (OwnerEngine default prefix `own_`). */
const ENGINE_ROWS = "own_rows"
const MAX_UPLOADERS = 64

const exists = (sql: Sql) => sql.exec(`SELECT 1 AS x FROM sqlite_master WHERE type = 'table' AND name = ?`, TABLE).length > 0
const ensure = (sql: Sql) =>
  sql.exec(`CREATE TABLE IF NOT EXISTS ${TABLE} (hash TEXT PRIMARY KEY, object_key TEXT NOT NULL, mime_type TEXT NOT NULL, byte_count INTEGER NOT NULL, name TEXT NOT NULL, uploaders TEXT NOT NULL, created_at INTEGER NOT NULL)`)
const toRecord = (r: Row): Record => ({ ...r, byte_count: Number(r.byte_count), created_at: Number(r.created_at), uploaders: JSON.parse(r.uploaders) as Array<string> })

/** The record of `hash`, or undefined. Never writes (safe inside a reducer and on unbound objects). */
export const attachmentRecord = (sql: Sql, hash: string): Record | undefined => {
  if (!exists(sql)) return undefined
  const r = sql.exec<Row>(`SELECT * FROM ${TABLE} WHERE hash = ?`, hash)[0]
  return r ? toRecord(r) : undefined
}

/** Whether a message with seq above `floor` references `hash` (retracted and edited-away references are deleted rows). */
export const referencedAbove = (sql: Sql, hash: string, floor: number): boolean =>
  sql.exec(`SELECT 1 AS x FROM ${ENGINE_ROWS} WHERE tbl = ? AND k >= ? AND k < ? AND json_extract(json, '$.seq') > ? LIMIT 1`, conversation.TABLE_ATTREF, `${hash}:`, `${hash};`, floor).length > 0

/** The record when `actor` may see it: an uploader, or a message after the member's history floor references it. */
export const visibleRecord = (sql: Sql, hash: string, actor: string, floor: number): Record | null => {
  const rec = attachmentRecord(sql, hash)
  if (!rec) return null
  return rec.uploaders.includes(actor) || referencedAbove(sql, hash, floor) ? rec : null
}

/**
 * Records a verified upload. First upload wins: a later upload of the same hash adds its
 * uploader and answers the kept object's key, so the caller deletes its duplicate object.
 */
export const commitRecord = (sql: Sql, rec: Omit<Record, "uploaders"> & { uploader: string }): { state: "stored" | "exists"; record: Record } => {
  ensure(sql)
  const prior = attachmentRecord(sql, rec.hash)
  if (prior) {
    const uploaders = prior.uploaders.includes(rec.uploader) ? prior.uploaders : [...prior.uploaders, rec.uploader].slice(-MAX_UPLOADERS)
    sql.exec(`UPDATE ${TABLE} SET uploaders = ? WHERE hash = ?`, JSON.stringify(uploaders), rec.hash)
    return { state: "exists", record: { ...prior, uploaders } }
  }
  const record: Record = { hash: rec.hash, object_key: rec.object_key, mime_type: rec.mime_type, byte_count: rec.byte_count, name: rec.name, uploaders: [rec.uploader], created_at: rec.created_at }
  sql.exec(`INSERT INTO ${TABLE} (hash, object_key, mime_type, byte_count, name, uploaders, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)`, record.hash, record.object_key, record.mime_type, record.byte_count, record.name, JSON.stringify(record.uploaders), record.created_at)
  return { state: "stored", record }
}

/**
 * Forgets records older than `before` that no message references, and answers their object
 * keys. Synchronous: the reference check and the delete happen with no await between, so a
 * message.send cannot reference a record that is being collected; once the record is gone, a
 * send refuses its hash, and only then does the caller delete the R2 objects.
 */
export const forgetUnreferenced = (sql: Sql, before: number, limit: number): Array<string> => {
  if (!exists(sql)) return []
  const keys: Array<string> = []
  for (const r of sql.exec<Row>(`SELECT * FROM ${TABLE} WHERE created_at < ? ORDER BY created_at LIMIT ?`, before, limit * 4)) {
    if (keys.length >= limit) break
    if (referencedAbove(sql, r.hash, -1)) continue
    sql.exec(`DELETE FROM ${TABLE} WHERE hash = ?`, r.hash)
    keys.push(r.object_key)
  }
  return keys
}
