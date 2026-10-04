import { createHash, createHmac } from "node:crypto"
import { claimedPrincipal, settled, stateFull, utf8Length } from "./state-guard.ts"
import { addEventBytes, DEFAULT_EVENT_WINDOW, nextPruneAt, pruneBefore, pruneWindow, windowOver, type EventWindow } from "./event-window.ts"
import { idFactory } from "./ids.ts"
import { channelOf, Outbox, type OutboxRow } from "./outbox.ts"
import { checkWrites, EMPTY_ROWS, readOnly, SqlRows, type RowWrite } from "./rows.ts"
import { migrate, tablesFor, type Tables } from "./schema.ts"
import { scrubStoredParams } from "./events-scrub.ts"
import { type LedgerReplyRedaction, ledgerReplyText, replayedReply, scrubStoredReplies } from "./ledger-reply.ts"
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
  Reject,
  RejectFrame,
  ResultFrame,
  SettledFrame,
  SnapshotFrame
} from "./types.ts"

export type { SqlStore } from "./sql.ts"
export type { OutboxRow } from "./outbox.ts"

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
  /**
   * Row mode only: what subscribers may see of an op's params, the head state and rows, for
   * fields that must stay with the owner (for example an invite's token hash). Applied to
   * events, effects and snapshots; the owner keeps the full values. Not allowed without
   * rowMode, because a JSON domain's mirror replays params and state.
   */
  readonly redact?: {
    readonly params?: (op: string, params: unknown) => unknown
    readonly state?: (state: unknown) => unknown
    readonly row?: (table: string, row: unknown) => unknown
    /** Tables whose writes never leave the owner (their keys may be secrets, for example token hashes). */
    readonly privateTables?: ReadonlyArray<string>
  }
  /**
   * Subscribers never replay ops from event params (they mirror owner-written data the owner
   * attaches to each event, as FeedDO does). Allows `redact.params` without row mode.
   */
  readonly eventsNotReplayed?: boolean
  /** What the request ledger keeps of a reply (ledger-reply.ts). Default: the whole reply. */
  readonly ledgerReply?: LedgerReplyRedaction
  /** What subscribers see of the actor in events. Default: the full principal. */
  readonly eventActor?: (p: Principal) => Principal
  /** Event window (event-window.ts). Default: DEFAULT_EVENT_WINDOW. */
  readonly eventWindow?: Partial<EventWindow>
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
  readonly outbox: Outbox
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
    // Mirrors replay ops from event params, so redacting them needs row mode (events carry the
    // effects) or an owner whose subscribers mirror owner-written data instead (eventsNotReplayed).
    if (options.redact && !options.rowMode && !options.eventsNotReplayed) throw new Error(`redact needs rowMode or eventsNotReplayed (stream ${options.stream})`)
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
    this.outbox = new Outbox(sql, t)
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

  /**
   * What `submit` would do before the reducer, without doing it: "replay" when the key is
   * decided (the ledger answers), the refusal when authorization denies the op, else undefined
   * (the op reaches the reducer). For owners that run an async check outside the pure reducer
   * (for example a code ref in an external store): they skip the check for replays and denials,
   * so a retry of a decided op always gets its original answer. Test mutants (noLedger,
   * trustClaimedIdentity) are not mirrored here; owners with a gate are not mutant subjects.
   */
  gate(principal: Principal, frame: OpFrame): "replay" | Reject | undefined {
    const key = frame.idempotency_key
    if (typeof key !== "string" || key.length === 0 || key.length > 128) return { code: "validation.invalid", message: "idempotency_key is required (1 to 128 characters)" }
    const prior = this.sql.exec<{ one: number }>(`SELECT 1 AS one FROM ${this.t.ledger} WHERE identity = ? AND idempotency_key = ?`, principal.identity, key)[0]
    if (prior) return "replay"
    return this.domain.authorize?.(this.state, frame.op, frame.params as P, principal) ?? undefined
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
        return reply(replayedReply(this.options.ledgerReply, frame.op, stored, this.state), Number(prior.sequence))
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
      // Only row-mode owners have rows: a JSON domain's mirror replays the reducer, so it must
      // never read or write rows the mirror cannot see.
      const rows = this.options.rowMode ? readOnly(this.rows) : EMPTY_ROWS
      const r = this.domain.reduce(this.state, frame.op, frame.params as P, { principal, origin, now: at, tx, newId: idFactory(tx), rows, idempotencyKey: key })
      if (r.ok && (r.writes?.length ?? 0) > 0) {
        if (!this.options.rowMode) throw new Error(`${frame.op}: row writes need rowMode on stream ${this.stream}`)
        checkWrites(r.writes!)
      }
      decision = r.ok
        ? { ok: true, state: r.state, value: r.value, changed: r.changed ?? true, outbox: r.outbox ?? [], writes: r.writes ?? [] }
        : { ok: false, frame: reject(r.code, r.message, r) }
    }

    // The head is one SQLite row (2 MB): past STATE_MAX_BYTES the commit is a retryable owner.state_full (state-guard.ts).
    const stateJson = decision.ok && decision.changed ? JSON.stringify(decision.state) : undefined
    const full = stateJson === undefined ? undefined : stateFull(stateJson, this.stream, frame.op)
    if (full) decision = { ok: false, frame: reject("owner.state_full", full, { retryable: true }) }

    // 4. Commit (state, rows, ledger, events, outbox) in one transaction, then publish.
    const changed = decision.ok && decision.changed
    const nextSeq = changed ? this.seq + 1 : this.seq
    const effects = changed && decision.ok && this.options.rowMode ? { state: this.redactState(decision.state), writes: this.publicWrites(decision.writes) } : undefined
    const event: EventFrame | undefined = changed
      ? {
          t: "event",
          stream: this.stream,
          seq: nextSeq,
          tx,
          op: frame.op,
          params: this.options.redact?.params ? this.options.redact.params(frame.op, frame.params) : frame.params,
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
        this.sql.exec(`INSERT INTO ${t.state} (id, seq, json) VALUES (1, ?, ?) ON CONFLICT (id) DO UPDATE SET seq = excluded.seq, json = excluded.json`, nextSeq, stateJson ?? JSON.stringify(decision.state))
        this.rows.apply(decision.writes)
        const ev = [JSON.stringify(event!.params ?? null), JSON.stringify(event!.actor), effects ? JSON.stringify(effects) : null] as const
        this.sql.exec(`INSERT INTO ${t.events} (seq, tx, op, params, actor, origin, at, effects) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, nextSeq, tx, frame.op, ev[0], ev[1], origin, at, ev[2])
        addEventBytes(this.sql, t, utf8Length(ev[0]) + utf8Length(ev[1]) + (ev[2] === null ? 0 : utf8Length(ev[2])))
        for (const item of decision.outbox) {
          this.sql.exec(
            `INSERT INTO ${t.outbox} (seq, kind, entity, payload, created_at, target, channel) VALUES (?, ?, ?, ?, ?, ?, ?)`,
            nextSeq,
            item.kind,
            item.entity,
            JSON.stringify(item.payload),
            at,
            item.target ? JSON.stringify(item.target) : null,
            channelOf(item.target ?? null)
          )
        }
      }
      // A retryable reject (rate limit, full) is not decided: like an authorization failure it is not
      // recorded, so a retry with the same key is evaluated again instead of replaying the reject.
      const retryableReject = !decision.ok && decision.frame.retryable
      if (!this.options.mutants?.noLedger && !retryableReject) {
        this.sql.exec(
          `INSERT INTO ${t.ledger} (identity, idempotency_key, tx, op, params_hash, ok, reply, sequence, revision, actor, origin, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          identity,
          key,
          tx,
          frame.op,
          paramsHash,
          decision.ok ? 1 : 0,
          ledgerReplyText(this.options.ledgerReply, frame.op, out),
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
    // No pending intents (want = []): no decided keys to report, so no ledger scan.
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
    const tail = mode && !this.options.redact?.privateTables?.includes(mode.snapshotTable)
      ? {
          table: mode.snapshotTable,
          rows: this.rows
            .range(mode.snapshotTable, { limit: mode.snapshotTail, desc: true })
            .reverse()
            .map((r) => (this.options.redact?.row ? { ...r, row: this.options.redact.row(mode.snapshotTable, r.row) } : r))
        }
      : undefined
    return { t: "snapshot", stream: this.stream, seq: this.seq, state: this.redactState(this.state) as S, decided, ...(tail ? { rows: tail } : {}) }
  }

  private redactState(state: S): unknown {
    return this.options.redact?.state ? this.options.redact.state(state) : state
  }

  /** Writes subscribers may see: private tables dropped, row values redacted. */
  private publicWrites(writes: ReadonlyArray<RowWrite>): Array<RowWrite> {
    const hidden = this.options.redact?.privateTables
    return writes.filter((w) => !hidden?.includes(w.table)).map((w) => this.redactWrite(w))
  }

  private redactWrite(w: RowWrite): RowWrite {
    return w.op === "upsert" && this.options.redact?.row ? { ...w, row: this.options.redact.row(w.table, w.row) } : w
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
    if (seq < 0) return false
    const n = this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM ${this.t.events} WHERE seq > ?`, seq)[0]?.n ?? 0
    return Number(n) === this.seq - seq
  }

  /** Rewrites stored `op` events (`redact.params`) and ledger replies (`ledgerReply.store`) past `marker`; returns the rewritten count. */
  scrubStored(op: string, marker: string): number {
    return scrubStoredParams(this.sql, this.t, this.options.redact?.params, op, marker) + scrubStoredReplies(this.sql, this.t, this.options.ledgerReply, op, `${marker}:ledger`)
  }

  /** When the oldest kept event was committed (ms), or null. */
  oldestEventAt(): number | null {
    const r = this.sql.exec<{ at: number | null }>(`SELECT MIN(at) AS at FROM ${this.t.events}`)[0]
    return r?.at === null || r?.at === undefined ? null : Number(r.at)
  }

  /** When the next time-based prune is due (the oldest event outside the floor plus the retention), or null. */
  nextEventPruneAt(retentionMs = this.window.retentionMs, keepLast = this.window.floor): number | null {
    return nextPruneAt(this.sql, this.t, this.seq, retentionMs, keepLast)
  }

  /** Deletes a bounded contiguous prefix older than `before`, never one of the newest `keepLast` (event-window.ts). */
  pruneEvents(before: number, keepLast = EVENT_KEEP_LAST, limit = 1000): number {
    return pruneBefore(this.sql, this.t, this.seq, before, keepLast, limit)
  }

  private get window(): EventWindow {
    return { ...DEFAULT_EVENT_WINDOW, ...this.options.eventWindow }
  }

  /** True when the log is past its count or byte cap (event-window.ts). */
  eventWindowDue = (_now: number): boolean => windowOver(this.sql, this.t, this.seq, this.window)

  /** One bounded prune of the event window: time first, then count and bytes. Returns how many went. */
  pruneEventWindow = (now: number): number => this.pruneEvents(now - this.window.retentionMs, this.window.floor) + pruneWindow(this.sql, this.t, this.seq, this.window)

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

  /** Every pending outbox item, oldest first (debug, tests). Delivery uses `outbox` per channel. */
  outboxPending(limit = 100): Array<OutboxRow> {
    return this.outbox.allPending(limit)
  }

  outboxMarkSent(ids: ReadonlyArray<number>): void {
    this.outbox.markSent(ids, this.now())
  }

  /** Admin dump for `debug.desync`. */
  debugDump(tail = 50) {
    return {
      stream: this.stream,
      seq: this.seq,
      state: this.state,
      ledger: this.sql.exec(`SELECT identity, idempotency_key, tx, op, ok, sequence, origin, created_at FROM ${this.t.ledger} ORDER BY created_at DESC LIMIT ?`, tail),
      events: this.eventsAfter(Math.max(0, this.seq - tail)),
      outbox_pending: this.outboxPending(tail).length,
      outbox_dead: this.outbox.deadCount()
    }
  }
}

