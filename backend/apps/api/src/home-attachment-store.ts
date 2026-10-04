import { conversation } from "@cmux/home-core"
import type { SqlStore } from "@cmux/ownership"

/**
 * ConversationDO's attachment store (home-messaging.md section 10.1), in the object's SQLite and
 * outside the op stream (never in events or snapshots). Single writer: the ConversationDO.
 *
 * - `home_attachment_objects`: one row per verified upload (hash, random object id, R2 key, type,
 *   size, etag, uploaders, quota user). No file names: names live only in message parts.
 * - `home_attachment_slots`: upload slots made at intent time and consumed once (stream PUT or
 *   presigned commit), so a slot URL carries only random ids.
 * - `home_attachment_sweep`: when the unreferenced sweep next has work (alarm schedule).
 *
 * Reference rows (`attref`) live in the engine's row table and are written in each message's own
 * commit (home-core attachments.ts), so "referenced" is exact when the sweep runs.
 */
type Sql = Pick<SqlStore, "exec">
type Record = conversation.AttachmentRecord
type Row = { hash: string; object_id: string; object_key: string; mime_type: string; byte_count: number; etag: string | null; uploaders: string; quota_user: string; created_at: number }

export interface UploadSlot {
  readonly id: string
  readonly hash: string
  readonly byte_count: number
  readonly mime_type: string
  readonly actor: string
  readonly quota_user: string
  readonly object_id: string
  readonly object_key: string
  readonly mode: "stream" | "presigned"
  readonly expires_at: number
}

const OBJECTS = "home_attachment_objects"
const SLOTS = "home_attachment_slots"
const SWEEP = "home_attachment_sweep"
/** The main engine's row table (OwnerEngine default prefix `own_`). */
const ENGINE_ROWS = "own_rows"
const MAX_UPLOADERS = 64
const GRACE = conversation.ATTACHMENT_LIMITS.unreferencedGraceMs

const has = (sql: Sql, table: string) => sql.exec(`SELECT 1 AS x FROM sqlite_master WHERE type = 'table' AND name = ?`, table).length > 0
const ensure = (sql: Sql) => {
  sql.exec(
    `CREATE TABLE IF NOT EXISTS ${OBJECTS} (hash TEXT PRIMARY KEY, object_id TEXT NOT NULL UNIQUE, object_key TEXT NOT NULL, mime_type TEXT NOT NULL, byte_count INTEGER NOT NULL, etag TEXT, uploaders TEXT NOT NULL, quota_user TEXT NOT NULL, created_at INTEGER NOT NULL)`
  )
  sql.exec(`CREATE INDEX IF NOT EXISTS ${OBJECTS}_created ON ${OBJECTS} (created_at)`)
  sql.exec(
    `CREATE TABLE IF NOT EXISTS ${SLOTS} (id TEXT PRIMARY KEY, hash TEXT NOT NULL, byte_count INTEGER NOT NULL, mime_type TEXT NOT NULL, actor TEXT NOT NULL, quota_user TEXT NOT NULL, object_id TEXT NOT NULL, object_key TEXT NOT NULL, mode TEXT NOT NULL, expires_at INTEGER NOT NULL)`
  )
  sql.exec(`CREATE TABLE IF NOT EXISTS ${SWEEP} (id INTEGER PRIMARY KEY CHECK (id = 1), cutoff INTEGER NOT NULL, dirty_at INTEGER)`)
}
const toRecord = (r: Row): Record => ({
  hash: r.hash,
  object_id: r.object_id,
  object_key: r.object_key,
  mime_type: r.mime_type,
  byte_count: Number(r.byte_count),
  ...(r.etag ? { etag: r.etag } : {}),
  uploaders: JSON.parse(r.uploaders) as Array<string>,
  quota_user: r.quota_user,
  created_at: Number(r.created_at)
})

/** A random 128-bit hex id (object ids and slot ids). */
export const randomId = () => crypto.randomUUID().replace(/-/g, "")

