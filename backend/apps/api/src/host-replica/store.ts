/**
 * The read replica of one host's host-homed streams (plans/cmux-next/object-sync/DESIGN.md
 * section 6.3, phase 3): per stream the last snapshot the host published and a bounded tail of
 * the events after it, plus the host's presence. The host is the owner and the only writer of
 * these streams; HostDO stores what it published so a client can read it while the host is off,
 * and never commits anything itself. The stream's `seq` is the host's, so a client that moves
 * from the replica to the live host sees no gap.
 *
 * Pure SQL over the object's own SQLite; HostDO does the sockets.
 */

/** A stored frame is JSON text exactly as the host sent it. */
export interface Stored {
  readonly seq: number
  readonly text: string
}

export interface Presence {
  /** The current publisher socket's id; null when the host closed it (a socket may also vanish unseen). */
  readonly publisher: string | null
  /** Unix ms of the last change; 0 before the host ever connected. */
  readonly since: number
}

/** An op forwarded to the host and not yet answered. */
export interface InFlight {
  readonly reader: string
  readonly key: string
  readonly stream: string
}

/** A Chief message kept for an offline host (the mailbox, a450 logs/iphone-chief-DESIGN.md). */
export interface Queued {
  readonly stream: string
  readonly key: string
  /** The reader's op frame, JSON, without routing fields. */
  readonly frame: string
  /** The reader's principal, JSON. */
  readonly principal: string
}

/** Mailbox bounds per host: entries, bytes of one op frame, and age (ms) before an entry expires. */
export const MAILBOX_MAX = 200
export const MAILBOX_FRAME_MAX_BYTES = 64 * 1024
export const MAILBOX_TTL_MS = 7 * 24 * 60 * 60 * 1000

/**
 * Tail bounds per stream (DESIGN.md section 12). The tail is never trimmed on its own (a snapshot
 * plus every event after it is the only consistent answer): past these bounds HostDO asks the host
 * for a new snapshot, which replaces the tail; at twice them the replica stops appending and waits.
 */
export const TAIL_MAX_EVENTS = 1000
export const TAIL_MAX_BYTES = 8 * 1024 * 1024
/** One stored snapshot (a DO SQLite value is at most 2 MB; screens are capped at 64 KiB each). */
export const SNAPSHOT_MAX_BYTES = 1024 * 1024
/** One stored event. */
export const EVENT_MAX_BYTES = 256 * 1024
/** Ops one reader socket may have in flight at the host. */
export const MAX_IN_FLIGHT = 64
/** Streams one host may publish. */
export const MAX_STREAMS = 512

/** Streams a host may publish: its own `host:<id>/...` streams and workspace documents. */
export const publishable = (host: string, stream: string): boolean =>
  stream.length <= 96 && (stream.startsWith(`host:${host}/`) || /^doc:ws_[A-Za-z0-9_-]{1,64}$/.test(stream))

type Sql = DurableObjectStorage["sql"]

const bytes = (text: string) => new TextEncoder().encode(text).length

export class ReplicaStore {
  constructor(private readonly sql: Sql) {
    sql.exec(`CREATE TABLE IF NOT EXISTS replica_stream (stream TEXT PRIMARY KEY, snapshot_seq INTEGER NOT NULL, snapshot TEXT NOT NULL, head INTEGER NOT NULL, tail_bytes INTEGER NOT NULL)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS replica_event (stream TEXT NOT NULL, seq INTEGER NOT NULL, event TEXT NOT NULL, PRIMARY KEY (stream, seq))`)
    sql.exec(`CREATE TABLE IF NOT EXISTS replica_presence (id INTEGER PRIMARY KEY CHECK (id = 1), publisher TEXT, since INTEGER NOT NULL)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS replica_mailbox (n INTEGER PRIMARY KEY AUTOINCREMENT, stream TEXT NOT NULL, key TEXT NOT NULL, frame TEXT NOT NULL, principal TEXT NOT NULL, at INTEGER NOT NULL, UNIQUE (stream, key))`)
    sql.exec(`CREATE TABLE IF NOT EXISTS replica_inflight (reader TEXT NOT NULL, key TEXT NOT NULL, stream TEXT NOT NULL, PRIMARY KEY (reader, key))`)
  }

  presence(): Presence {
    const row = this.sql.exec<{ publisher: string | null; since: number }>(`SELECT publisher, since FROM replica_presence WHERE id = 1`).toArray()[0]
    return row ? { publisher: row.publisher ?? null, since: Number(row.since) } : { publisher: null, since: 0 }
  }

  setPresence(publisher: string | null, since: number): void {
    this.sql.exec(`INSERT INTO replica_presence (id, publisher, since) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET publisher = excluded.publisher, since = excluded.since`, publisher, since)
  }

