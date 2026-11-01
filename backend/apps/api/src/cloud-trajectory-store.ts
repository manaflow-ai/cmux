import { DurableObject } from "cloudflare:workers"
import type { Env } from "./env.ts"

/**
 * ACP chat trajectories kept outside the Cloud VM (#25584). One TrajectoryDO per team and machine
 * (`<team>/<machine>`, cloud-trajectory.ts): it outlives the VM's pause and the machine itself, so a
 * replacement restored from one of its snapshots reads it (read only) and imports what it lacks.
 *
 * What is kept per acpmux session: its record (`session.json`, as acpmux wrote it), its event log
 * as the exact ndjson lines acpmux wrote (`events/NNNNNN.ndjson`), and the agent's own resume files
 * (a Claude project `<sid>.jsonl`, a Codex rollout) as append-only byte ranges. Together they are an
 * `acpmux.bundle.v1`, which the VM's acpmux imports to continue the chat.
 *
 * One writer: only the machine's own VM install writes (the route checks it). The log
 * is contiguous: a batch must start at most one past the kept `last_seq`; a record already kept must
 * be byte-identical (a different one is a conflict, never last-write-wins). A session's generation is
 * its `createdAt`: a newer one (the session recreated under the same id) replaces the old copy, an
 * older one is refused.
 */

/** A refusal: the route maps it to an HTTP answer. */
export type TrajectoryRefusal =
  | { readonly code: "cloud.trajectory.gap"; readonly last_seq: number }
  | { readonly code: "cloud.trajectory.conflict"; readonly seq: number }
  | { readonly code: "cloud.trajectory.stale_generation"; readonly generation: number }
  | { readonly code: "cloud.trajectory.offset"; readonly size: number }
  | { readonly code: "cloud.trajectory.not_found" }
  | { readonly code: "cloud.trajectory.full"; readonly bytes: number }
  | { readonly code: "validation.invalid"; readonly message: string }

export type TrajectoryResult<A> = { readonly ok: true; readonly value: A } | { readonly ok: false; readonly refusal: TrajectoryRefusal }

export interface NativeFile {
  readonly label: string
  readonly path: string
  readonly size: number
  readonly revision: string
}

export interface SessionSummary {
  readonly session: string
  readonly generation: number
  readonly last_seq: number
  readonly meta: unknown
  readonly native: ReadonlyArray<NativeFile>
  readonly updated_at: number
}

/** A complete ordered page of session references; the cursor is stable across metadata updates. */
export interface TrajectoryListPage {
  readonly sessions: ReadonlyArray<SessionSummary>
  readonly has_more: boolean
  readonly next_after_session: string | null
}

/** The most one machine keeps (events, records and native files). */
export const MACHINE_MAX_BYTES = 2 * 1024 ** 3
/** One stored value stays well under the 2 MB SQLite row limit. */
export const RECORD_MAX_BYTES = 1024 * 1024
export const NATIVE_CHUNK_MAX_BYTES = 512 * 1024
export const READ_MAX_RECORDS = 2000
/** A read page's records stop past this many bytes (at least one record is returned). */
export const READ_MAX_BYTES = 4 * 1024 * 1024
export const LIST_MAX_SESSIONS = 500
/** A list page's session records stop past this many bytes (at least one session is returned). */
export const LIST_MAX_BYTES = 4 * 1024 * 1024

/** The labels acpmux bundles use for the agents' own files (acpmux native.rs). */
const NATIVE_LABELS: ReadonlySet<string> = new Set(["claude-project", "codex-rollout"])

const SESSION_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/

export const isSessionId = (id: unknown): id is string => typeof id === "string" && SESSION_ID.test(id) && id !== "." && id !== ".."

/** A native file's path under the home directory: plain components only, a `.jsonl` file. */
export const isNativePath = (label: unknown, path: unknown): path is string =>
  typeof label === "string" && NATIVE_LABELS.has(label) && typeof path === "string" && path.length <= 512 && path.endsWith(".jsonl") &&
  path.split("/").every((c) => c.length > 0 && c !== "." && c !== ".." && !c.includes("\\") && !c.includes("\0")) &&
  (label === "claude-project" ? path.startsWith(".claude/projects/") : path.startsWith(".codex/sessions/"))

