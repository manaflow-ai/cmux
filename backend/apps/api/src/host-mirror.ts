/**
 * The streams HostDO serves (b1-control-do.md sections 1 and 3): per stream one snapshot (state at
 * `snap_seq`) and the events after it, in SQLite so a hibernated object answers subscribers.
 *
 * - Mirrored streams (`workspace:`, `task:`): the Mac owns them. The snapshot is the Mac's latest
 *   and the tail is every Mac event since; nothing here reduces state, so clients see the Mac's
 *   sequence end to end. The tail is bounded: past COMPACT_EVENTS (or bytes) the caller asks the
 *   Mac for a compacting snapshot; past MAX_EVENTS new events are dropped (the next one is a gap,
 *   which asks again) rather than keeping a tail that could not rebuild the head.
 * - Owned streams (`host:`): HostDO writes the state and the event together, so the snapshot is
 *   always at the head and the tail is only for `after_seq` replay (oldest dropped past OWNED_TAIL).
 */

export const COMPACT_EVENTS = 512
export const COMPACT_BYTES = 512 * 1024
export const MAX_EVENTS = 2048
export const OWNED_TAIL = 256
export const MAX_SNAPSHOT_BYTES = 1024 * 1024

export interface StreamHead {
  readonly snapSeq: number
  readonly head: number
  readonly state: unknown
}

export interface EventLike {
  readonly seq: number
  readonly [k: string]: unknown
}

export type AppendOutcome = "applied" | "gap" | "stale" | "full"

export class HostStreams {
  constructor(private readonly sql: SqlStorage) {
    sql.exec(`CREATE TABLE IF NOT EXISTS host_stream (stream TEXT PRIMARY KEY, snap_seq INTEGER NOT NULL, head INTEGER NOT NULL, state TEXT NOT NULL, tail_bytes INTEGER NOT NULL DEFAULT 0)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS host_event (stream TEXT NOT NULL, seq INTEGER NOT NULL, frame TEXT NOT NULL, PRIMARY KEY (stream, seq))`)
  }

  head(stream: string): StreamHead | undefined {
    const row = this.sql.exec<{ snap_seq: number; head: number; state: string }>(`SELECT snap_seq, head, state FROM host_stream WHERE stream = ?`, stream).toArray()[0]
    return row ? { snapSeq: Number(row.snap_seq), head: Number(row.head), state: JSON.parse(row.state) as unknown } : undefined
  }

  private tailInfo(stream: string): { count: number; bytes: number; min: number | null } {
    const r = this.sql.exec<{ n: number; lo: number | null }>(`SELECT COUNT(*) AS n, MIN(seq) AS lo FROM host_event WHERE stream = ?`, stream).toArray()[0]
    const bytes = Number(this.sql.exec<{ b: number }>(`SELECT tail_bytes AS b FROM host_stream WHERE stream = ?`, stream).toArray()[0]?.b ?? 0)
    return { count: Number(r?.n ?? 0), bytes, min: r?.lo === null || r?.lo === undefined ? null : Number(r.lo) }
  }

  /** Replaces a mirrored stream's snapshot (Mac reconnect, gap repair, compaction); the tail goes. */
  replaceSnapshot(stream: string, seq: number, state: unknown): void {
    const text = JSON.stringify(state)
    this.sql.exec(`DELETE FROM host_event WHERE stream = ?`, stream)
    this.sql.exec(
      `INSERT INTO host_stream (stream, snap_seq, head, state, tail_bytes) VALUES (?, ?, ?, ?, 0) ON CONFLICT(stream) DO UPDATE SET snap_seq = excluded.snap_seq, head = excluded.head, state = excluded.state, tail_bytes = 0`,
      stream,
      seq,
      seq,
      text
    )
  }

  /** Appends one Mac event when it is the next seq. */
  appendMirrored(stream: string, event: EventLike): AppendOutcome {
    const h = this.head(stream)
    if (!h) return "gap"
    if (event.seq <= h.head) return "stale"
    if (event.seq !== h.head + 1) return "gap"
    if (this.tailInfo(stream).count >= MAX_EVENTS) return "full"
    const text = JSON.stringify(event)
    this.sql.exec(`INSERT OR REPLACE INTO host_event (stream, seq, frame) VALUES (?, ?, ?)`, stream, event.seq, text)
    this.sql.exec(`UPDATE host_stream SET head = ?, tail_bytes = tail_bytes + ? WHERE stream = ?`, event.seq, text.length, stream)
    return "applied"
  }

  /** Whether a mirrored stream's tail is past the compaction threshold. */
  wantsCompaction(stream: string): boolean {
    const t = this.tailInfo(stream)
    return t.count >= COMPACT_EVENTS || t.bytes >= COMPACT_BYTES
  }

  /** Commits an owned stream's next state and its event together; returns the event's seq. */
  commitOwned(stream: string, state: unknown, makeEvent: (seq: number) => EventLike): EventLike {
    const seq = (this.head(stream)?.head ?? 0) + 1
    const event = makeEvent(seq)
    this.sql.exec(
      `INSERT INTO host_stream (stream, snap_seq, head, state) VALUES (?, ?, ?, ?) ON CONFLICT(stream) DO UPDATE SET snap_seq = excluded.snap_seq, head = excluded.head, state = excluded.state`,
      stream,
      seq,
      seq,
      JSON.stringify(state)
    )
    this.sql.exec(`INSERT OR REPLACE INTO host_event (stream, seq, frame) VALUES (?, ?, ?)`, stream, seq, JSON.stringify(event))
    this.sql.exec(`DELETE FROM host_event WHERE stream = ? AND seq <= ?`, stream, seq - OWNED_TAIL)
    return event
  }

  /** Events after `after`, oldest first. */
  eventsAfter(stream: string, after: number): Array<EventLike> {
    return this.sql.exec<{ frame: string }>(`SELECT frame FROM host_event WHERE stream = ? AND seq > ? ORDER BY seq`, stream, after).toArray().map((r) => JSON.parse(r.frame) as EventLike)
  }

  /**
   * What a subscriber with `afterSeq` needs: a replay of events when the tail covers the gap,
   * otherwise the snapshot and the events after it. Undefined when the stream has no state yet.
   */
  resume(stream: string, afterSeq: number | undefined): { snapshot?: { seq: number; state: unknown }; events: Array<EventLike> } | undefined {
    const h = this.head(stream)
    if (!h) return undefined
    if (afterSeq !== undefined && afterSeq <= h.head) {
      const min = this.tailInfo(stream).min
      if (afterSeq === h.head) return { events: [] }
      if (afterSeq >= h.snapSeq || (min !== null && afterSeq >= min - 1)) return { events: this.eventsAfter(stream, afterSeq) }
    }
    return { snapshot: { seq: h.snapSeq, state: h.state }, events: this.eventsAfter(stream, h.snapSeq) }
  }
}
