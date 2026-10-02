import type { Tables } from "./schema.ts"
import type { SqlStore } from "./sql.ts"

export interface OutboxRow {
  readonly id: number
  readonly seq: number
  readonly kind: string
  readonly entity: string
  readonly payload: unknown
  readonly target: { readonly class: string; readonly name: string; readonly coalesce?: string } | null
}

/** After this many failed attempts in a row, a channel's head item moves to dead letter. */
export const OUTBOX_MAX_ATTEMPTS = 12
const MAX_BACKOFF_MS = 5 * 60_000

/** '' for PlanetScale projections; '<class>:<name>' for a target object. */
export const channelOf = (target: OutboxRow["target"]): string => (target ? `${target.class}:${target.name}` : "")

/**
 * Outbox delivery state per channel. A failing channel backs off on its own and
 * cannot fill the read window of another (review finding: one dead target must
 * not stop projections or healthy targets). A poison head item leaves the queue
 * for dead letter after OUTBOX_MAX_ATTEMPTS.
 */
export class Outbox {
  private readonly backoff: string

  constructor(
    private readonly sql: SqlStore,
    private readonly t: Tables
  ) {
    this.backoff = `${t.outbox}_backoff`
  }

  /** Channels with pending items whose backoff has passed. */
  dueChannels(now: number): Array<string> {
    return this.sql
      .exec<{ channel: string }>(
        `SELECT DISTINCT o.channel AS channel FROM ${this.t.outbox} o LEFT JOIN ${this.backoff} b ON b.channel = o.channel
         WHERE o.sent_at IS NULL AND o.dead_at IS NULL AND (b.next_at IS NULL OR b.next_at <= ?)`,
        now
      )
      .map((r) => r.channel)
  }

  /** Earliest time a pending channel may run again (now-ish when one is due), or null. */
  nextDueAt(now: number): number | null {
    const r = this.sql.exec<{ at: number | null }>(
      `SELECT MIN(COALESCE(b.next_at, ?)) AS at FROM ${this.t.outbox} o LEFT JOIN ${this.backoff} b ON b.channel = o.channel
       WHERE o.sent_at IS NULL AND o.dead_at IS NULL`,
      now
    )[0]
    return r?.at === null || r?.at === undefined ? null : Math.max(now, Number(r.at))
  }

  pending(channel: string, limit = 100): Array<OutboxRow> {
    return this.sql
      .exec<{ id: number; seq: number; kind: string; entity: string; payload: string; target: string | null }>(
        `SELECT id, seq, kind, entity, payload, target FROM ${this.t.outbox} WHERE channel = ? AND sent_at IS NULL AND dead_at IS NULL ORDER BY id LIMIT ?`,
        channel,
        limit
      )
      .map((r) => ({
        id: Number(r.id),
        seq: Number(r.seq),
        kind: r.kind,
        entity: r.entity,
        payload: JSON.parse(r.payload) as unknown,
        target: r.target ? (JSON.parse(r.target) as OutboxRow["target"]) : null
      }))
  }

  /** Every pending item, oldest first (debug and tests). */
  allPending(limit = 100): Array<OutboxRow> {
    return this.sql
      .exec<{ channel: string }>(`SELECT DISTINCT channel FROM ${this.t.outbox} WHERE sent_at IS NULL AND dead_at IS NULL`)
      .flatMap((c) => this.pending(c.channel, limit))
      .sort((a, b) => a.id - b.id)
      .slice(0, limit)
  }

  markSent(ids: ReadonlyArray<number>, at: number): void {
    if (ids.length === 0) return
    this.sql.transaction(() => {
      for (const id of ids) this.sql.exec(`UPDATE ${this.t.outbox} SET sent_at = ? WHERE id = ?`, at, id)
    })
  }

  succeeded(channel: string): void {
    this.sql.exec(`DELETE FROM ${this.backoff} WHERE channel = ?`, channel)
  }

  /**
   * Records a failed attempt: exponential backoff for this channel only. At the limit the
   * channel's head item goes to dead letter (kept, with dead_at, for debug.desync) and the
   * channel retries the next item at once. Returns the dead item id, if any.
   */
  failed(channel: string, now: number): number | null {
    return this.sql.transaction(() => {
      const prior = this.sql.exec<{ attempts: number }>(`SELECT attempts FROM ${this.backoff} WHERE channel = ?`, channel)[0]
      const attempts = (prior ? Number(prior.attempts) : 0) + 1
      if (attempts >= OUTBOX_MAX_ATTEMPTS) {
        const head = this.pending(channel, 1)[0]
        if (head) this.sql.exec(`UPDATE ${this.t.outbox} SET dead_at = ? WHERE id = ?`, now, head.id)
        this.sql.exec(`DELETE FROM ${this.backoff} WHERE channel = ?`, channel)
        return head?.id ?? null
      }
      const next = now + Math.min(MAX_BACKOFF_MS, 1000 * 2 ** attempts)
      this.sql.exec(
        `INSERT INTO ${this.backoff} (channel, attempts, next_at) VALUES (?, ?, ?) ON CONFLICT (channel) DO UPDATE SET attempts = excluded.attempts, next_at = excluded.next_at`,
        channel,
        attempts,
        next
      )
      return null
    })
  }

  deadCount(): number {
    return Number(this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM ${this.t.outbox} WHERE dead_at IS NOT NULL`)[0]?.n ?? 0)
  }
}