const sha256 = async (text: string) => {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)))
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("")
}

const bytesOf = (text: string) => new TextEncoder().encode(text).byteLength

/** The seq of one ndjson record line, or undefined when it is not one. */
export const recordSeq = (line: string): number | undefined => {
  let parsed: unknown
  try {
    parsed = JSON.parse(line)
  } catch {
    return undefined
  }
  const seq = (parsed as { seq?: unknown } | null)?.seq
  return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed) && Number.isSafeInteger(seq) && (seq as number) > 0 ? (seq as number) : undefined
}

interface SessionRow {
  readonly session: string
  readonly generation: number
  readonly meta: string
  readonly last_seq: number
  readonly bytes: number
  readonly updated_at: number
}

/** The store over one object's SQLite (TrajectoryDO; the tests use it directly). */
export class TrajectoryStore {
  constructor(private readonly sql: SqlStorage) {
    sql.exec(`CREATE TABLE IF NOT EXISTS traj_session (session TEXT PRIMARY KEY, generation INTEGER NOT NULL, meta TEXT NOT NULL, last_seq INTEGER NOT NULL, bytes INTEGER NOT NULL, updated_at INTEGER NOT NULL)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS traj_event (session TEXT NOT NULL, seq INTEGER NOT NULL, hash TEXT NOT NULL, line TEXT NOT NULL, PRIMARY KEY (session, seq))`)
    sql.exec(`CREATE TABLE IF NOT EXISTS traj_native (session TEXT NOT NULL, label TEXT NOT NULL, path TEXT NOT NULL, size INTEGER NOT NULL, PRIMARY KEY (session, label, path))`)
    sql.exec(`CREATE TABLE IF NOT EXISTS traj_native_chunk (session TEXT NOT NULL, label TEXT NOT NULL, path TEXT NOT NULL, offset INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY (session, label, path, offset))`)
    sql.exec(`CREATE TABLE IF NOT EXISTS traj_native_revision (session TEXT NOT NULL, label TEXT NOT NULL, path TEXT NOT NULL, revision TEXT NOT NULL, PRIMARY KEY (session, label, path))`)
  }

  private row(session: string): SessionRow | undefined {
    return this.sql.exec<Record<string, SqlStorageValue>>(`SELECT * FROM traj_session WHERE session = ?`, session).toArray()[0] as unknown as SessionRow | undefined
  }

  private totalBytes(): number {
    return Number(this.sql.exec<{ total: number | null }>(`SELECT SUM(bytes) AS total FROM traj_session`).one().total ?? 0)
  }

  private dropSession(session: string) {
    this.sql.exec(`DELETE FROM traj_event WHERE session = ?`, session)
    this.sql.exec(`DELETE FROM traj_native_chunk WHERE session = ?`, session)
    this.sql.exec(`DELETE FROM traj_native WHERE session = ?`, session)
    this.sql.exec(`DELETE FROM traj_native_revision WHERE session = ?`, session)
    this.sql.exec(`DELETE FROM traj_session WHERE session = ?`, session)
  }

  /** Existing stores acquire a revision on their first read; a rewrite replaces it atomically. */
  private nativeRevision(session: string, label: string, path: string): string {
    const kept = this.sql.exec<{ revision: string }>(`SELECT revision FROM traj_native_revision WHERE session = ? AND label = ? AND path = ?`, session, label, path).toArray()[0]
    if (kept) return kept.revision
    const revision = crypto.randomUUID()
    this.sql.exec(`INSERT INTO traj_native_revision (session, label, path, revision) VALUES (?, ?, ?, ?)`, session, label, path, revision)
    return revision
  }

