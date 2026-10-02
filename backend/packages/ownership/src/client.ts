import { idFactory } from "./ids.ts"
import { MemoryRows, OverlayRows } from "./rows.ts"
import type { Domain, EventFrame, OpFrame, Origin, OwnerFrame, Principal, SettledFrame, SnapshotFrame } from "./types.ts"

export interface Intent<P = unknown> {
  readonly idempotency_key: string
  readonly op: string
  readonly params: P
  readonly origin: Origin
}

/** Deliberately broken client variants for the mutation tests. */
export interface ClientMutants {
  readonly noGapCheck?: boolean
  readonly dropAtNextDelta?: boolean
  readonly settleBeforeMirror?: boolean
  readonly noResendOnReconnect?: boolean
}

/**
 * Longest a client keeps a pending intent (24 h). Owners forget decided keys
 * after LEDGER_RETENTION_MS (7 days, engine.ts); a client never resends a key
 * older than this, so a resend can never reach an owner that pruned the
 * original decision and apply it a second time. Expired intents move to
 * `expired` and are surfaced to the user, never resent.
 */
export const INTENT_TTL_MS = 24 * 3600_000

export type ClientOut = { readonly t: "op"; readonly frame: OpFrame } | { readonly t: "snapshot.request"; readonly pending: ReadonlyArray<string> }

export class OwnerUnreachable extends Error {
  readonly code = "owner_unreachable"
  constructor() {
    super("owner unreachable: changes are refused while offline (U5)")
  }
}

/**
 * A client projection (OWNERSHIP-PRINCIPLES "Clients are projections"): a
 * confirmed mirror written only by owner frames plus one ordered intent log.
 * Visible state = mirror with the intents overlaid by the same reducer.
 */
export class ProjectionClient<S, P = unknown> {
  confirmed: { state: S; seq: number }
  /** Rows of a row-backed domain the mirror holds (snapshot tail plus applied effects). */
  readonly rows = new MemoryRows()
  pending: Array<Intent<P>> = []
  /** `ok` settles that arrived before the mirror reached their sequence (client memory). */
  held: Array<SettledFrame> = []
  /** Keys this client settled as applied (history, for invariant checks). */
  readonly settledOk = new Set<string>()
  connected = true
  awaiting = false
  /** Committed events the local reducer refused (schema skew or a bug); each one triggers a snapshot. */
  desyncs = 0
  /** Intents dropped because they outlived INTENT_TTL_MS without a settle; never resent. */
  expired: Array<Intent<P>> = []
  /** Clock for intent ages (tests replace it). */
  clock: () => number = Date.now
  private buffered: Array<EventFrame> = []
  private counter = 0
  private readonly issuedAt = new Map<string, number>()

  constructor(
    private readonly domain: Domain<S, P>,
    readonly principal: Principal,
    private readonly send: (out: ClientOut) => void,
    private readonly mutants: ClientMutants = {},
    private readonly keyPrefix = `${principal.identity}:${Math.random().toString(36).slice(2, 8)}`
  ) {
    this.confirmed = { state: domain.initial(), seq: 0 }
  }

  /** Issues a typed intent. Offline: refused, nothing queues (U5). */
  issue(op: string, params: P, origin: Origin = "user", key?: string): string {
    if (!this.connected) throw new OwnerUnreachable()
    const idempotency_key = key ?? `${this.keyPrefix}:${++this.counter}`
    const intent: Intent<P> = { idempotency_key, op, params, origin }
    this.pending.push(intent)
    this.issuedAt.set(idempotency_key, this.clock())
    this.send({ t: "op", frame: { t: "op", op, params, idempotency_key, origin } })
    return idempotency_key
  }

  /** Timeout resend of one pending intent with the same key. */
  retry(key: string): void {
    this.expireStale()
    const intent = this.pending.find((i) => i.idempotency_key === key)
    if (intent && this.connected) this.send({ t: "op", frame: { t: "op", ...intent } })
  }

  view(): S {
    return this.visible().state
  }

  /**
   * Visible rows (row-backed domains): the mirror's loaded rows with the intents' writes on top.
   * The intent preview runs the reducer on the rows the mirror holds, so a row-mode domain must
   * keep every intent path on the head and the snapshot tail (send, react, edit a recent
   * message). An intent whose preview the reducer refuses for lack of rows stays in `pending`;
   * clients render such intents from their params (a pending bubble), never drop them.
   */
  viewRows(): OverlayRows {
    return this.visible().rows
  }

  private visible(): { state: S; rows: OverlayRows } {
    let s = this.confirmed.state
    const rows = new OverlayRows(this.rows)
    for (const i of this.pending) {
      const r = this.domain.reduce(s, i.op, i.params, {
        principal: this.principal,
        now: Date.now(),
        tx: i.idempotency_key,
        newId: (prefix) => `${prefix}_pending`,
        rows
      })
      if (r.ok) {
        s = r.state
        rows.apply(r.writes ?? [])
      }
    }
    return { state: s, rows }
  }

