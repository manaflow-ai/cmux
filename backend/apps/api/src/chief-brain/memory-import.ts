import { bytes } from "./memory.ts"

/**
 * A copy of a Mac Chief's OptChat memory into a hosted Chief's brain (the Home migration to the
 * Hosted Chief). The Mac sends its store's own export lines verbatim (`optchat-chief memory export
 * --text`: main/<day>.jsonl `{i, kind, text, size, date}` and tree/<day>.jsonl `{l, i, text, size}`),
 * which are the rows of `oc_message` and `oc_node` here: the same OptChat core makes and reads both,
 * so the summaries the Mac already paid for are kept. Only into an empty memory, only while the brain
 * is off (no wake appends in between), messages in id order; `done` checks the nodes and folds the view.
 * The Mac's memory is only read (its export runs read-only); nothing is sent back to it.
 */
export type ImportStatus = { readonly count: number; readonly nodes: number; readonly state: "empty" | "importing" | "done" | "live" }
export type ImportBody = { readonly after: number; readonly main: ReadonlyArray<string>; readonly tree: ReadonlyArray<string>; readonly done: boolean }
export type ImportFail = { readonly ok: false; readonly status: number; readonly code: string; readonly message: string; readonly extra?: Record<string, unknown> }

const KINDS = new Set(["user", "talk", "tool", "echo", "note", "ai"])
/** One request: the Worker reads at most this many lines (the body is capped at 1 MiB before). */
const MAX_LINES = 20_000
/** A node's level: 2^40 messages is far above any memory. */
const MAX_LEVEL = 40
export const MAX_IMPORT_BODY = 1024 * 1024

export const IMPORT_SCHEMA = `CREATE TABLE IF NOT EXISTS oc_import (id INTEGER PRIMARY KEY CHECK (id = 1), state TEXT NOT NULL)`

/** A copy is under way: the brain runs no turn and no compactor call until its last batch (cheap: one row). */
export const importing = (sql: SqlStorage): boolean => sql.exec<{ state: string }>(`SELECT state FROM oc_import WHERE id = 1`).toArray()[0]?.state === "importing"

const bad = (message: string, extra?: Record<string, unknown>): ImportFail => ({ ok: false, status: 400, code: "validation.invalid", message, ...(extra ? { extra } : {}) })
const conflict = (code: string, message: string, extra?: Record<string, unknown>): ImportFail => ({ ok: false, status: 409, code, message, ...(extra ? { extra } : {}) })

export const importStatus = (sql: SqlStorage): ImportStatus => {
  sql.exec(IMPORT_SCHEMA)
  const count = Number(sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM oc_message`).one().n)
  const nodes = Number(sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM oc_node`).one().n)
  const saved = sql.exec<{ state: string }>(`SELECT state FROM oc_import WHERE id = 1`).toArray()[0]?.state
  const state = saved === "importing" || saved === "done" ? saved : count === 0 && nodes === 0 ? "empty" : "live"
  return { count, nodes, state }
}

/** The request body, checked for shape only (lines are parsed in `importBatch`). */
export const parseImportBody = (raw: unknown): ImportBody | ImportFail => {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return bad("body is {after, main, tree, done}")
  const b = raw as Record<string, unknown>
  const lines = (v: unknown) => (v === undefined ? [] : Array.isArray(v) && v.every((s) => typeof s === "string") ? (v as string[]) : null)
  const main = lines(b.main)
  const tree = lines(b.tree)
  if (!Number.isInteger(b.after) || (b.after as number) < 0) return bad("after is the count of messages already stored")
  if (!main || !tree || main.length + tree.length > MAX_LINES) return bad(`main and tree are arrays of export lines (at most ${MAX_LINES})`)
  if (b.done !== undefined && typeof b.done !== "boolean") return bad("done is a boolean")
  return { after: b.after as number, main, tree, done: b.done === true }
}

const object = (line: string): Record<string, unknown> | null => {
  try {
    const v = JSON.parse(line) as unknown
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null
  } catch {
    return null
  }
}

/**
 * Stores one batch. `brainOn`: the brain answers (a wake could append between batches): refused.
 * Returns the status after the batch; after `done`, the caller reloads the memory.
 */