  /**
   * Appends `lines` (ndjson records, consecutive seqs) to `session` at `generation`, and replaces its
   * record with `meta` when given. Answers the kept `last_seq`. Records already kept are checked, not
   * written again, so a retried batch is a no-op.
   */
  async append(session: string, generation: number, meta: unknown, lines: ReadonlyArray<string>, now: number): Promise<TrajectoryResult<{ last_seq: number }>> {
    const invalid = (message: string) => ({ ok: false as const, refusal: { code: "validation.invalid" as const, message } })
    const seqs: Array<number> = []
    for (const line of lines) {
      if (bytesOf(line) > RECORD_MAX_BYTES) return invalid("a record is too large")
      const seq = recordSeq(line)
      if (seq === undefined) return invalid("a record is not an acpmux event line")
      if (seqs.length > 0 && seq !== seqs[seqs.length - 1]! + 1) return invalid("records must have consecutive seqs")
      seqs.push(seq)
    }
    const metaText = meta === undefined ? undefined : JSON.stringify(meta)
    if (metaText !== undefined && bytesOf(metaText) > RECORD_MAX_BYTES) return invalid("the session record is too large")
    const hashes = await Promise.all(lines.map(sha256))
    // From here on, one synchronous turn: no other request runs in between.
    let row = this.row(session)
    if (row && generation < row.generation) return { ok: false, refusal: { code: "cloud.trajectory.stale_generation", generation: row.generation } }
    // A recreated session replaces the old copy: that copy's bytes are freed first, unless the new one does not fit.
    const replacing = row !== undefined && generation > row.generation
    const freed = replacing ? row!.bytes : 0
    if (replacing && this.totalBytes() - freed + lines.reduce((n, l) => n + bytesOf(l), 0) + (metaText ? bytesOf(metaText) : 0) > MACHINE_MAX_BYTES) return { ok: false, refusal: { code: "cloud.trajectory.full", bytes: this.totalBytes() } }
    // A replacement is a fresh log: refuse it before the old copy goes, never after (review 2).
    if (replacing && metaText === undefined) return { ok: false, refusal: { code: "cloud.trajectory.not_found" } }
    if (replacing && seqs[0] !== undefined && seqs[0] > 1) return { ok: false, refusal: { code: "cloud.trajectory.gap", last_seq: 0 } }
    if (replacing) {
      this.dropSession(session)
      row = undefined
    }
    if (!row && metaText === undefined) return { ok: false, refusal: { code: "cloud.trajectory.not_found" } }
    const lastSeq = row?.last_seq ?? 0
    const first = seqs[0]
    if (first !== undefined && first > lastSeq + 1) return { ok: false, refusal: { code: "cloud.trajectory.gap", last_seq: lastSeq } }
    let added = 0
    let next = lastSeq
    const fresh: Array<[number, string, string]> = []
    for (let i = 0; i < lines.length; i++) {
      const seq = seqs[i]!
      if (seq <= lastSeq) {
        const kept = this.sql.exec<{ hash: string }>(`SELECT hash FROM traj_event WHERE session = ? AND seq = ?`, session, seq).toArray()[0]
        if (kept && kept.hash !== hashes[i]) return { ok: false, refusal: { code: "cloud.trajectory.conflict", seq } }
        continue
      }
      fresh.push([seq, hashes[i]!, lines[i]!])
      added += bytesOf(lines[i]!)
      next = seq
    }
    const metaBytes = metaText === undefined ? 0 : bytesOf(metaText) - (row ? bytesOf(row.meta) : 0)
    const total = this.totalBytes()
    if (added + metaBytes > 0 && total + added + metaBytes > MACHINE_MAX_BYTES) return { ok: false, refusal: { code: "cloud.trajectory.full", bytes: total } }
    for (const [seq, hash, line] of fresh) this.sql.exec(`INSERT INTO traj_event (session, seq, hash, line) VALUES (?, ?, ?, ?)`, session, seq, hash, line)
    const bytes = (row?.bytes ?? 0) + added + metaBytes
    this.sql.exec(
      `INSERT INTO traj_session (session, generation, meta, last_seq, bytes, updated_at) VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(session) DO UPDATE SET meta = excluded.meta, last_seq = excluded.last_seq, bytes = excluded.bytes, updated_at = excluded.updated_at`,
      session, generation, metaText ?? row!.meta, next, bytes, now
    )
    return { ok: true, value: { last_seq: next } }
  }

