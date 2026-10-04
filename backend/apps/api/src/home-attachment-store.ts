import { conversation } from "@cmux/home-core"
import type { SqlStore } from "@cmux/ownership"

/**
 * ConversationDO's attachment store (home-messaging.md section 10.1), in the object's SQLite and
 * outside the op stream (never in events or snapshots). Single writer: the ConversationDO.
 *
 * - `home_attachment_objects`: one row per verified upload (hash, random object id, R2 key, type,
 *   size, etag, derived image, uploaders, quota user). No file names: names live only in message parts.
 *   The `poster*` columns hold the attachment's derived image, a video's poster or an image's
 *   preview (home-core `derivedVariantOf` picks the variant by type); the names predate previews.
 * - `home_attachment_slots`: upload slots made at intent time. States: `open` (issued),
 *   `uploading` (its one PUT or commit started), `tombstone` (a presigned slot that ended without
 *   keeping its object: its URL may still be used until it expires). A slot row lives until the
 *   alarm deletes its object key at expiry (refunding the bytes of a slot that never committed),
 *   so no upload outside a record survives.
 * - `home_attachment_sweep`: the unreferenced sweep's schedule and its (created_at, hash) cursor.
 *
 * Reference rows (`attref`) live in the engine's row table and are written in each message's own
 * commit (home-core attachments.ts), so "referenced" is exact when the sweep runs.
 */
type Sql = Pick<SqlStore, "exec">
type Record = conversation.AttachmentRecord
type Row = { hash: string; object_id: string; object_key: string; mime_type: string; byte_count: number; etag: string | null; poster?: string | null; uploaders: string; quota_user: string; created_at: number }
type Image = conversation.DerivedImage

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
  readonly state?: "open" | "uploading" | "tombstone"
  /** The declared poster (video) or preview (image): uploaded once through the Worker (`open` -> `uploading` -> `stored`) before the attachment commits. */
  readonly derived?: Image
  readonly derived_state?: "open" | "uploading" | "stored"
  readonly derived_etag?: string
}

/**
 * How long after its expiry a slot that may still receive bytes is kept: an `uploading` slot (its
 * Worker PUT may still be streaming) and every presigned slot, open or tombstone (S3 checks the
 * URL's expiry only when a request starts, so a PUT that began in time may finish later). One
 * hour covers a maximum-size (100 MB) PUT down to about 230 kbit/s; the alarm deletes the key,
 * refunds and drops the row only after it, so a late PUT never leaves an object outside the quota.
 */
export const UPLOADING_GRACE_MS = 3_600_000
/** One sweep batch examines at most this many records and forgets at most SWEEP_DELETE of them. */
export const SWEEP_SCAN = 400
export const SWEEP_DELETE = 100

const OBJECTS = "home_attachment_objects"
const SLOTS = "home_attachment_slots"
const SWEEP = "home_attachment_sweep"
/** The main engine's row table (OwnerEngine default prefix `own_`). */
const ENGINE_ROWS = "own_rows"
const MAX_UPLOADERS = 64
const GRACE = conversation.ATTACHMENT_LIMITS.unreferencedGraceMs