export const importBatch = (sql: SqlStorage, storage: DurableObjectStorage, body: ImportBody, brainOn: boolean): ImportStatus | ImportFail => {
  const before = importStatus(sql)
  if (before.state === "done") return conflict("memory_import_done", "this Chief's memory copy is done", { count: before.count })
  if (before.state === "live") return conflict("memory_not_empty", "this Chief already has its own memory", { count: before.count })
  if (brainOn) return conflict("brain_on", "turn the Chief's brain off for the copy, then on again")
  // A turn of this brain that runs or waits (it started before the brain was turned off) would append to the log.
  const busy = sql.exec(`SELECT 1 FROM cb_inbox WHERE state IN ('queued', 'running') UNION ALL SELECT 1 FROM cb_turn WHERE status NOT IN ('done', 'failed') LIMIT 1`).toArray().length > 0
  if (busy) return conflict("brain_busy", "a Chief turn runs here: copy after it ends")
  if (body.after !== before.count) return conflict("out_of_order", `the memory holds ${before.count} messages, not ${body.after}`, { count: before.count })
  const messages: Array<{ i: number; kind: string; text: string; size: number; date: string }> = []
  for (const [k, line] of body.main.entries()) {
    const m = object(line)
    const i = before.count + k
    const at = typeof m?.date === "string" ? Date.parse(m.date) : Number.NaN
    if (!m || m.i !== i || typeof m.kind !== "string" || !KINDS.has(m.kind) || typeof m.text !== "string" || !Number.isFinite(at)) {
      return bad(`main line ${k} is not message ${i} {i, kind, text, date}`, { line: k })
    }
    messages.push({ i, kind: m.kind, text: m.text, size: bytes(`${m.kind}: ${m.text}`), date: new Date(at).toISOString() })
  }
  const nodes: Array<{ l: number; i: number; text: string }> = []
  for (const [k, line] of body.tree.entries()) {
    const n = object(line)
    if (!n || !Number.isInteger(n.l) || (n.l as number) < 0 || (n.l as number) > MAX_LEVEL || !Number.isInteger(n.i) || (n.i as number) < 0 || typeof n.text !== "string") {
      return bad(`tree line ${k} is not a node {l, i, text}`, { line: k })
    }
    nodes.push({ l: n.l as number, i: n.i as number, text: n.text })
  }
  const count = before.count + messages.length
  if (body.done) {
    // Every node covers stored messages only: the stored ones and this batch's (2^l messages from i * 2^l).
    const top = Number(sql.exec<{ n: number | null }>(`SELECT MAX((i + 1) * (1 << l)) AS n FROM oc_node`).one().n ?? 0)
    const over = nodes.find((n) => (n.i + 1) * 2 ** n.l > count)
    if (top > count || over) return bad(`a node covers messages past the ${count} copied`, over ? { l: over.l, i: over.i } : {})
  }
  storage.transactionSync(() => {
    for (const m of messages) sql.exec(`INSERT INTO oc_message (i, kind, text, size, date) VALUES (?, ?, ?, ?, ?)`, m.i, m.kind, m.text, m.size, m.date)
    for (const n of nodes) sql.exec(`INSERT INTO oc_node (l, i, text, size) VALUES (?, ?, ?, ?) ON CONFLICT (l, i) DO NOTHING`, n.l, n.i, n.text, bytes(n.text))
    if (body.done) {
      // The view is folded again from the copied nodes at the reload: no checkpoint or frozen view of an empty memory stays.
      sql.exec(`DELETE FROM oc_checkpoint`)
      sql.exec(`DELETE FROM oc_frozen`)
    }
    sql.exec(`INSERT INTO oc_import (id, state) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET state = excluded.state`, body.done ? "done" : "importing")
  })
  return importStatus(sql)
}

// ------------------------------------------------------------------ append mode (incremental sync into a live memory)

/**
 * Append mode of `PUT /v1/chiefs/<id>/memory`: `{mode: "append", dry_run, items: [{key, kind, text, date, source}]}`.
 * Unlike the copy above it works in any state (empty, done, live) and needs no brain-off: each new item becomes one
 * `note` at the log's end whose text starts with `[imported from <source> · <kind> · <date>]` (a side: an old `user`
 * line at the end of the log must not look like a live request). The compactor builds its summaries in the background
 * (`pump`), so a turn never waits for it. `key` is sha256(kind \0 date_ms \0 text) of the SOURCE message (the Mac client
 * makes the same hash): an item whose key is known (an earlier append, or a message already stored, such as the Oct 19
 * copy) is a duplicate, so a re-run adds nothing. Items that look like credentials are rejected (second wall; the
 * client drops them first). Refused with `brain_busy` while a turn runs (it would roll back appended rows).
 */
export type AppendItem = { readonly key: string; readonly kind: string; readonly text: string; readonly date: string; readonly source: string }
export type AppendBody = { readonly mode: "append"; readonly dry_run: boolean; readonly items: ReadonlyArray<AppendItem>; readonly batch?: string }
/** `{mode: "undo", batch}`: takes back one earlier append (the log's tail) and the summaries that cover it. */
export type UndoBody = { readonly mode: "undo"; readonly batch: string }
export type AppendResult = { readonly added: number; readonly duplicate: number; readonly rejected: number; readonly count: number }

