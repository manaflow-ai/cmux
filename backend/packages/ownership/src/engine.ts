import { createHash, createHmac } from "node:crypto"
import { idFactory } from "./ids.ts"
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

/**
 * Synchronous SQL, shaped like Durable Object `ctx.storage.sql` so the same
 * engine runs in a DO and in node:sqlite tests.
 */
export interface SqlStore {
  exec<T = Record<string, unknown>>(query: string, ...params: Array<unknown>): Array<T>
  /** Runs `fn` atomically. A throw rolls back every write. */
  transaction<T>(fn: () => T): T
}

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

const SCHEMA_VERSION = 1
const ORIGINS = new Set(["user", "cli", "mcp", "script", "remote"])

const MIGRATIONS: ReadonlyArray<string> = [
  `CREATE TABLE IF NOT EXISTS own_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS own_state (id INTEGER PRIMARY KEY CHECK (id = 1), seq INTEGER NOT NULL, json TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS own_ledger (
     identity TEXT NOT NULL,
     idempotency_key TEXT NOT NULL,
     tx TEXT NOT NULL,
     op TEXT NOT NULL,
     params_hash TEXT NOT NULL,
     ok INTEGER NOT NULL,
     reply TEXT NOT NULL,
     sequence INTEGER NOT NULL,
     revision TEXT NOT NULL,
     actor TEXT NOT NULL,
     origin TEXT NOT NULL,
     created_at INTEGER NOT NULL,
     PRIMARY KEY (identity, idempotency_key))`,
  `CREATE TABLE IF NOT EXISTS own_events (
     seq INTEGER PRIMARY KEY,
     tx TEXT NOT NULL,
     op TEXT NOT NULL,
     params TEXT NOT NULL,
     actor TEXT NOT NULL,
     origin TEXT NOT NULL,
     at INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS own_outbox (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     seq INTEGER NOT NULL,
     kind TEXT NOT NULL,
     entity TEXT NOT NULL,
     payload TEXT NOT NULL,
     created_at INTEGER NOT NULL,
     sent_at INTEGER)`,
  // Ledger pruning finds the oldest key without a scan.
  `CREATE INDEX IF NOT EXISTS own_ledger_created ON own_ledger (created_at)`
]

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
}

/**
 * The single writer of one entity (spec/sync-and-transport.md section 7):
 * ledger check, authorization, pure reducer, one transaction for state +
 * ledger + events + outbox, and only then publish events, result and
 * `request-settled` (commit before publish).
 */
