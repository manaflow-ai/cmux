import { createHash, createHmac } from "node:crypto"
import { idFactory } from "./ids.ts"
import { checkWrites, SqlRows, type RowWrite } from "./rows.ts"
import { migrate, tablesFor, type Tables } from "./schema.ts"
import type { SqlStore } from "./sql.ts"
import type {
  DecidedKey,
  Domain,
  EventFrame,
  OpFrame,
  Origin,
  OutboxItem,
  OwnerFrame,
  Principal,
  RejectFrame,
  ResultFrame,
  SettledFrame,
  SnapshotFrame
} from "./types.ts"

export type { SqlStore } from "./sql.ts"

/** Where committed frames go. `"all"` = every subscriber of the stream. */
export type Deliver = (target: "all" | string, frame: OwnerFrame) => void

/**
 * Deliberately broken variants for the mutation tests (formal/README.md
 * mutants). Production code never sets these.
 */
export interface EngineMutants {
  readonly noLedger?: boolean
  readonly publishBeforeCommit?: boolean
  readonly trustClaimedIdentity?: boolean
}

export interface EngineOptions {
  readonly stream: string
  /** Table prefix (default `own_`); one per stream when an object hosts several (E2). */
  readonly prefix?: string
  /**
   * Row mode (E1): events carry their effects (head state and row writes) and snapshots
   * carry the newest rows of `snapshotTable`, so mirrors never need hidden rows.
   */
  readonly rowMode?: { readonly snapshotTable: string; readonly snapshotTail: number }
  readonly now?: () => number
  readonly mutants?: EngineMutants
  /** Test hook: called inside the commit transaction; a throw models a crash before commit. */
  readonly beforeCommit?: () => void
  /** What subscribers see of the actor in events. Default: the full principal. */
  readonly eventActor?: (p: Principal) => Principal
}

/**
 * Replay window of the request ledger (7 days). Decided keys older than this
 * are pruned (`pruneLedger`); a request with a pruned key applies again. Safe
 * because clients never resend a key older than INTENT_TTL_MS (24 h,
 * client.ts) and owners derive their own system keys from state checks.
 */
export const LEDGER_RETENTION_MS = 7 * 24 * 3600_000

/**
 * Event log retention (E3): events older than 30 days go, but the newest
 * EVENT_KEEP_LAST always stay. A resume from before the oldest kept event gets
 * a snapshot instead of a replay (`canReplayFrom`).
 */
export const EVENT_RETENTION_MS = 30 * 24 * 3600_000
export const EVENT_KEEP_LAST = 10_000

const ORIGINS = new Set(["user", "cli", "mcp", "script", "remote"])

/** Canonical JSON (sorted keys) so equal params hash equally. */
export const canonicalJson = (value: unknown): string =>
  JSON.stringify(value, (_k, v: unknown) =>
    v && typeof v === "object" && !Array.isArray(v)
      ? Object.fromEntries(Object.entries(v as Record<string, unknown>).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))
      : v
  ) ?? "null"

const sha256 = (s: string) => createHash("sha256").update(s).digest("base64url")

interface LedgerRow {
  tx: string
  params_hash: string
  ok: number
  reply: string
  sequence: number
  revision: string
}

export interface OutboxRow {
  readonly id: number
  readonly seq: number
  readonly kind: string
  readonly entity: string
  readonly payload: unknown
  readonly target: { readonly class: string; readonly name: string; readonly coalesce?: string } | null
}

type Decision<S> =
  | { ok: true; state: S; value: unknown; changed: boolean; outbox: ReadonlyArray<OutboxItem>; writes: ReadonlyArray<RowWrite> }
  | { ok: false; frame: RejectFrame }

/**
 * The single writer of one entity (spec/sync-and-transport.md section 7):
 * ledger check, authorization, pure reducer, one transaction for state +
 * rows + ledger + events + outbox, and only then publish events, result and
 * `request-settled` (commit before publish).
 */
export class OwnerEngine<S, P = unknown> {
  readonly stream: string
  readonly rows: SqlRows
  private readonly t: Tables
  private state: S
  private seq: number
  private readonly secret: string
  private readonly now: () => number