  /** Records an op forwarded for `reader`; false when that reader already has MAX_IN_FLIGHT. */
  addInFlight(reader: string, key: string, stream: string): boolean {
    const n = Number(this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM replica_inflight WHERE reader = ?`, reader).toArray()[0]?.n ?? 0)
    if (n >= MAX_IN_FLIGHT) return false
    this.sql.exec(`INSERT INTO replica_inflight (reader, key, stream) VALUES (?, ?, ?) ON CONFLICT(reader, key) DO NOTHING`, reader, key, stream)
    return true
  }

  settleInFlight(reader: string, key: string): void {
    this.sql.exec(`DELETE FROM replica_inflight WHERE reader = ? AND key = ?`, reader, key)
  }

  /** Removes and returns every op in flight (the publisher that had them is gone), or one reader's. */
  takeInFlight(reader?: string): Array<InFlight> {
    const rows = (reader === undefined ? this.sql.exec<{ reader: string; key: string; stream: string }>(`SELECT reader, key, stream FROM replica_inflight`) : this.sql.exec<{ reader: string; key: string; stream: string }>(`SELECT reader, key, stream FROM replica_inflight WHERE reader = ?`, reader)).toArray()
    if (reader === undefined) this.sql.exec(`DELETE FROM replica_inflight`)
    else this.sql.exec(`DELETE FROM replica_inflight WHERE reader = ?`, reader)
    return rows.map((r) => ({ reader: r.reader, key: r.key, stream: r.stream }))
  }

  /**
   * Keeps one op for the offline host. The same (stream, key) is one entry: a resend answers its
   * position again and changes nothing. Returns the 1-based position among the stream's entries,
   * or why it was refused.
   */
  enqueue(stream: string, key: string, frame: string, principal: string, now: number): { readonly kind: "queued"; readonly position: number } | { readonly kind: "full" | "too_large" } {
    this.expire(now)
    if (bytes(frame) > MAILBOX_FRAME_MAX_BYTES) return { kind: "too_large" }
    const existing = this.sql.exec<{ n: number }>(`SELECT n FROM replica_mailbox WHERE stream = ? AND key = ?`, stream, key).toArray()[0]
    if (!existing) {
      const count = Number(this.sql.exec<{ c: number }>(`SELECT COUNT(*) AS c FROM replica_mailbox`).toArray()[0]?.c ?? 0)
      if (count >= MAILBOX_MAX) return { kind: "full" }
      this.sql.exec(`INSERT INTO replica_mailbox (stream, key, frame, principal, at) VALUES (?, ?, ?, ?, ?)`, stream, key, frame, principal, now)
    }
    const n = existing ? Number(existing.n) : Number(this.sql.exec<{ n: number }>(`SELECT n FROM replica_mailbox WHERE stream = ? AND key = ?`, stream, key).toArray()[0]!.n)
    const position = Number(this.sql.exec<{ c: number }>(`SELECT COUNT(*) AS c FROM replica_mailbox WHERE stream = ? AND n <= ?`, stream, n).toArray()[0]?.c ?? 1)
    return { kind: "queued", position }
  }

  /** Every kept op, oldest first (expired ones are dropped first). */
  mailbox(now: number): Array<Queued> {
    this.expire(now)
    return this.sql
      .exec<{ stream: string; key: string; frame: string; principal: string }>(`SELECT stream, key, frame, principal FROM replica_mailbox ORDER BY n`)
      .toArray()
      .map((r) => ({ stream: r.stream, key: r.key, frame: r.frame, principal: r.principal }))
  }

  /** Removes one kept op; true when it was there. */
  settleQueued(stream: string, key: string): boolean {
    const had = this.sql.exec(`SELECT 1 FROM replica_mailbox WHERE stream = ? AND key = ?`, stream, key).toArray().length > 0
    this.sql.exec(`DELETE FROM replica_mailbox WHERE stream = ? AND key = ?`, stream, key)
    return had
  }

  private expire(now: number): void {
    this.sql.exec(`DELETE FROM replica_mailbox WHERE at < ?`, now - MAILBOX_TTL_MS)
  }

  /** The newest seq stored per stream (what the host must resume after). */
  heads(): Record<string, number> {
    const out: Record<string, number> = {}
    for (const r of this.sql.exec<{ stream: string; head: number }>(`SELECT stream, head FROM replica_stream`)) out[r.stream] = Number(r.head)
    return out
  }

  head(stream: string): number | undefined {
    const r = this.sql.exec<{ head: number }>(`SELECT head FROM replica_stream WHERE stream = ?`, stream).toArray()[0]
    return r ? Number(r.head) : undefined
  }

  snapshot(stream: string): Stored | undefined {
    const r = this.sql.exec<{ snapshot_seq: number; snapshot: string }>(`SELECT snapshot_seq, snapshot FROM replica_stream WHERE stream = ?`, stream).toArray()[0]
    return r ? { seq: Number(r.snapshot_seq), text: r.snapshot } : undefined
  }

  /**
   * The stored events after `after`, when the tail holds every one of them; otherwise undefined
   * (the caller answers with the snapshot).
   */
  eventsAfter(stream: string, after: number): Iterable<Stored> | undefined {
    const head = this.head(stream)
    if (head === undefined || after > head) return undefined
    const n = Number(this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM replica_event WHERE stream = ? AND seq > ?`, stream, after).toArray()[0]?.n ?? 0)
    if (n !== head - after) return undefined
    // A cursor, not an array: the caller sends each event as it reads it (a tail may be 16 MiB).
    const cursor = this.sql.exec<{ seq: number; event: string }>(`SELECT seq, event FROM replica_event WHERE stream = ? AND seq > ? ORDER BY seq`, stream, after)
    return (function* () {
      for (const r of cursor) yield { seq: Number(r.seq), text: r.event }
    })()
  }

  /** Replaces the stream's snapshot and drops its tail. False when refused (too big, too many streams). */
  putSnapshot(stream: string, seq: number, text: string): boolean {
    if (bytes(text) > SNAPSHOT_MAX_BYTES) return false
    if (this.head(stream) === undefined && this.streamCount() >= MAX_STREAMS) return false
    this.sql.exec(`DELETE FROM replica_event WHERE stream = ?`, stream)
    this.sql.exec(
      `INSERT INTO replica_stream (stream, snapshot_seq, snapshot, head, tail_bytes) VALUES (?, ?, ?, ?, 0) ON CONFLICT(stream) DO UPDATE SET snapshot_seq = excluded.snapshot_seq, snapshot = excluded.snapshot, head = excluded.head, tail_bytes = 0`,
      stream,
      seq,
      text,
      seq
    )
    return true
  }

  /**
   * Appends the event at `head + 1`. Returns "applied" (and whether the tail is past its soft
   * bounds, so the host should send a new snapshot), "duplicate" (at or below the head), "gap"
   * (the replica needs a snapshot from the host first), or "full" (the tail is at twice its
   * bounds: refused, and the replica waits for a snapshot; the next event is then a gap), or
   * "too_large" (one event above EVENT_MAX_BYTES: refused, and the replica waits for a snapshot).
   */
  appendEvent(stream: string, seq: number, text: string): { readonly kind: "applied"; readonly compact: boolean } | { readonly kind: "duplicate" | "gap" | "full" | "too_large" } {
    const r = this.row(stream)
    if (!r || seq > r.head + 1) return { kind: "gap" }
    if (seq <= r.head) return { kind: "duplicate" }
    const size = bytes(text)
    if (size > EVENT_MAX_BYTES) return { kind: "too_large" }
    const count = r.head + 1 - r.snapshotSeq
    if (count > 2 * TAIL_MAX_EVENTS || r.tailBytes + size > 2 * TAIL_MAX_BYTES) return { kind: "full" }
    this.sql.exec(`INSERT INTO replica_event (stream, seq, event) VALUES (?, ?, ?)`, stream, seq, text)
    this.sql.exec(`UPDATE replica_stream SET head = ?, tail_bytes = tail_bytes + ? WHERE stream = ?`, seq, size, stream)
    return { kind: "applied", compact: count > TAIL_MAX_EVENTS || r.tailBytes + size > TAIL_MAX_BYTES }
  }

  /** Forgets every stream (the host's owner turned the replica off, or purged it). */
  purge(): void {
    this.sql.exec(`DELETE FROM replica_event`)
    this.sql.exec(`DELETE FROM replica_stream`)
    this.sql.exec(`DELETE FROM replica_inflight`)
    this.sql.exec(`DELETE FROM replica_mailbox`)
  }

  private streamCount(): number {
    return Number(this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM replica_stream`).toArray()[0]?.n ?? 0)
  }

  private row(stream: string): { head: number; snapshotSeq: number; tailBytes: number } | undefined {
    const r = this.sql.exec<{ head: number; snapshot_seq: number; tail_bytes: number }>(`SELECT head, snapshot_seq, tail_bytes FROM replica_stream WHERE stream = ?`, stream).toArray()[0]
    return r ? { head: Number(r.head), snapshotSeq: Number(r.snapshot_seq), tailBytes: Number(r.tail_bytes) } : undefined
  }
}