/** The record of `hash`, or undefined. Never writes (safe inside a reducer and on unbound objects). */
export const attachmentRecord = (sql: Sql, hash: string): Record | undefined => {
  if (!has(sql, OBJECTS)) return undefined
  const r = sql.exec<Row>(`SELECT * FROM ${OBJECTS} WHERE hash = ?`, hash)[0]
  return r ? toRecord(r) : undefined
}

export const recordByObjectId = (sql: Sql, objectId: string): Record | undefined => {
  if (!has(sql, OBJECTS)) return undefined
  const r = sql.exec<Row>(`SELECT * FROM ${OBJECTS} WHERE object_id = ?`, objectId)[0]
  return r ? toRecord(r) : undefined
}

/** Whether a message with seq above `floor` references `hash` (retracted and edited-away references are deleted rows). */
export const referencedAbove = (sql: Sql, hash: string, floor: number): boolean =>
  sql.exec(`SELECT 1 AS x FROM ${ENGINE_ROWS} WHERE tbl = ? AND k >= ? AND k < ? AND json_extract(json, '$.seq') > ? LIMIT 1`, conversation.TABLE_ATTREF, `${hash}:`, `${hash};`, floor).length > 0

/**
 * The record when `actor` may use it: an uploader of it here, or a message above the actor's
 * history floor references it. Everything else is null (callers cannot tell why).
 */
export const usableRecord = (sql: Sql, hash: string, actor: string, floor: number): Record | null => {
  const rec = attachmentRecord(sql, hash)
  if (!rec) return null
  return rec.uploaders.includes(actor) || referencedAbove(sql, hash, floor) ? rec : null
}