  constructor(
    private readonly sql: SqlStore,
    private readonly domain: Domain<S, P>,
    private readonly options: EngineOptions
  ) {
    this.stream = options.stream
    this.now = options.now ?? Date.now
    this.t = tablesFor(options.prefix)
    const t = this.t
    sql.transaction(() => {
      migrate(sql, t)
      // Per-object secret for transaction tags: other subscribers see the tag
      // but cannot derive the client's key (ownership.md mutation-echo-v1).
      const secret = sql.exec<{ value: string }>(`SELECT value FROM ${t.meta} WHERE key = 'tx_secret'`)[0]
      if (!secret) sql.exec(`INSERT INTO ${t.meta} (key, value) VALUES ('tx_secret', ?)`, createHash("sha256").update(`${crypto.randomUUID()}${crypto.randomUUID()}`).digest("base64url"))
    })
    this.secret = sql.exec<{ value: string }>(`SELECT value FROM ${t.meta} WHERE key = 'tx_secret'`)[0]!.value
    this.rows = new SqlRows(sql, t.rows)
    const row = sql.exec<{ seq: number; json: string }>(`SELECT seq, json FROM ${t.state} WHERE id = 1`)[0]
    this.state = row ? (JSON.parse(row.json) as S) : domain.initial()
    this.seq = row ? Number(row.seq) : 0
  }

  get currentState(): S {
    return this.state
  }

  get currentSeq(): number {
    return this.seq
  }

  txTag(identity: string, key: string): string {
    return createHmac("sha256", this.secret).update(identity).update("\u0000").update(key).digest("base64url").slice(0, 22)
  }