/** Columns added after the first schema (derived images, first posters); added once per store instance. */
const LATER_COLUMNS: ReadonlyArray<[string, string]> = [
  [OBJECTS, "poster TEXT"],
  [SLOTS, "poster TEXT"],
  [SLOTS, "poster_state TEXT"],
  [SLOTS, "poster_etag TEXT"],
  // 1 from a batch until its markSwept: a release in between (during the R2 delete) queues another pass.
  [SWEEP, "running INTEGER NOT NULL DEFAULT 0"],
  // After conversation storage deletion: when to delete the prefix again (a URL the deletion dropped may still finish a PUT).
  [SWEEP, "purge_at INTEGER"]
]
const migrated = new WeakSet<object>()
const has = (sql: Sql, table: string) => sql.exec(`SELECT 1 AS x FROM sqlite_master WHERE type = 'table' AND name = ?`, table).length > 0
const ensure = (sql: Sql) => {
  sql.exec(
    `CREATE TABLE IF NOT EXISTS ${OBJECTS} (hash TEXT PRIMARY KEY, object_id TEXT NOT NULL UNIQUE, object_key TEXT NOT NULL, mime_type TEXT NOT NULL, byte_count INTEGER NOT NULL, etag TEXT, uploaders TEXT NOT NULL, quota_user TEXT NOT NULL, created_at INTEGER NOT NULL)`
  )
  sql.exec(`CREATE INDEX IF NOT EXISTS ${OBJECTS}_created ON ${OBJECTS} (created_at)`)
  sql.exec(
    `CREATE TABLE IF NOT EXISTS ${SLOTS} (id TEXT PRIMARY KEY, hash TEXT NOT NULL, byte_count INTEGER NOT NULL, mime_type TEXT NOT NULL, actor TEXT NOT NULL, quota_user TEXT NOT NULL, object_id TEXT NOT NULL, object_key TEXT NOT NULL, mode TEXT NOT NULL, expires_at INTEGER NOT NULL, state TEXT NOT NULL DEFAULT 'open')`
  )
  sql.exec(`CREATE TABLE IF NOT EXISTS ${SWEEP} (id INTEGER PRIMARY KEY CHECK (id = 1), cutoff INTEGER NOT NULL, dirty_at INTEGER, cursor_at INTEGER, cursor_hash TEXT, redo INTEGER NOT NULL DEFAULT 0)`)
  if (migrated.has(sql)) return
  for (const [table, column] of LATER_COLUMNS) {
    const name = column.split(" ")[0]
    if (!sql.exec<{ name: string }>(`SELECT name FROM pragma_table_info('${table}')`).some((c) => c.name === name)) sql.exec(`ALTER TABLE ${table} ADD COLUMN ${column}`)
  }
  migrated.add(sql)
}
const imageOf = (json: string | null | undefined): conversation.RecordedImage | undefined => (json ? (JSON.parse(json) as conversation.RecordedImage) : undefined)
const toRecord = (r: Row): Record => {
  const variant = conversation.derivedVariantOf(r.mime_type)
  return {
    hash: r.hash,
    object_id: r.object_id,
    object_key: r.object_key,
    mime_type: r.mime_type,
    byte_count: Number(r.byte_count),
    ...(r.etag ? { etag: r.etag } : {}),
    ...(r.poster && variant ? { [variant]: imageOf(r.poster)! } : {}),
    uploaders: JSON.parse(r.uploaders) as Array<string>,
    quota_user: r.quota_user,
    created_at: Number(r.created_at)
  }
}

const keysOf = (objectKey: string, variant: conversation.DerivedVariant | undefined): Array<string> => (variant ? [objectKey, conversation.attachmentDerivedKey(objectKey, variant)] : [objectKey])
/** Every R2 key a slot may have written: its object and its derived image. */
export const slotKeys = (slot: Pick<UploadSlot, "object_key" | "mime_type">): Array<string> => keysOf(slot.object_key, conversation.derivedVariantOf(slot.mime_type))
/** Every R2 key of a record. */
export const recordKeys = (r: Record): Array<string> => keysOf(r.object_key, conversation.recordedImageOf(r)?.variant)

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

/** A new upload slot (made after the participant and quota checks). Rows leave only through the alarm or a settle. */
export const createSlot = (sql: Sql, slot: UploadSlot): void => {
  ensure(sql)
  sql.exec(
    `INSERT INTO ${SLOTS} (id, hash, byte_count, mime_type, actor, quota_user, object_id, object_key, mode, expires_at, state, poster, poster_state) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?, ?)`,
    slot.id,
    slot.hash,
    slot.byte_count,
    slot.mime_type,
    slot.actor,
    slot.quota_user,
    slot.object_id,
    slot.object_key,
    slot.mode,
    slot.expires_at,
    slot.derived ? JSON.stringify({ hash: slot.derived.hash, mime_type: slot.derived.mime_type, byte_count: slot.derived.byte_count }) : null,
    slot.derived ? "open" : null
  )
}