export const APPEND_SCHEMA = [
  `CREATE TABLE IF NOT EXISTS oc_import_key (key TEXT PRIMARY KEY, i INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS oc_import_mark (id INTEGER PRIMARY KEY CHECK (id = 1), hashed INTEGER NOT NULL)`,
  // One import run (a client's several requests share the id): the rows [first_i, last_i] it appended, for undo.
  `CREATE TABLE IF NOT EXISTS oc_import_batch (id TEXT PRIMARY KEY, first_i INTEGER NOT NULL, last_i INTEGER NOT NULL, at TEXT NOT NULL)`,
]
const BATCH_ID = /^[A-Za-z0-9._:-]{1,64}$/

/** null: not an append body (the copy's parser takes it). */
export const parseAppendBody = (raw: unknown): AppendBody | UndoBody | ImportFail | null => {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null
  const b = raw as Record<string, unknown>
  if (b.mode === "undo") return typeof b.batch === "string" && BATCH_ID.test(b.batch) ? { mode: "undo", batch: b.batch } : bad("batch is the id of an earlier append (A-Z a-z 0-9 . _ : -)")
  if (b.mode !== "append") return null
  if (b.batch !== undefined && (typeof b.batch !== "string" || !BATCH_ID.test(b.batch))) return bad("batch is 1 to 64 of A-Z a-z 0-9 . _ : -")
  if (!Array.isArray(b.items) || b.items.length > MAX_LINES) return bad(`items is an array of at most ${MAX_LINES}`)
  const items: AppendItem[] = []
  for (const [k, v] of b.items.entries()) {
    const o = v as Record<string, unknown> | null
    if (!o || typeof o.key !== "string" || !/^[0-9a-f]{64}$/.test(o.key) || typeof o.text !== "string" || typeof o.kind !== "string" || typeof o.date !== "string" || typeof o.source !== "string") {
      return bad(`item ${k} is not {key (sha256 hex), kind, text, date, source}`, { line: k })
    }
    items.push({ key: o.key, kind: o.kind, text: o.text, date: o.date, source: o.source })
  }
  return { mode: "append", dry_run: b.dry_run === true, items, ...(typeof b.batch === "string" ? { batch: b.batch } : {}) }
}

/** The key of a stored or sent message: sha256(kind \0 date_ms \0 text), hex (0 for an unparsable date). */
export const messageKey = async (kind: string, date: string, text: string): Promise<string> => {
  const ms = Date.parse(date)
  const data = new TextEncoder().encode(`${kind}\0${Number.isFinite(ms) ? ms : 0}\0${text}`)
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", data))].map((x) => x.toString(16).padStart(2, "0")).join("")
}

const SECRET = [/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}/, /\bgithub_pat_[A-Za-z0-9_]{20,}/, /\bsk-[A-Za-z0-9_-]{20,}/, /\bxox[abprs]-[A-Za-z0-9-]{10,}/, /\bAKIA[A-Z0-9]{16,}/, /\bAIza[A-Za-z0-9_-]{35,}/, /\bglpat-[A-Za-z0-9_-]{20,}/, /-----BEGIN [A-Z ]*PRIVATE KEY-----/]
export const looksSecret = (text: string): boolean => SECRET.some((r) => r.test(text))

/** Hashes the stored messages not yet in `oc_import_key` (once per message), so earlier copies count as known. */
const hashStored = async (sql: SqlStorage): Promise<void> => {
  for (const q of APPEND_SCHEMA) sql.exec(q)
  const done = Number(sql.exec<{ h: number }>(`SELECT hashed AS h FROM oc_import_mark WHERE id = 1`).toArray()[0]?.h ?? 0)
  const rows = sql.exec<{ i: number; kind: string; text: string; date: string }>(`SELECT i, kind, text, date FROM oc_message WHERE i >= ? ORDER BY i`, done).toArray()
  if (rows.length === 0) return
  const keys = await Promise.all(rows.map((r) => messageKey(r.kind, r.date, r.text)))
  rows.forEach((r, n) => sql.exec(`INSERT OR IGNORE INTO oc_import_key (key, i) VALUES (?, ?)`, keys[n], r.i))
  sql.exec(`INSERT INTO oc_import_mark (id, hashed) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET hashed = excluded.hashed`, rows[rows.length - 1]!.i + 1)
}

export const sideText = (it: AppendItem): string => `[imported from ${it.source} · ${it.kind} · ${it.date}]\n${it.text}`