  /**
   * Writes `data` at `offset` of one agent resume file: at its kept size (an append) or at 0 (the
   * file was rewritten: it is replaced). Any other offset answers the kept size.
   */
  appendNative(session: string, generation: number, label: string, path: string, offset: number, data: Uint8Array, now: number): TrajectoryResult<{ size: number }> {
    const row = this.row(session)
    if (!row) return { ok: false, refusal: { code: "cloud.trajectory.not_found" } }
    if (generation !== row.generation) return { ok: false, refusal: { code: "cloud.trajectory.stale_generation", generation: row.generation } }
    const kept = this.sql.exec<{ size: number }>(`SELECT size FROM traj_native WHERE session = ? AND label = ? AND path = ?`, session, label, path).toArray()[0]
    const size = Number(kept?.size ?? 0)
    if (offset !== size && offset !== 0) return { ok: false, refusal: { code: "cloud.trajectory.offset", size } }
    const freed = offset === 0 ? size : 0
    const total = this.totalBytes()
    if (data.byteLength > freed && total + data.byteLength - freed > MACHINE_MAX_BYTES) return { ok: false, refusal: { code: "cloud.trajectory.full", bytes: total } }
    if (offset === 0) {
      this.sql.exec(`DELETE FROM traj_native_chunk WHERE session = ? AND label = ? AND path = ?`, session, label, path)
      this.sql.exec(`INSERT INTO traj_native_revision (session, label, path, revision) VALUES (?, ?, ?, ?) ON CONFLICT(session, label, path) DO UPDATE SET revision = excluded.revision`, session, label, path, crypto.randomUUID())
    }
    if (data.byteLength > 0) this.sql.exec(`INSERT INTO traj_native_chunk (session, label, path, offset, data) VALUES (?, ?, ?, ?, ?)`, session, label, path, offset, data.slice().buffer)
    const next = offset + data.byteLength
    this.sql.exec(`INSERT INTO traj_native (session, label, path, size) VALUES (?, ?, ?, ?) ON CONFLICT(session, label, path) DO UPDATE SET size = excluded.size`, session, label, path, next)
    this.sql.exec(`UPDATE traj_session SET bytes = ?, updated_at = ? WHERE session = ?`, row.bytes + data.byteLength - freed, now, session)
    return { ok: true, value: { size: next } }
  }

  /**
   * List every kept session through keyset pages. Session ids are immutable, whereas updated_at
   * changes while a VM writes, so sorting by recency would skip/duplicate rows between requests.
   * One extra row proves whether another page exists; the caller may only report restore complete
   * after following every cursor.
   */
  list(afterSession: string | null = null): TrajectoryListPage {
    const cursor = this.sql.exec<Record<string, SqlStorageValue>>(
      `SELECT * FROM traj_session WHERE session > ? ORDER BY session ASC LIMIT ?`,
      afterSession ?? "", LIST_MAX_SESSIONS + 1
    )
    // Each session record may be up to RECORD_MAX_BYTES, so 500 of them could exceed the Durable
    // Object reply limit; cut the page at a byte budget too. The cursor makes a short page safe.
    const rows: Array<SessionRow> = []
    let bytes = 0
    let hasMore = false
    for (const value of cursor) {
      const row = value as unknown as SessionRow
      const size = bytesOf(row.meta)
      if (rows.length === LIST_MAX_SESSIONS || (rows.length > 0 && bytes + size > LIST_MAX_BYTES)) {
        hasMore = true
        break
      }
      bytes += size
      rows.push(row)
    }
    const sessions = rows.map((r) => ({
      session: r.session,
      generation: Number(r.generation),
      last_seq: Number(r.last_seq),
      meta: JSON.parse(r.meta) as unknown,
      native: this.sql.exec<{ label: string; path: string; size: number }>(`SELECT label, path, size FROM traj_native WHERE session = ? ORDER BY label, path`, r.session).toArray().map((n) => ({ label: n.label, path: n.path, size: Number(n.size), revision: this.nativeRevision(r.session, n.label, n.path) })),
      updated_at: Number(r.updated_at)
    }))
    return { sessions, has_more: hasMore, next_after_session: hasMore ? sessions.at(-1)!.session : null }
  }