type SlotRow = Omit<UploadSlot, "derived" | "derived_state" | "derived_etag"> & { poster?: string | null; poster_state?: UploadSlot["derived_state"] | null; poster_etag?: string | null }
const slotRow = ({ poster, poster_state, poster_etag, ...s }: SlotRow): UploadSlot => ({
  ...s,
  byte_count: Number(s.byte_count),
  expires_at: Number(s.expires_at),
  ...(poster ? { derived: imageOf(poster)! } : {}),
  ...(poster_state ? { derived_state: poster_state } : {}),
  ...(poster_etag ? { derived_etag: poster_etag } : {})
})

/** The slot `id` in `state`, or null. */
export const slotIn = (sql: Sql, id: string, state: NonNullable<UploadSlot["state"]>): UploadSlot | null => {
  if (!has(sql, SLOTS)) return null
  const s = sql.exec<SlotRow>(`SELECT * FROM ${SLOTS} WHERE id = ? AND state = ?`, id, state)[0]
  return s ? slotRow(s) : null
}

/** The live open slot `id` of `mode` (and of `actor` when given); `consume` moves it to `uploading`, so it works once. */
export const takeSlot = (sql: Sql, id: string, mode: UploadSlot["mode"], consume: boolean, actor?: string): UploadSlot | null => {
  const s = slotIn(sql, id, "open")
  if (!s || s.mode !== mode || s.expires_at <= Date.now() || (actor !== undefined && s.actor !== actor)) return null
  if (consume) sql.exec(`UPDATE ${SLOTS} SET state = 'uploading' WHERE id = ?`, id)
  return { ...s, state: consume ? "uploading" : "open" }
}

/** Whether the slot's declared derived image (if any) is stored, so the attachment may commit. */
export const derivedReady = (slot: UploadSlot): boolean => !slot.derived || slot.derived_state === "stored"

/** The live open slot `id` whose declared derived image is still `open`; moves it to `uploading` (one PUT at a time, once stored never again). */
export const takeDerived = (sql: Sql, id: string): UploadSlot | null => {
  const s = slotIn(sql, id, "open")
  if (!s || !s.derived || s.derived_state !== "open" || s.expires_at <= Date.now()) return null
  sql.exec(`UPDATE ${SLOTS} SET poster_state = 'uploading' WHERE id = ?`, id)
  return { ...s, derived_state: "uploading" }
}

/** Ends a derived image PUT: `etag` when the bytes were verified (stored), null to let the client try again. */
export const settleDerived = (sql: Sql, id: string, etag: string | null): void => {
  if (!has(sql, SLOTS)) return
  sql.exec(`UPDATE ${SLOTS} SET poster_state = ?, poster_etag = ? WHERE id = ? AND poster_state = 'uploading'`, etag === null ? "open" : "stored", etag, id)
}

/**
 * Ends a slot. `kept`: its object became the record's. A stream slot (only this Worker writes its
 * key) is removed; a presigned slot that did not keep its object stays as a tombstone until its
 * URL expires, so the alarm deletes anything PUT to the key later.
 */
export const settleSlot = (sql: Sql, slot: UploadSlot, kept: boolean): void => {
  if (kept || slot.mode === "stream") sql.exec(`DELETE FROM ${SLOTS} WHERE id = ?`, slot.id)
  else sql.exec(`UPDATE ${SLOTS} SET state = 'tombstone' WHERE id = ?`, slot.id)
}

const DUE = `CASE WHEN state = 'uploading' OR mode = 'presigned' THEN expires_at + ${UPLOADING_GRACE_MS} ELSE expires_at END`