/** `append` adds one message (the brain's Memory.append) and returns nothing; the caller pumps the compactor after. */
export const appendBatch = async (
  sql: SqlStorage,
  storage: DurableObjectStorage,
  body: AppendBody,
  append: (text: string) => void,
): Promise<(AppendResult & { ok: true }) | ImportFail> => {
  sql.exec(IMPORT_SCHEMA)
  const busy = sql.exec(`SELECT 1 FROM cb_inbox WHERE state IN ('queued', 'running') UNION ALL SELECT 1 FROM cb_turn WHERE status NOT IN ('done', 'failed') LIMIT 1`).toArray().length > 0
  if (busy && !body.dry_run) return conflict("brain_busy", "a Chief turn runs here: append after it ends")
  if (sql.exec<{ state: string }>(`SELECT state FROM oc_import WHERE id = 1`).toArray()[0]?.state === "importing") return conflict("memory_import_running", "a full memory copy is under way")
  await hashStored(sql)
  let duplicate = 0
  let rejected = 0
  const seen = new Set<string>()
  const fresh: AppendItem[] = []
  for (const it of body.items) {
    if (looksSecret(it.text)) rejected++
    else if (seen.has(it.key) || sql.exec(`SELECT 1 FROM oc_import_key WHERE key = ?`, it.key).toArray().length > 0) duplicate++
    else (seen.add(it.key), fresh.push(it))
  }
  const total = () => Number(sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM oc_message`).one().n)
  if (!body.dry_run && fresh.length > 0) {
    const first = total()
    storage.transactionSync(() => {
      for (const it of fresh) {
        append(sideText(it))
        sql.exec(`INSERT OR IGNORE INTO oc_import_key (key, i) VALUES (?, ?)`, it.key, total() - 1)
      }
      // The appended rows are keyed by their source key already: they are not hashed again later.
      sql.exec(`INSERT INTO oc_import_mark (id, hashed) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET hashed = excluded.hashed`, total())
      if (body.batch) {
        sql.exec(
          `INSERT INTO oc_import_batch (id, first_i, last_i, at) VALUES (?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET last_i = excluded.last_i`,
          body.batch,
          first,
          total() - 1,
          new Date().toISOString(),
        )
      }
    })
  }
  return { ok: true, added: fresh.length, duplicate, rejected, count: total() }
}

export type UndoResult = { readonly removed: number; readonly count: number }

/**
 * Takes back the append `body.batch`: its rows must be the log's tail (nothing was appended after it: a later
 * import or a live turn makes it `undo_not_tail`, refused). The summaries that cover any of its rows are deleted
 * (the compactor builds them again from what stays), and the folded view is dropped and loaded again by the caller.
 */
export const undoBatch = (sql: SqlStorage, storage: DurableObjectStorage, body: UndoBody): (UndoResult & { ok: true }) | ImportFail => {
  sql.exec(IMPORT_SCHEMA)
  for (const q of APPEND_SCHEMA) sql.exec(q)
  const busy = sql.exec(`SELECT 1 FROM cb_inbox WHERE state IN ('queued', 'running') UNION ALL SELECT 1 FROM cb_turn WHERE status NOT IN ('done', 'failed') LIMIT 1`).toArray().length > 0
  if (busy) return conflict("brain_busy", "a Chief turn runs here: undo after it ends")
  const row = sql.exec<{ first_i: number; last_i: number }>(`SELECT first_i, last_i FROM oc_import_batch WHERE id = ?`, body.batch).toArray()[0]
  if (!row) return { ok: false, status: 404, code: "not_found", message: "no such import batch (already undone?)" }
  const count = Number(sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM oc_message`).one().n)
  if (row.last_i !== count - 1) return conflict("undo_not_tail", "messages came after this import, so it cannot be taken back", { count })
  const removed = row.last_i - row.first_i + 1
  storage.transactionSync(() => {
    sql.exec(`DELETE FROM oc_message WHERE i >= ?`, row.first_i)
    sql.exec(`DELETE FROM oc_import_key WHERE i >= ?`, row.first_i)
    // A node (l, i) covers messages i*2^l .. (i+1)*2^l - 1: every node that reaches the removed rows goes.
    sql.exec(`DELETE FROM oc_node WHERE (i + 1) * (1 << l) > ?`, row.first_i)
    sql.exec(`DELETE FROM oc_checkpoint`)
    sql.exec(`DELETE FROM oc_frozen`)
    sql.exec(`INSERT INTO oc_import_mark (id, hashed) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET hashed = excluded.hashed`, row.first_i)
    sql.exec(`DELETE FROM oc_import_batch WHERE id = ? OR first_i >= ?`, body.batch, row.first_i)
  })
  return { ok: true, removed, count: row.first_i }
}