  receive(frame: OwnerFrame): void {
    if (!this.connected) return
    switch (frame.t) {
      case "event":
        return this.onEvent(frame)
      case "request-settled":
        return this.onSettled(frame)
      case "snapshot":
        return this.onSnapshot(frame as SnapshotFrame<S>)
      default:
        return // result and reject carry the value; the settle decides the log
    }
  }

  disconnect(): void {
    this.connected = false
    this.awaiting = false
    this.buffered = []
  }

  /** Reconnect: resend every pending intent with its key, then request a snapshot. */
  reconnect(): void {
    this.connected = true
    this.expireStale()
    if (!this.mutants.noResendOnReconnect) {
      for (const i of this.pending) this.send({ t: "op", frame: { t: "op", ...i } })
    }
    this.requestSnapshot()
  }

  /** Moves intents older than INTENT_TTL_MS from `pending` to `expired`. */
  expireStale(): void {
    const cutoff = this.clock() - INTENT_TTL_MS
    const keep: Array<Intent<P>> = []
    for (const i of this.pending) {
      const at = this.issuedAt.get(i.idempotency_key)
      if (at === undefined) this.issuedAt.set(i.idempotency_key, this.clock())
      else if (at < cutoff) {
        this.expired.push(i)
        this.issuedAt.delete(i.idempotency_key)
      } else keep.push(i)
    }
    this.pending = keep
  }

  private requestSnapshot(): void {
    this.awaiting = true
    // Expired keys are asked about (a query, never a resend) so a decided one leaves `expired`.
    this.send({ t: "snapshot.request", pending: [...this.pending, ...this.expired].map((i) => i.idempotency_key) })
  }

  private onEvent(e: EventFrame): void {
    if (this.awaiting) {
      this.buffered.push(e)
      return
    }
    if (this.mutants.dropAtNextDelta && this.pending.length > 0) this.pending.shift()
    if (e.seq === this.confirmed.seq + 1 || (this.mutants.noGapCheck && e.seq > this.confirmed.seq)) {
      this.applyEvent(e)
      if (!this.awaiting) this.flushHeld()
    } else if (e.seq > this.confirmed.seq + 1) {
      this.buffered.push(e)
      this.requestSnapshot()
    }
  }

  private applyEvent(e: EventFrame): void {
    // Row-mode owners send the effects: apply them (the mirror holds only some rows).
    if (e.effects) {
      this.rows.apply(e.effects.writes)
      this.confirmed = { state: e.effects.state as S, seq: e.seq }
      return
    }
    const r = this.domain.reduce(this.confirmed.state, e.op, e.params as P, {
      principal: e.actor,
      now: e.at,
      tx: e.tx,
      newId: idFactory(e.tx),
      rows: this.rows
    })
    // The owner committed this op with the same pure reducer, so it applies. If it does
    // not (version skew), resync from a snapshot instead of diverging.
    if (!r.ok) {
      this.desyncs++
      this.requestSnapshot()
      return
    }
    this.confirmed = { state: r.state, seq: e.seq }
  }

  private onSettled(s: SettledFrame): void {
    if (!s.ok || this.mutants.settleBeforeMirror || this.confirmed.seq >= s.sequence) this.settle(s)
    else this.held.push(s)
  }

  private settle(s: SettledFrame): void {
    this.pending = this.pending.filter((i) => i.idempotency_key !== s.idempotency_key)
    this.expired = this.expired.filter((i) => i.idempotency_key !== s.idempotency_key)
    this.issuedAt.delete(s.idempotency_key)
    if (s.ok) this.settledOk.add(s.idempotency_key)
  }

  private flushHeld(): void {
    const ready = this.held.filter((h) => this.confirmed.seq >= h.sequence)
    if (ready.length === 0) return
    this.held = this.held.filter((h) => this.confirmed.seq < h.sequence)
    for (const h of ready) this.settle(h)
  }

  private onSnapshot(snap: SnapshotFrame<S>): void {
    this.awaiting = false
    if (snap.seq >= this.confirmed.seq) {
      this.confirmed = { state: snap.state, seq: snap.seq }
      // Rows held from before may be stale; keep only what the snapshot sends.
      if (snap.rows) {
        this.rows.clear()
        this.rows.load(snap.rows.table, snap.rows.rows)
      }
      const decided = new Map(snap.decided.map((d) => [d.idempotency_key, d]))
      this.pending = this.pending.filter((i) => !decided.has(i.idempotency_key))
      this.expired = this.expired.filter((i) => !decided.has(i.idempotency_key))
      for (const k of decided.keys()) this.issuedAt.delete(k)
      for (const d of decided.values()) if (d.ok) this.settledOk.add(d.idempotency_key)
    }
    const later = this.buffered.sort((a, b) => a.seq - b.seq)
    this.buffered = []
    for (const e of later) this.onEvent(e)
    this.flushHeld()
  }
}