/** Slots whose time is up: open stream slots at expiry; uploading and presigned slots (open or tombstone) after the grace. */
export const dueSlots = (sql: Sql, now: number, limit: number): Array<UploadSlot> =>
  has(sql, SLOTS) ? sql.exec<SlotRow>(`SELECT * FROM ${SLOTS} WHERE ${DUE} <= ? ORDER BY ${DUE} LIMIT ?`, now, limit).map(slotRow) : []

export const removeSlot = (sql: Sql, id: string): void => void sql.exec(`DELETE FROM ${SLOTS} WHERE id = ?`, id)

export const nextSlotDue = (sql: Sql): number | null => {
  if (!has(sql, SLOTS)) return null
  const at = sql.exec<{ at: number | null }>(`SELECT MIN(${DUE}) AS at FROM ${SLOTS}`)[0]?.at
  return at === null || at === undefined ? null : Number(at)
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
  const record: Record = {
    hash: rec.hash,
    object_id: rec.object_id,
    object_key: rec.object_key,
    mime_type: rec.mime_type,
    byte_count: rec.byte_count,
    ...(rec.etag ? { etag: rec.etag } : {}),
    ...(rec.poster ? { poster: rec.poster } : {}),
    ...(rec.preview ? { preview: rec.preview } : {}),
    uploaders: [rec.uploader],
    quota_user: rec.quota_user,
    created_at: rec.created_at
  }
  sql.exec(
    `INSERT INTO ${OBJECTS} (hash, object_id, object_key, mime_type, byte_count, etag, poster, uploaders, quota_user, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    record.hash,
    record.object_id,
    record.object_key,
    record.mime_type,
    record.byte_count,
    record.etag ?? null,
    (record.poster ?? record.preview) ? JSON.stringify(record.poster ?? record.preview) : null,
    JSON.stringify(record.uploaders),
    record.quota_user,
    record.created_at
  )
  return { state: "stored", record }
}

/**
 * One sweep batch: from the persistent (created_at, hash) cursor, examines up to SWEEP_SCAN
 * records older than `before` and forgets up to SWEEP_DELETE that no message references. Each
 * batch moves the cursor past what it examined, so a long run of referenced records costs one
 * pass, not a hot loop; `done` when the pass reached the end (the cursor resets).
 * Synchronous: the reference check and the delete happen with no await between, so a
 * message.send cannot reference a record that is being collected; once the record is gone, a
 * send refuses its hash, and only then does the caller delete the R2 objects.
 */
export const sweepBatch = (sql: Sql, before: number): { records: Array<Record>; done: boolean } => {
  if (!has(sql, OBJECTS)) return { records: [], done: true }
  ensure(sql)
  const c = sql.exec<{ cursor_at: number | null; cursor_hash: string | null }>(`SELECT cursor_at, cursor_hash FROM ${SWEEP} WHERE id = 1`)[0]
  const at = c?.cursor_at === null || c?.cursor_at === undefined ? null : Number(c.cursor_at)
  const rows =
    at === null
      ? sql.exec<Row>(`SELECT * FROM ${OBJECTS} WHERE created_at < ? ORDER BY created_at, hash LIMIT ?`, before, SWEEP_SCAN)
      : sql.exec<Row>(`SELECT * FROM ${OBJECTS} WHERE created_at < ? AND (created_at > ? OR (created_at = ? AND hash > ?)) ORDER BY created_at, hash LIMIT ?`, before, at, at, c!.cursor_hash ?? "", SWEEP_SCAN)
  const records: Array<Record> = []
  let last: Row | undefined
  let stopped = false
  for (const r of rows) {
    last = r
    if (!referencedAbove(sql, r.hash, -1)) {
      sql.exec(`DELETE FROM ${OBJECTS} WHERE hash = ?`, r.hash)
      records.push(toRecord(r))
      if (records.length >= SWEEP_DELETE) {
        stopped = true
        break
      }
    }
  }
  const done = !stopped && rows.length < SWEEP_SCAN
  ensure(sql)
  sql.exec(`INSERT INTO ${SWEEP} (id, cutoff) VALUES (1, ?) ON CONFLICT (id) DO NOTHING`, Number.MIN_SAFE_INTEGER)
  sql.exec(`UPDATE ${SWEEP} SET cursor_at = ?, cursor_hash = ?, running = 1 WHERE id = 1`, done || !last ? null : Number(last.created_at), done || !last ? null : last.hash)
  return { records, done }
}

/** Forgets every record and slot (conversation storage deletion); answers both (the caller deletes the prefix and refunds). */
export const forgetAll = (sql: Sql): { records: Array<Record>; slots: Array<UploadSlot> } => {
  if (!has(sql, OBJECTS)) return { records: [], slots: [] }
  const records = sql.exec<Row>(`SELECT * FROM ${OBJECTS}`).map(toRecord)
  const slots = sql.exec<SlotRow>(`SELECT * FROM ${SLOTS}`).map(slotRow)
  sql.exec(`DELETE FROM ${OBJECTS}`)
  sql.exec(`DELETE FROM ${SLOTS}`)
  return { records, slots }
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

/**
 * After a batch at `now`. Not done: due again now (the cursor guarantees progress). Done: records
 * created before now - grace are covered; another pass is due only if a reference was released
 * during this one (`redo`).
 */
export const markSwept = (sql: Sql, now: number, done: boolean): void => {
  ensure(sql)
  if (!done) {
    sql.exec(`UPDATE ${SWEEP} SET dirty_at = ?, running = 0 WHERE id = 1`, now)
    return
  }
  sql.exec(`UPDATE ${SWEEP} SET cutoff = ?, dirty_at = CASE WHEN redo = 1 THEN ? ELSE NULL END, redo = 0, running = 0 WHERE id = 1`, now - GRACE, now)
}

/**
 * A reference was released (retract, edit): older records may now be collectable. During a pass
 * (a cursor is held, or a batch is awaiting its R2 delete) the next pass is queued: markSwept
 * would otherwise clear this dirty time and the release would wait for the next one.
 */
export const markDirty = (sql: Sql, at: number): void => {
  if (!has(sql, OBJECTS)) return
  ensure(sql)
  sql.exec(`INSERT INTO ${SWEEP} (id, cutoff) VALUES (1, ?) ON CONFLICT (id) DO NOTHING`, Number.MIN_SAFE_INTEGER)
  sql.exec(`UPDATE ${SWEEP} SET dirty_at = MIN(COALESCE(dirty_at, ?), ?), redo = CASE WHEN cursor_at IS NULL AND running = 0 THEN redo ELSE 1 END WHERE id = 1`, at, at)
}

/**
 * Conversation storage deletion dropped slots whose URL may still finish a PUT: the prefix is
 * deleted again at `at` (the latest dropped slot's expiry plus the upload grace).
 */
export const schedulePurge = (sql: Sql, at: number): void => {
  ensure(sql)
  sql.exec(`INSERT INTO ${SWEEP} (id, cutoff) VALUES (1, ?) ON CONFLICT (id) DO NOTHING`, Number.MIN_SAFE_INTEGER)
  sql.exec(`UPDATE ${SWEEP} SET purge_at = MAX(COALESCE(purge_at, ?), ?) WHERE id = 1`, at, at)
}

export const purgeAt = (sql: Sql): number | null => {
  if (!has(sql, SWEEP)) return null
  ensure(sql)
  const at = sql.exec<{ purge_at: number | null }>(`SELECT purge_at FROM ${SWEEP} WHERE id = 1`)[0]?.purge_at
  return at === null || at === undefined ? null : Number(at)
}

/** After the delayed prefix delete that was due at `at` (a later schedule stays). */
export const clearPurge = (sql: Sql, at: number): void => void sql.exec(`UPDATE ${SWEEP} SET purge_at = NULL WHERE id = 1 AND purge_at <= ?`, at)