export class OwnerEngine<S, P = unknown> {
  readonly stream: string
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
    sql.transaction(() => {
      for (const m of MIGRATIONS) sql.exec(m)
      const version = sql.exec<{ value: string }>(`SELECT value FROM own_meta WHERE key = 'schema_version'`)[0]
      if (!version) sql.exec(`INSERT INTO own_meta (key, value) VALUES ('schema_version', ?)`, String(SCHEMA_VERSION))
      // Per-object secret for transaction tags: other subscribers see the tag
      // but cannot derive the client's key (ownership.md mutation-echo-v1).
      const secret = sql.exec<{ value: string }>(`SELECT value FROM own_meta WHERE key = 'tx_secret'`)[0]
      if (!secret) sql.exec(`INSERT INTO own_meta (key, value) VALUES ('tx_secret', ?)`, createHash("sha256").update(`${crypto.randomUUID()}${crypto.randomUUID()}`).digest("base64url"))
    })
    this.secret = sql.exec<{ value: string }>(`SELECT value FROM own_meta WHERE key = 'tx_secret'`)[0]!.value
    const row = sql.exec<{ seq: number; json: string }>(`SELECT seq, json FROM own_state WHERE id = 1`)[0]
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
    const principal = this.options.mutants?.trustClaimedIdentity
      ? claimedPrincipal(principalIn, frame.params)
      : principalIn
    const identity = principal.identity
    const key = frame.idempotency_key
    if (typeof key !== "string" || key.length === 0 || key.length > 128) {
      const bad = typeof key === "string" ? key : ""
      deliver(identity, { t: "reject", tx: "", idempotency_key: bad, code: "validation.invalid", message: "idempotency_key is required (1 to 128 characters)", retryable: false, replayed: false })
      deliver(identity, settled(this.stream, "", bad, 0, false))
      return
    }
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
      const prior = this.sql.exec<LedgerRow>(
        `SELECT tx, params_hash, ok, reply, sequence, revision FROM own_ledger WHERE identity = ? AND idempotency_key = ?`,
        identity,
        key
      )[0]
      if (prior) {
        if (prior.params_hash !== paramsHash) {
          return reply(reject("idempotency.conflict", "idempotency key reused with different params"), 0)
        }
        const stored = JSON.parse(prior.reply) as ResultFrame | RejectFrame
        return reply({ ...stored, replayed: true }, Number(prior.sequence))
      }
    }

    // 2. Authorization. Not recorded: a later grant may allow the same key.
    const denied = this.domain.authorize?.(this.state, frame.op, frame.params as P, principal)
    if (denied) return reply(reject(denied.code, denied.message, denied), 0)

    // 3. Decide: revision precondition, then the pure reducer.
    let decision: { ok: true; state: S; value: unknown; changed: boolean; outbox: ReadonlyArray<OutboxItem> } | { ok: false; frame: RejectFrame }
    if (frame.expected_revision !== undefined && frame.expected_revision !== String(this.seq)) {
      decision = {
        ok: false,
        frame: reject("revision.conflict", "expected_revision does not match", {
          details: { expected: frame.expected_revision, actual: String(this.seq) }
        })
      }
    } else {
      const r = this.domain.reduce(this.state, frame.op, frame.params as P, {
        principal,
        origin,
        now: at,
        tx,
        newId: idFactory(tx)
      })
      decision = r.ok
        ? { ok: true, state: r.state, value: r.value, changed: r.changed ?? true, outbox: r.outbox ?? [] }
        : { ok: false, frame: reject(r.code, r.message, r) }
    }

    // 4. Commit (state, ledger, events, outbox) in one transaction, then publish.
    const nextSeq = decision.ok && decision.changed ? this.seq + 1 : this.seq
    const event: EventFrame | undefined =
      decision.ok && decision.changed
        ? { t: "event", stream: this.stream, seq: nextSeq, tx, op: frame.op, params: frame.params, actor: this.options.eventActor?.(principal) ?? principal, origin, at }
        : undefined
    const sequence = event ? event.seq : 0
    const out: ResultFrame | RejectFrame = decision.ok
      ? { t: "result", tx, idempotency_key: key, value: decision.value, revision: String(nextSeq), replayed: false }
      : decision.frame

    const publish = () => {
      if (event) deliver("all", event)
      reply(out, sequence)
    }

    if (this.options.mutants?.publishBeforeCommit) publish()
    this.sql.transaction(() => {
      if (decision.ok && decision.changed) {
        this.sql.exec(
          `INSERT INTO own_state (id, seq, json) VALUES (1, ?, ?) ON CONFLICT (id) DO UPDATE SET seq = excluded.seq, json = excluded.json`,
          nextSeq,
          JSON.stringify(decision.state)
        )
        this.sql.exec(
          `INSERT INTO own_events (seq, tx, op, params, actor, origin, at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
          nextSeq,
          tx,
          frame.op,
          JSON.stringify(frame.params ?? null),
          JSON.stringify(event!.actor),
          origin,
          at
        )
        for (const item of decision.outbox) {
          this.sql.exec(
            `INSERT INTO own_outbox (seq, kind, entity, payload, created_at) VALUES (?, ?, ?, ?, ?)`,
            nextSeq,
            item.kind,
            item.entity,
            JSON.stringify(item.payload),
            at
          )
        }
      }
      // A retryable reject (rate limit, full) is not decided: like an authorization failure it is not
      // recorded, so a retry with the same key is evaluated again instead of replaying the reject.
      const retryableReject = !decision.ok && decision.frame.retryable
      if (!this.options.mutants?.noLedger && !retryableReject) {
        this.sql.exec(
          `INSERT INTO own_ledger (identity, idempotency_key, tx, op, params_hash, ok, reply, sequence, revision, actor, origin, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
    if (decision.ok && decision.changed) {
      this.state = decision.state
      this.seq = nextSeq
    }
    if (!this.options.mutants?.publishBeforeCommit) publish()
  }

  /** Snapshot for one identity; `pending` narrows `decided` to the keys the client still holds. */
  snapshot(identity: string, pending?: ReadonlyArray<string>): SnapshotFrame<S> {
    const rows = this.sql.exec<{ idempotency_key: string; ok: number; sequence: number }>(
      `SELECT idempotency_key, ok, sequence FROM own_ledger WHERE identity = ? ORDER BY created_at`,
      identity
    )
    const want = pending ? new Set(pending) : undefined
    const decided: Array<DecidedKey> = rows
      .filter((r) => !want || want.has(r.idempotency_key))
      .map((r) => ({ idempotency_key: r.idempotency_key, ok: Number(r.ok) === 1, sequence: Number(r.sequence) }))
    return { t: "snapshot", stream: this.stream, seq: this.seq, state: this.state, decided }
  }

  /** Committed events after `seq`, for resume. */
  eventsAfter(seq: number, limit = 1000): Array<EventFrame> {
    return this.sql
      .exec<{ seq: number; tx: string; op: string; params: string; actor: string; origin: string; at: number }>(
        `SELECT seq, tx, op, params, actor, origin, at FROM own_events WHERE seq > ? ORDER BY seq LIMIT ?`,
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
        at: Number(r.at)
      }))
  }

  /** When the oldest decided key was recorded (ms), or null for an empty ledger. */
  oldestLedgerAt(): number | null {
    const row = this.sql.exec<{ at: number | null }>(`SELECT MIN(created_at) AS at FROM own_ledger`)[0]
    return row?.at === null || row?.at === undefined ? null : Number(row.at)
  }

  /**
   * Forgets decided keys recorded before `before` (the replay window): a retry
   * with such a key applies again, and snapshots stop listing it. Bounded per
   * call; returns how many rows went.
   */
  pruneLedger(before: number, limit = 1000): number {
    return this.sql.transaction(() => {
      const rows = this.sql.exec<{ identity: string; idempotency_key: string }>(
        `SELECT identity, idempotency_key FROM own_ledger WHERE created_at < ? ORDER BY created_at LIMIT ?`,
        before,
        limit
      )
      for (const r of rows) this.sql.exec(`DELETE FROM own_ledger WHERE identity = ? AND idempotency_key = ?`, r.identity, r.idempotency_key)
      return rows.length
    })
  }

  outboxPending(limit = 100): Array<OutboxRow> {
    return this.sql
      .exec<{ id: number; seq: number; kind: string; entity: string; payload: string }>(
        `SELECT id, seq, kind, entity, payload FROM own_outbox WHERE sent_at IS NULL ORDER BY id LIMIT ?`,
        limit
      )
      .map((r) => ({ id: Number(r.id), seq: Number(r.seq), kind: r.kind, entity: r.entity, payload: JSON.parse(r.payload) as unknown }))
  }

  outboxMarkSent(ids: ReadonlyArray<number>): void {
    if (ids.length === 0) return
    const at = this.now()
    this.sql.transaction(() => {
      for (const id of ids) this.sql.exec(`UPDATE own_outbox SET sent_at = ? WHERE id = ?`, at, id)
    })
  }

  /** Admin dump for `debug.desync`. */
  debugDump(tail = 50) {
    return {
      stream: this.stream,
      seq: this.seq,
      state: this.state,
      ledger: this.sql.exec(`SELECT identity, idempotency_key, tx, op, ok, sequence, origin, created_at FROM own_ledger ORDER BY created_at DESC LIMIT ?`, tail),
      events: this.eventsAfter(Math.max(0, this.seq - tail)),
      outbox_pending: this.outboxPending(tail).length
    }
  }
}

const settled = (stream: string, tx: string, key: string, sequence: number, ok: boolean): SettledFrame => ({
  t: "request-settled",
  tx,
  idempotency_key: key,
  stream,
  sequence,
  ok
})

/** The TrustClaimedOwner mutant: identity taken from the request body. */
const claimedPrincipal = (p: Principal, params: unknown): Principal => {
  const claimed = (params as { claimed_identity?: unknown } | null)?.claimed_identity
  return typeof claimed === "string" ? { ...p, identity: claimed } : p
}