/** A new upload slot (made after the participant and quota checks); expired slots are pruned. */
export const createSlot = (sql: Sql, slot: UploadSlot): void => {
  ensure(sql)
  sql.exec(`DELETE FROM ${SLOTS} WHERE expires_at <= ?`, Date.now())
  sql.exec(
    `INSERT INTO ${SLOTS} (id, hash, byte_count, mime_type, actor, quota_user, object_id, object_key, mode, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    slot.id,
    slot.hash,
    slot.byte_count,
    slot.mime_type,
    slot.actor,
    slot.quota_user,
    slot.object_id,
    slot.object_key,
    slot.mode,
    slot.expires_at
  )
}

/** The live slot `id` of `mode` (and of `actor` when given); `consume` deletes it, so a slot works once. */
export const takeSlot = (sql: Sql, id: string, mode: UploadSlot["mode"], consume: boolean, actor?: string): UploadSlot | null => {
  if (!has(sql, SLOTS)) return null
  const s = sql.exec<UploadSlot>(`SELECT * FROM ${SLOTS} WHERE id = ?`, id)[0]
  if (!s || s.mode !== mode || Number(s.expires_at) <= Date.now() || (actor !== undefined && s.actor !== actor)) return null
  if (consume) sql.exec(`DELETE FROM ${SLOTS} WHERE id = ?`, id)
  return { ...s, byte_count: Number(s.byte_count), expires_at: Number(s.expires_at) }
}

/**
 * Records a verified upload. First upload wins: a later upload of the same hash adds its
 * uploader and answers the kept record, so the caller deletes its duplicate object.
 */
export const commitRecord = (sql: Sql, rec: Omit<Record, "uploaders" | "quota_user"> & { uploader: string; quota_user: string }): { state: "stored" | "exists"; record: Record } => {
  ensure(sql)
  const prior = attachmentRecord(sql, rec.hash)
  if (prior) {
    const uploaders = prior.uploaders.includes(rec.uploader) ? prior.uploaders : [...prior.uploaders, rec.uploader].slice(-MAX_UPLOADERS)
    sql.exec(`UPDATE ${OBJECTS} SET uploaders = ? WHERE hash = ?`, JSON.stringify(uploaders), rec.hash)
    return { state: "exists", record: { ...prior, uploaders } }
  }
  const record: Record = { hash: rec.hash, object_id: rec.object_id, object_key: rec.object_key, mime_type: rec.mime_type, byte_count: rec.byte_count, ...(rec.etag ? { etag: rec.etag } : {}), uploaders: [rec.uploader], quota_user: rec.quota_user, created_at: rec.created_at }
  sql.exec(
    `INSERT INTO ${OBJECTS} (hash, object_id, object_key, mime_type, byte_count, etag, uploaders, quota_user, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    record.hash,
    record.object_id,
    record.object_key,
    record.mime_type,
    record.byte_count,
    record.etag ?? null,
    JSON.stringify(record.uploaders),
    record.quota_user,
    record.created_at
  )
  return { state: "stored", record }
}

/**
 * Forgets records older than `before` that no message references, and answers them.
 * Synchronous: the reference check and the delete happen with no await between, so a
 * message.send cannot reference a record that is being collected; once the record is gone, a
 * send refuses its hash, and only then does the caller delete the R2 objects.
 */
export const forgetUnreferenced = (sql: Sql, before: number, limit: number): { records: Array<Record>; more: boolean } => {
  if (!has(sql, OBJECTS)) return { records: [], more: false }
  const records: Array<Record> = []
  const candidates = sql.exec<Row>(`SELECT * FROM ${OBJECTS} WHERE created_at < ? ORDER BY created_at LIMIT ?`, before, limit * 4 + 1)
  for (const r of candidates.slice(0, limit * 4)) {
    if (records.length >= limit) return { records, more: true }
    if (referencedAbove(sql, r.hash, -1)) continue
    sql.exec(`DELETE FROM ${OBJECTS} WHERE hash = ?`, r.hash)
    records.push(toRecord(r))
  }
  return { records, more: candidates.length > limit * 4 }
}

/** Forgets every record and slot (conversation storage deletion); answers the records. */
export const forgetAll = (sql: Sql): Array<Record> => {
  if (!has(sql, OBJECTS)) return []
  const records = sql.exec<Row>(`SELECT * FROM ${OBJECTS}`).map(toRecord)
  sql.exec(`DELETE FROM ${OBJECTS}`)
  sql.exec(`DELETE FROM ${SLOTS}`)
  return records
}

/**
 * When the sweep next has work: an explicit dirty time (a reference was released), or the
 * grace end of the oldest record not yet covered by the last sweep. Null when nothing waits.
 */
export const nextSweepAt = (sql: Sql): number | null => {
  if (!has(sql, SWEEP)) return null
  const s = sql.exec<{ cutoff: number; dirty_at: number | null }>(`SELECT cutoff, dirty_at FROM ${SWEEP} WHERE id = 1`)[0]
  const cutoff = s ? Number(s.cutoff) : Number.MIN_SAFE_INTEGER
  const oldest = sql.exec<{ at: number | null }>(`SELECT MIN(created_at) AS at FROM ${OBJECTS} WHERE created_at >= ?`, cutoff)[0]?.at
  const byAge = oldest === null || oldest === undefined ? null : Number(oldest) + GRACE
  const dirty = s?.dirty_at === null || s?.dirty_at === undefined ? null : Number(s.dirty_at)
  return byAge === null ? dirty : dirty === null ? byAge : Math.min(byAge, dirty)
}

/** After a sweep at `now`: records created before now - grace are covered; `more` keeps it due. */
export const markSwept = (sql: Sql, now: number, more: boolean): void => {
  ensure(sql)
  sql.exec(`INSERT INTO ${SWEEP} (id, cutoff, dirty_at) VALUES (1, ?, ?) ON CONFLICT (id) DO UPDATE SET cutoff = excluded.cutoff, dirty_at = excluded.dirty_at`, now - GRACE, more ? now : null)
}

/** A reference was released (retract, edit): older records may now be collectable. */
export const markDirty = (sql: Sql, at: number): void => {
  if (!has(sql, OBJECTS)) return
  sql.exec(`INSERT INTO ${SWEEP} (id, cutoff, dirty_at) VALUES (1, ?, ?) ON CONFLICT (id) DO UPDATE SET dirty_at = MIN(COALESCE(dirty_at, excluded.dirty_at), excluded.dirty_at)`, Number.MIN_SAFE_INTEGER, at)
}