  /** Handles one op from an authenticated connection. Frames go out through `deliver`. */
  submit(principalIn: Principal, frame: OpFrame, deliver: Deliver): void {
    const principal = this.options.mutants?.trustClaimedIdentity ? claimedPrincipal(principalIn, frame.params) : principalIn
    const identity = principal.identity
    const key = frame.idempotency_key
    if (typeof key !== "string" || key.length === 0 || key.length > 128) {
      const bad = typeof key === "string" ? key : ""
      deliver(identity, { t: "reject", tx: "", idempotency_key: bad, code: "validation.invalid", message: "idempotency_key is required (1 to 128 characters)", retryable: false, replayed: false })
      deliver(identity, settled(this.stream, "", bad, 0, false))
      return
    }
    const t = this.t
    const origin: Origin = ORIGINS.has(frame.origin as string) ? (frame.origin as Origin) : "cli"
    const tx = this.txTag(identity, key)
    const paramsHash = sha256(canonicalJson({ op: frame.op, params: frame.params }))
    const at = this.now()

    const reply = (r: ResultFrame | RejectFrame, sequence: number) => {
      deliver(identity, r)
      deliver(identity, settled(this.stream, tx, key, sequence, r.t === "result"))
    }
    const reject = (code: string, message: string, extra: { details?: unknown; retryable?: boolean } = {}): RejectFrame => ({
      t: "reject",
      tx,
      idempotency_key: key,
      code,
      message,
      ...(extra.details === undefined ? {} : { details: extra.details }),
      retryable: extra.retryable ?? false,
      replayed: false
    })

    // 1. Ledger: a decided key answers from the ledger with its original sequence.
    if (!this.options.mutants?.noLedger) {
      const prior = this.sql.exec<LedgerRow>(`SELECT tx, params_hash, ok, reply, sequence, revision FROM ${t.ledger} WHERE identity = ? AND idempotency_key = ?`, identity, key)[0]
      if (prior) {
        if (prior.params_hash !== paramsHash) return reply(reject("idempotency.conflict", "idempotency key reused with different params"), 0)
        const stored = JSON.parse(prior.reply) as ResultFrame | RejectFrame
        return reply({ ...stored, replayed: true }, Number(prior.sequence))
      }
    }

    // 2. Authorization. Not recorded: a later grant may allow the same key.
    const denied = this.domain.authorize?.(this.state, frame.op, frame.params as P, principal)
    if (denied) return reply(reject(denied.code, denied.message, denied), 0)

    // 3. Decide: revision precondition, then the pure reducer (rows read-only).
    let decision: Decision<S>
    if (frame.expected_revision !== undefined && frame.expected_revision !== String(this.seq)) {
      decision = { ok: false, frame: reject("revision.conflict", "expected_revision does not match", { details: { expected: frame.expected_revision, actual: String(this.seq) } }) }
    } else {
      const r = this.domain.reduce(this.state, frame.op, frame.params as P, { principal, now: at, tx, newId: idFactory(tx), rows: this.rows })
      if (r.ok) checkWrites(r.writes ?? [])
      decision = r.ok
        ? { ok: true, state: r.state, value: r.value, changed: r.changed ?? true, outbox: r.outbox ?? [], writes: r.writes ?? [] }
        : { ok: false, frame: reject(r.code, r.message, r) }
    }

    // 4. Commit (state, rows, ledger, events, outbox) in one transaction, then publish.
    const changed = decision.ok && decision.changed
    const nextSeq = changed ? this.seq + 1 : this.seq
    const effects = changed && decision.ok && this.options.rowMode ? { state: decision.state as unknown, writes: decision.writes } : undefined
    const event: EventFrame | undefined = changed
      ? {
          t: "event",
          stream: this.stream,
          seq: nextSeq,
          tx,
          op: frame.op,
          params: frame.params,
          actor: this.options.eventActor?.(principal) ?? principal,
          origin,
          at,
          ...(effects ? { effects } : {})
        }
      : undefined
    const sequence = event ? event.seq : 0
    const out: ResultFrame | RejectFrame = decision.ok ? { t: "result", tx, idempotency_key: key, value: decision.value, revision: String(nextSeq), replayed: false } : decision.frame

    const publish = () => {
      if (event) deliver("all", event)
      reply(out, sequence)
    }

    if (this.options.mutants?.publishBeforeCommit) publish()
    this.sql.transaction(() => {
      if (changed && decision.ok) {
        this.sql.exec(`INSERT INTO ${t.state} (id, seq, json) VALUES (1, ?, ?) ON CONFLICT (id) DO UPDATE SET seq = excluded.seq, json = excluded.json`, nextSeq, JSON.stringify(decision.state))
        this.rows.apply(decision.writes)
        this.sql.exec(
          `INSERT INTO ${t.events} (seq, tx, op, params, actor, origin, at, effects) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
          nextSeq,
          tx,
          frame.op,
          JSON.stringify(frame.params ?? null),
          JSON.stringify(event!.actor),
          origin,
          at,
          effects ? JSON.stringify(effects) : null
        )
        for (const item of decision.outbox) {
          this.sql.exec(
            `INSERT INTO ${t.outbox} (seq, kind, entity, payload, created_at, target) VALUES (?, ?, ?, ?, ?, ?)`,
            nextSeq,
            item.kind,
            item.entity,
            JSON.stringify(item.payload),
            at,
            item.target ? JSON.stringify(item.target) : null
          )
        }
      }
      if (!this.options.mutants?.noLedger) {
        this.sql.exec(
          `INSERT INTO ${t.ledger} (identity, idempotency_key, tx, op, params_hash, ok, reply, sequence, revision, actor, origin, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          identity,
          key,
          tx,
          frame.op,
          paramsHash,
          decision.ok ? 1 : 0,
          JSON.stringify(out),
          sequence,
          String(nextSeq),
          JSON.stringify(principal),
          origin,
          at
        )
      }
      this.options.beforeCommit?.()
    })
    if (changed && decision.ok) {
      this.state = decision.state
      this.seq = nextSeq
    }
    if (!this.options.mutants?.publishBeforeCommit) publish()
  }

  /** Snapshot for one identity; `pending` narrows `decided` to the keys the client still holds. */
  snapshot(identity: string, pending?: ReadonlyArray<string>): SnapshotFrame<S> {
    const want = pending ? [...new Set(pending)].slice(0, 500) : undefined
    const rows = want
      ? want.length === 0
        ? []
        : this.sql.exec<{ idempotency_key: string; ok: number; sequence: number }>(
            `SELECT idempotency_key, ok, sequence FROM ${this.t.ledger} WHERE identity = ? AND idempotency_key IN (${want.map(() => "?").join(",")})`,
            identity,
            ...want
          )
      : this.sql.exec<{ idempotency_key: string; ok: number; sequence: number }>(`SELECT idempotency_key, ok, sequence FROM ${this.t.ledger} WHERE identity = ? ORDER BY created_at`, identity)
    const decided: Array<DecidedKey> = rows.map((r) => ({ idempotency_key: r.idempotency_key, ok: Number(r.ok) === 1, sequence: Number(r.sequence) }))
    const mode = this.options.rowMode
    const tail = mode ? { table: mode.snapshotTable, rows: this.rows.range(mode.snapshotTable, { limit: mode.snapshotTail, desc: true }).reverse() } : undefined
    return { t: "snapshot", stream: this.stream, seq: this.seq, state: this.state, decided, ...(tail ? { rows: tail } : {}) }
  }

  /** Committed events after `seq`, for resume. Check `canReplayFrom` first. */
  eventsAfter(seq: number, limit = 1000): Array<EventFrame> {
    return this.sql
      .exec<{ seq: number; tx: string; op: string; params: string; actor: string; origin: string; at: number; effects: string | null }>(
        `SELECT seq, tx, op, params, actor, origin, at, effects FROM ${this.t.events} WHERE seq > ? ORDER BY seq LIMIT ?`,
        seq,
        limit
      )
      .map((r) => ({
        t: "event" as const,
        stream: this.stream,
        seq: Number(r.seq),
        tx: r.tx,
        op: r.op,
        params: JSON.parse(r.params) as unknown,
        actor: JSON.parse(r.actor) as Principal,
        origin: r.origin as Origin,
        at: Number(r.at),
        ...(r.effects ? { effects: JSON.parse(r.effects) as EventFrame["effects"] } : {})
      }))
  }

  /** True when every event after `seq` is still stored (otherwise send a snapshot). */
  canReplayFrom(seq: number): boolean {
    if (seq >= this.seq) return true
    const oldest = this.sql.exec<{ s: number | null }>(`SELECT MIN(seq) AS s FROM ${this.t.events}`)[0]?.s
    return oldest !== null && oldest !== undefined && Number(oldest) <= seq + 1
  }

  /** When the oldest kept event was committed (ms), or null. */
  oldestEventAt(): number | null {
    const r = this.sql.exec<{ at: number | null }>(`SELECT MIN(at) AS at FROM ${this.t.events}`)[0]
    return r?.at === null || r?.at === undefined ? null : Number(r.at)
  }

  /**
   * When the next event prune is due: the oldest event beyond the newest `keepLast`, plus the
   * retention; null when nothing can be pruned (so a quiet object never wakes for it).
   */
  nextEventPruneAt(retentionMs = EVENT_RETENTION_MS, keepLast = EVENT_KEEP_LAST): number | null {
    const floor = this.seq - keepLast
    if (floor <= 0) return null
    const r = this.sql.exec<{ at: number | null }>(`SELECT MIN(at) AS at FROM ${this.t.events} WHERE seq <= ?`, floor)[0]
    return r?.at === null || r?.at === undefined ? null : Number(r.at) + retentionMs
  }

  /** Deletes events committed before `before`, never one of the newest `keepLast`. Bounded per call. */
  pruneEvents(before: number, keepLast = EVENT_KEEP_LAST, limit = 1000): number {
    const floor = this.seq - keepLast
    if (floor <= 0) return 0
    return this.sql.transaction(() => {
      const seqs = this.sql.exec<{ seq: number }>(`SELECT seq FROM ${this.t.events} WHERE at < ? AND seq <= ? ORDER BY seq LIMIT ?`, before, floor, limit).map((r) => Number(r.seq))
      if (seqs.length) this.sql.exec(`DELETE FROM ${this.t.events} WHERE seq <= ? AND at < ?`, seqs[seqs.length - 1]!, before)
      return seqs.length
    })
  }

  /** When the oldest decided key was recorded (ms), or null for an empty ledger. */
  oldestLedgerAt(): number | null {
    const row = this.sql.exec<{ at: number | null }>(`SELECT MIN(created_at) AS at FROM ${this.t.ledger}`)[0]
    return row?.at === null || row?.at === undefined ? null : Number(row.at)
  }

  /**
   * Forgets decided keys recorded before `before` (the replay window): a retry
   * with such a key applies again, and snapshots stop listing it. Bounded per
   * call; returns how many rows went.
   */
  pruneLedger(before: number, limit = 1000): number {
    return this.sql.transaction(() => {
      const rows = this.sql.exec<{ identity: string; idempotency_key: string }>(`SELECT identity, idempotency_key FROM ${this.t.ledger} WHERE created_at < ? ORDER BY created_at LIMIT ?`, before, limit)
      for (const r of rows) this.sql.exec(`DELETE FROM ${this.t.ledger} WHERE identity = ? AND idempotency_key = ?`, r.identity, r.idempotency_key)
      return rows.length
    })
  }

  outboxPending(limit = 100): Array<OutboxRow> {
    return this.sql
      .exec<{ id: number; seq: number; kind: string; entity: string; payload: string; target: string | null }>(
        `SELECT id, seq, kind, entity, payload, target FROM ${this.t.outbox} WHERE sent_at IS NULL ORDER BY id LIMIT ?`,
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

  outboxMarkSent(ids: ReadonlyArray<number>): void {
    if (ids.length === 0) return
    const at = this.now()
    this.sql.transaction(() => {
      for (const id of ids) this.sql.exec(`UPDATE ${this.t.outbox} SET sent_at = ? WHERE id = ?`, at, id)
    })
  }

  /** Admin dump for `debug.desync`. */
  debugDump(tail = 50) {
    return {
      stream: this.stream,
      seq: this.seq,
      state: this.state,
      ledger: this.sql.exec(`SELECT identity, idempotency_key, tx, op, ok, sequence, origin, created_at FROM ${this.t.ledger} ORDER BY created_at DESC LIMIT ?`, tail),
      events: this.eventsAfter(Math.max(0, this.seq - tail)),
      outbox_pending: this.outboxPending(tail).length
    }
  }
}

const settled = (stream: string, tx: string, key: string, sequence: number, ok: boolean): SettledFrame => ({ t: "request-settled", tx, idempotency_key: key, stream, sequence, ok })

/** The TrustClaimedOwner mutant: identity taken from the request body. */
const claimedPrincipal = (p: Principal, params: unknown): Principal => {
  const claimed = (params as { claimed_identity?: unknown } | null)?.claimed_identity
  return typeof claimed === "string" ? { ...p, identity: claimed } : p
}
