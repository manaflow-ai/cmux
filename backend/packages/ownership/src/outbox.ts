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

/** After this many POISON failures of the same head item in a row, it moves to dead letter. */
export const OUTBOX_MAX_ATTEMPTS = 12
/**
 * Why a delivery failed. `transient`: the target or PlanetScale is unreachable or overloaded
 * (backoff, retried forever, never dead letter). `poison`: the item itself fails (counts toward
 * dead letter for its own head item only).
 */
export type OutboxFailure = "transient" | "poison"
const MAX_BACKOFF_MS = 5 * 60_000

/** '' for PlanetScale projections; '<class>:<name>' for a target object. */
export const channelOf = (target: OutboxRow["target"]): string => (target ? `${target.class}:${target.name}` : "")

/**
 * Outbox delivery state per channel. A failing channel backs off on its own and
 * cannot fill the read window of another (review finding: one dead target must
 * not stop projections or healthy targets). Transient failures back off forever; a poison
 * head item leaves the queue for dead letter after OUTBOX_MAX_ATTEMPTS poison failures, and
 * `replayDead` puts dead items back (operators, and the daily automatic replay in OwnerDO).
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

  /**
   * A delivered item is deleted (home-scale C-1: sent rows were never deleted, the fastest-growing
   * table). An older dead item for the same channel and key is superseded and goes with it, so a
   * replay can never apply it after the newer one (for example an upsert after a hard delete).
   */
  markSent(ids: ReadonlyArray<number>, _at: number): void {
    if (ids.length === 0) return
    this.sql.transaction(() => {
      for (const id of ids) {
        this.sql.exec(
          `DELETE FROM ${this.t.outbox} WHERE dead_at IS NOT NULL AND id < ? AND (channel, entity) = (SELECT channel, entity FROM ${this.t.outbox} WHERE id = ?)`,
          id,
          id
        )
        this.sql.exec(`DELETE FROM ${this.t.outbox} WHERE id = ?`, id)
      }
    })
  }

  /** Removes rows that an older build marked sent instead of deleting; bounded per call. Returns how many went. */
  pruneSent(limit = 1000): number {
    const ids = this.sql.exec<{ id: number }>(`SELECT id FROM ${this.t.outbox} WHERE sent_at IS NOT NULL LIMIT ?`, limit).map((r) => Number(r.id))
    if (ids.length === 0) return 0
    this.sql.transaction(() => {
      for (const id of ids) this.sql.exec(`DELETE FROM ${this.t.outbox} WHERE id = ?`, id)
    })
    return ids.length
  }

  succeeded(channel: string): void {
    this.sql.exec(`DELETE FROM ${this.backoff} WHERE channel = ?`, channel)
  }

  /** True after a failure until the next success: the drain then sends one item per attempt, so a poison item is found alone. */
  isolating(channel: string): boolean {
    return this.sql.exec(`SELECT 1 FROM ${this.backoff} WHERE channel = ?`, channel).length > 0
  }

  /**
   * Records a failed attempt: exponential backoff (at most 5 minutes) for this channel only.
   * Only `poison` failures count toward dead letter: after OUTBOX_MAX_ATTEMPTS of them in a row the
   * channel's head item goes to dead letter (kept, with dead_at) and the channel retries the next
   * item at once. A transient failure (an outage of any length) never dead-letters. Returns the dead id.
   */
  failed(channel: string, now: number, kind: OutboxFailure = "poison"): number | null {
    return this.sql.transaction(() => {
      const prior = this.sql.exec<{ attempts: number; poison: number }>(`SELECT attempts, poison FROM ${this.backoff} WHERE channel = ?`, channel)[0]
      const attempts = (prior ? Number(prior.attempts) : 0) + 1
      const poison = kind === "poison" ? (prior ? Number(prior.poison) : 0) + 1 : 0
      if (poison >= OUTBOX_MAX_ATTEMPTS) {
        const head = this.pending(channel, 1)[0]
        if (head) this.deadLetter(head.id, now)
        this.sql.exec(`DELETE FROM ${this.backoff} WHERE channel = ?`, channel)
        return head?.id ?? null
      }
      const next = now + Math.min(MAX_BACKOFF_MS, 1000 * 2 ** Math.min(attempts, 20))
      this.sql.exec(
        `INSERT INTO ${this.backoff} (channel, attempts, next_at, poison) VALUES (?, ?, ?, ?)
         ON CONFLICT (channel) DO UPDATE SET attempts = excluded.attempts, next_at = excluded.next_at, poison = excluded.poison`,
        channel,
        attempts,
        next,
        poison
      )
      return null
    })
  }

  /** Moves one item to dead letter (a poison projection row found alone). */
  deadLetter(id: number, now: number): void {
    this.sql.exec(`UPDATE ${this.t.outbox} SET dead_at = ? WHERE id = ? AND sent_at IS NULL`, now, id)
  }

  /**
   * The replay tool: dead items (all, or the given ids, or those dead before `deadBefore`) go back
   * to the queue in their original order. Delivery is idempotent ((stream, seq) guards and target
   * ledgers), so a replay never applies an item twice. Returns how many came back.
   */
  replayDead(now: number, opts: { readonly ids?: ReadonlyArray<number>; readonly deadBefore?: number } = {}): number {
    return this.sql.transaction(() => {
      const rows = this.sql.exec<{ id: number; channel: string }>(
        `SELECT id, channel FROM ${this.t.outbox} WHERE dead_at IS NOT NULL AND sent_at IS NULL AND dead_at <= ?`,
        opts.deadBefore ?? now
      ).filter((r) => !opts.ids || opts.ids.includes(Number(r.id)))
      // Superseded dead items were deleted when the newer item for their key went out (markSent).
      for (const r of rows) this.sql.exec(`UPDATE ${this.t.outbox} SET dead_at = NULL WHERE id = ?`, r.id)
      for (const c of new Set(rows.map((r) => r.channel))) this.sql.exec(`DELETE FROM ${this.backoff} WHERE channel = ?`, c)
      return rows.length
    })
  }

  /** When the oldest dead item died, or null. */
  oldestDeadAt(): number | null {
    const r = this.sql.exec<{ at: number | null }>(`SELECT MIN(dead_at) AS at FROM ${this.t.outbox} WHERE dead_at IS NOT NULL AND sent_at IS NULL`)[0]
    return r?.at === null || r?.at === undefined ? null : Number(r.at)
  }

  deadCount(): number {
    return Number(this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM ${this.t.outbox} WHERE dead_at IS NOT NULL`)[0]?.n ?? 0)
  }
}