  /** The records after `afterSeq`, oldest first, bounded by `limit` and READ_MAX_BYTES. */
  read(session: string, afterSeq: number, limit: number): TrajectoryResult<{ generation: number; last_seq: number; lines: ReadonlyArray<string>; has_more: boolean }> {
    const row = this.row(session)
    if (!row) return { ok: false, refusal: { code: "cloud.trajectory.not_found" } }
    const take = Math.max(1, Math.min(limit, READ_MAX_RECORDS))
    const cursor = this.sql.exec<{ seq: number; line: string }>(`SELECT seq, line FROM traj_event WHERE session = ? AND seq > ? ORDER BY seq LIMIT ?`, session, afterSeq, take + 1)
    const lines: Array<string> = []
    let bytes = 0
    let last = afterSeq
    for (const r of cursor) {
      if (lines.length === take || (lines.length > 0 && bytes + bytesOf(r.line) > READ_MAX_BYTES)) break
      lines.push(r.line)
      bytes += bytesOf(r.line)
      last = Number(r.seq)
    }
    return { ok: true, value: { generation: Number(row.generation), last_seq: Number(row.last_seq), lines, has_more: last < Number(row.last_seq) } }
  }

  /** The kept chunk of a native file that starts at `offset`, and the file's size. */
  readNative(session: string, label: string, path: string, offset: number): TrajectoryResult<{ generation: number; revision: string; size: number; data: Uint8Array }> {
    const row = this.row(session)
    if (!row) return { ok: false, refusal: { code: "cloud.trajectory.not_found" } }
    const generation = Number(row.generation)
    const kept = this.sql.exec<{ size: number }>(`SELECT size FROM traj_native WHERE session = ? AND label = ? AND path = ?`, session, label, path).toArray()[0]
    if (!kept) return { ok: false, refusal: { code: "cloud.trajectory.not_found" } }
    const size = Number(kept.size)
    const revision = this.nativeRevision(session, label, path)
    if (offset >= size) return { ok: true, value: { generation, revision, size, data: new Uint8Array(0) } }
    const chunk = this.sql.exec<{ data: ArrayBuffer }>(`SELECT data FROM traj_native_chunk WHERE session = ? AND label = ? AND path = ? AND offset = ?`, session, label, path, offset).toArray()[0]
    if (!chunk) return { ok: false, refusal: { code: "cloud.trajectory.offset", size } }
    return { ok: true, value: { generation, revision, size, data: new Uint8Array(chunk.data) } }
  }
}

/** The Durable Object around a TrajectoryStore: RPC only, no fetch. */
export class TrajectoryDO extends DurableObject<Env> {
  private readonly store: TrajectoryStore
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    this.store = new TrajectoryStore(ctx.storage.sql)
  }
  append(session: string, generation: number, meta: unknown, lines: ReadonlyArray<string>) {
    return this.store.append(session, generation, meta, lines, Date.now())
  }
  appendNative(session: string, generation: number, label: string, path: string, offset: number, data: Uint8Array) {
    return this.store.appendNative(session, generation, label, path, offset, data, Date.now())
  }
  list(afterSession: string | null = null) {
    return this.store.list(afterSession)
  }
  read(session: string, afterSeq: number, limit: number) {
    return this.store.read(session, afterSeq, limit)
  }
  readNative(session: string, label: string, path: string, offset: number) {
    return this.store.readNative(session, label, path, offset)
  }
}
