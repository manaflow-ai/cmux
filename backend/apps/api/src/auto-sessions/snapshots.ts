import { MAX_CHAT_BYTES, MAX_MANIFEST_CHUNKS } from "./model.ts"

/**
 * An Auto chat's snapshot: what a new holder needs besides the events. One manifest (JSON) naming chunks by the
 * SHA-256 of their bytes. A snapshot is whole or absent: a manifest is accepted only when every chunk it names is
 * stored. The newest manifest is kept; accepting it drops the older one and every chunk it does not name.
 *
 * Each chunk is its own row (at most 1 MiB, under the storage row limit), so a chat's copy is never one large value.
 *
 * The size limit (MAX_CHAT_BYTES) is on what one snapshot names. The chunks of the snapshot being uploaded are
 * counted apart from the ones the kept snapshot names (`kept`), so a chat can always replace its snapshot with
 * another of up to the limit, and the store holds at most twice the limit for a chat.
 */
export const CHUNKS_TABLE = `CREATE TABLE IF NOT EXISTS chunks (sha TEXT PRIMARY KEY, size INTEGER NOT NULL, kept INTEGER NOT NULL DEFAULT 0, at INTEGER NOT NULL, bytes BLOB NOT NULL)`
export const SNAPSHOTS_TABLE = `CREATE TABLE IF NOT EXISTS snapshots (n INTEGER PRIMARY KEY, manifest TEXT NOT NULL, at INTEGER NOT NULL)`

export const SHA256_HEX = /^[0-9a-f]{64}$/
/** Chunks no snapshot named for this long are dropped when their chat is at its limit: an upload that was given up. */
const ABANDONED_MS = 24 * 3600_000

export const sha256Hex = async (bytes: ArrayBuffer): Promise<string> => [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((b) => b.toString(16).padStart(2, "0")).join("")

/**
 * The chunks a manifest names: every list in it whose items are all SHA-256 hex names (`cwd.bundle`, `cwd.patch`
 * and `cwd.tar` today). Read by shape, not by field, so a list a later manifest adds is kept too rather than
 * dropped as unnamed. Null when it names more than a chat may keep. Pure.
 */
export const chunkNames = (manifest: unknown): ReadonlyArray<string> | null => {
  const names = new Set<string>()
  const walk = (v: unknown, depth: number): void => {
    if (depth > 16 || v === null || typeof v !== "object") return
    if (Array.isArray(v)) {
      if (v.length > 0 && v.every((x) => typeof x === "string" && SHA256_HEX.test(x))) for (const x of v) names.add(x as string)
      else for (const x of v) walk(x, depth + 1)
      return
    }
    for (const x of Object.values(v)) walk(x, depth + 1)
  }
  walk(manifest, 0)
  return names.size > MAX_MANIFEST_CHUNKS ? null : [...names]
}

export const hasChunk = (sql: SqlStorage, sha: string): boolean => sql.exec(`SELECT 1 FROM chunks WHERE sha = ?`, sha).toArray().length > 0

const waitingBytes = (sql: SqlStorage): number => sql.exec<{ bytes: number | null }>(`SELECT sum(size) AS bytes FROM chunks WHERE kept = 0`).one().bytes ?? 0

/** Whether `size` more bytes fit beside the chunks waiting for their snapshot; at the limit, uploads that were given up make room first. */
export const roomForChunk = (sql: SqlStorage, size: number, now: number): boolean => {
  if (waitingBytes(sql) + size <= MAX_CHAT_BYTES) return true
  sql.exec(`DELETE FROM chunks WHERE kept = 0 AND at < ?`, now - ABANDONED_MS)
  return waitingBytes(sql) + size <= MAX_CHAT_BYTES
}

export const putChunk = (sql: SqlStorage, sha: string, bytes: ArrayBuffer, now: number): void => void sql.exec(`INSERT INTO chunks (sha, size, at, bytes) VALUES (?, ?, ?, ?)`, sha, bytes.byteLength, now, bytes)

export const getChunk = (sql: SqlStorage, sha: string): ArrayBuffer | null => sql.exec<{ bytes: ArrayBuffer }>(`SELECT bytes FROM chunks WHERE sha = ?`, sha).toArray()[0]?.bytes ?? null

/** The chunks of `names` that are not stored, and the size of the ones that are. */
export const weighChunks = (sql: SqlStorage, names: ReadonlyArray<string>): { readonly missing: ReadonlyArray<string>; readonly bytes: number } => {
  const missing: Array<string> = []
  let bytes = 0
  for (const sha of names) {
    const row = sql.exec<{ size: number }>(`SELECT size FROM chunks WHERE sha = ?`, sha).toArray()[0]
    if (row) bytes += row.size
    else missing.push(sha)
  }
  return { missing, bytes }
}

/** Keeps manifest `n` as the chat's snapshot, and drops the one before it and every chunk `n` does not name. */
export const acceptSnapshot = (sql: SqlStorage, n: number, manifest: string, names: ReadonlyArray<string>, now: number): void => {
  sql.exec(`INSERT INTO snapshots (n, manifest, at) VALUES (?, ?, ?)`, n, manifest, now)
  sql.exec(`DELETE FROM snapshots WHERE n < ?`, n)
  const named = new Set(names)
  const unnamed = sql.exec<{ sha: string }>(`SELECT sha FROM chunks`).toArray().filter((c) => !named.has(c.sha))
  for (const c of unnamed) sql.exec(`DELETE FROM chunks WHERE sha = ?`, c.sha)
  sql.exec(`UPDATE chunks SET kept = 1 WHERE kept = 0`)
}

/** The newest snapshot: its number and its manifest's JSON text. */
export const readSnapshot = (sql: SqlStorage): { readonly snapshot: number; readonly manifest: string } | null => {
  const row = sql.exec<{ n: number; manifest: string }>(`SELECT n, manifest FROM snapshots ORDER BY n DESC LIMIT 1`).toArray()[0]
  return row ? { snapshot: row.n, manifest: row.manifest } : null
}

export const dropSnapshots = (sql: SqlStorage): void => {
  sql.exec(`DELETE FROM snapshots`)
  sql.exec(`DELETE FROM chunks`)
}
