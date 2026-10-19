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

const SCHEMA = `CREATE TABLE IF NOT EXISTS oc_import (id INTEGER PRIMARY KEY CHECK (id = 1), state TEXT NOT NULL)`

const bad = (message: string, extra?: Record<string, unknown>): ImportFail => ({ ok: false, status: 400, code: "validation.invalid", message, ...(extra ? { extra } : {}) })
const conflict = (code: string, message: string, extra?: Record<string, unknown>): ImportFail => ({ ok: false, status: 409, code, message, ...(extra ? { extra } : {}) })

export const importStatus = (sql: SqlStorage): ImportStatus => {
  sql.exec(SCHEMA)
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
