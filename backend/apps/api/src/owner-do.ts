import { DurableObject } from "cloudflare:workers"
import { LEDGER_RETENTION_MS, OwnerEngine, type Domain, type EventFrame, type OpFrame, type OwnerFrame, type Principal, type Reject, type SqlStore } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { drainOutbox } from "./projection.ts"
import { SnapshotBatcher } from "./snapshot-batcher.ts"

/** DO SQLite as the engine's synchronous store. Output gates hold every outgoing message until writes are durable. */
const doSql = (storage: DurableObjectStorage): SqlStore => ({
  exec: <T>(q: string, ...params: Array<unknown>) => storage.sql.exec(q, ...params).toArray() as Array<T>,
  transaction: <T>(fn: () => T): T => storage.transactionSync(fn)
})

interface Attachment {
  readonly principal: Principal
  subscribed: boolean
}

export interface SubmitResult {
  readonly frames: ReadonlyArray<OwnerFrame>
}

export type ReadResult = { readonly ok: true; readonly value: unknown; readonly revision: string } | ({ readonly ok: false } & Reject)

const MAX_BACKOFF_MS = 5 * 60_000
/** How long hidden events coalesce before the filtered resync snapshot. */
const RESYNC_BATCH_MS = 250
const PRUNE_SLACK_MS = 60 * 60_000

/** A closing socket must not stop delivery to the others (events are committed already). */
const safeSend = (ws: WebSocket, text: string) => {
  try {
    ws.send(text)
  } catch {}
}

/**
 * The shared base of every cloud owner (spec 00-overview 7.1): one entity per
 * object, ops through OwnerEngine (ledger, pure reducer, one transaction for
 * state + ledger + events + outbox, commit before publish, request-settled),
 * hibernating WebSocket subscribers, outbox drained to PlanetScale by alarm.
 * The principal always comes from the Worker, never from a frame.
 */
export abstract class OwnerDO<S> extends DurableObject<Env> {
  private engine: OwnerEngine<S> | undefined
  private readonly store: SqlStore

  constructor(
    ctx: DurableObjectState,
    env: Env,
    private readonly domain: Domain<S>,
    private readonly streamPrefix: string,
    private readonly eventActor?: (p: Principal) => Principal
  ) {
    super(ctx, env)
    this.store = doSql(ctx.storage)
    void ctx.blockConcurrencyWhile(async () => {
      this.store.exec(`CREATE TABLE IF NOT EXISTS do_entity (id INTEGER PRIMARY KEY CHECK (id = 1), entity TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0)`)
      this.store.exec(`CREATE TABLE IF NOT EXISTS do_wake (id INTEGER PRIMARY KEY CHECK (id = 1), attempts INTEGER NOT NULL)`)
      const row = this.store.exec<{ entity: string }>(`SELECT entity FROM do_entity WHERE id = 1`)[0]
      if (row) this.open(row.entity)
    })
  }

  /** Per-stream read projection for a principal. */
  protected abstract read(state: S, op: string, params: unknown, principal: Principal): ReadResult
  /** Who may subscribe to this stream. */
  protected abstract maySubscribe(state: S, principal: Principal): boolean

  private open(entity: string): OwnerEngine<S> {
    if (!this.engine)
      this.engine = new OwnerEngine(this.store, this.domain, {
        stream: `${this.streamPrefix}:${entity}`,
        ...(this.eventActor ? { eventActor: this.eventActor } : {})
      })
    return this.engine
  }

  /** Binds this object to its entity on first use; refuses any other entity. */
  protected bind(entity: string): OwnerEngine<S> {
    const row = this.store.exec<{ entity: string }>(`SELECT entity FROM do_entity WHERE id = 1`)[0]
    if (!row) this.store.exec(`INSERT INTO do_entity (id, entity) VALUES (1, ?)`, entity)
    else if (row.entity !== entity) throw new Error(`object bound to ${row.entity}, not ${entity}`)
    return this.open(entity)
  }

  private broadcast(frame: OwnerFrame) {
    const text = JSON.stringify(frame)
    const state = this.engine?.currentState
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment() as Attachment | null
      if (!a?.subscribed) continue
      // A hidden event would leave the subscriber's mirror stale until its next
      // visible event (clients repair only on a seq gap): send it a filtered snapshot instead.
      if (frame.t === "event" && state !== undefined && this.engine && !this.mayReceive(state, frame, a.principal)) {
        this.resyncs.mark(ws, a.principal.identity)
        continue
      }
      // A visible event after hidden ones: send the pending snapshot first (no seq gap round trip).
      if (this.resyncs.has(ws)) this.resyncs.flushOne(ws)
      safeSend(ws, text)
    }
  }

  /**
   * Hidden events become one filtered snapshot per socket per batch, sent
   * after a short one-shot delay (not a poll), with one view per identity.
   */
  private readonly resyncs = new SnapshotBatcher<WebSocket>({
    schedule: (flush) => void setTimeout(flush, RESYNC_BATCH_MS),
    viewFor: (_identity, ws) => {
      const principal = (ws.deserializeAttachment() as Attachment | null)?.principal
      return this.engine && principal ? this.snapshotFor(this.engine, principal, []) : ""
    },
    send: (ws, text) => {
      const a = ws.deserializeAttachment() as Attachment | null
      if (text && a?.subscribed) safeSend(ws, text)
    }
  })

  /** What a subscriber may see of the state in snapshots (default: all of it). */
  protected subscriberView(state: S, _principal: Principal): unknown {
    return state
  }

  /** Whether a subscriber receives a committed event (default: yes). */
  protected mayReceive(_state: S, _event: EventFrame, _principal: Principal): boolean {
    return true
  }

  private snapshotFor(engine: OwnerEngine<S>, principal: Principal, pending: ReadonlyArray<string>): string {
    const snap = engine.snapshot(principal.identity, pending)
    return JSON.stringify({ ...snap, state: this.subscriberView(snap.state as S, principal) })
  }


  /** Closes every socket whose principal matches (revocation). */
  protected closeSockets(match: (p: Principal) => boolean, reason: string) {
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment() as Attachment | null
      if (a && match(a.principal)) {
        try {
          ws.close(4401, reason)
        } catch {}
      }
    }
  }

  /** Hook after each committed op (for example: close a revoked install's sockets). */
  protected afterOp(_principal: Principal, _op: string, _frames: ReadonlyArray<OwnerFrame>) {}

  /**
   * When this owner next needs its alarm for its own work (for example the next
   * cron fire), from committed state only; null for never. The one DO alarm is
   * shared with the outbox drain: it fires at the earlier of the two.
   */
  protected nextWakeAt(_state: S, _now: number): number | null {
    return null
  }

  /**
   * A frame type the base does not know (for example FeedDO's `presence.set`).
   * Return true when handled. Never commits state: ops go through `op` frames.
   */
  protected onFrame(_ws: WebSocket, _frame: { readonly t?: string } & Record<string, unknown>): boolean {
    return false
  }

  /** Subclasses prune their own side tables older than `before` (same replay window). */
  protected onPrune(_before: number): void {}

  /** The owner's wake and the ledger's next prune (oldest key + retention), whichever is first. */
  private wakeAt(now: number): number | null {
    if (!this.engine) return null
    const wake = this.nextWakeAt(this.engine.currentState, now)
    const oldest = this.engine.oldestLedgerAt()
    // One hour of slack so one wake prunes a batch instead of one wake per expiring key.
    const prune = oldest === null ? null : oldest + LEDGER_RETENTION_MS + PRUNE_SLACK_MS
    return wake === null ? prune : prune === null ? wake : Math.min(wake, prune)
  }

  /** Runs in the alarm after the outbox drain. A throw is logged and the alarm is rescheduled. */
  protected async onWake(_now: number): Promise<void> {}

  /** The bound entity's engine, for subclasses that read state outside an op. */
  protected get boundEngine(): OwnerEngine<S> | undefined {
    return this.engine
  }

  /**
   * Commits this owner's own op (alarm fires, Workflow reports) through the same
   * engine: same ledger, commit before publish, events to subscribers. The
   * principal is built here and nowhere else; the key must be deterministic so a
   * repeated alarm replays instead of applying twice.
   */
  protected submitSystem(op: string, params: unknown, idempotencyKey: string): SubmitResult {
    if (!this.engine) throw new Error("submitSystem before the object is bound")
    const principal: Principal = { identity: `system:${this.streamPrefix}`, kind: "system" }
    const frames: Array<OwnerFrame> = []
    this.engine.submit(principal, { t: "op", op, params, idempotency_key: idempotencyKey, origin: "script" }, (target, f) =>
      target === "all" ? this.broadcast(f) : frames.push(f)
    )
    this.afterCommit()
    this.afterOp(principal, op, frames)
    return { frames }
  }

  /**
   * Moves the alarm earlier when needed: to now for a pending outbox (unless a
   * failed drain is backing off; its retry alarm stays), or to the owner's next
   * wake. Never moves it later: the alarm handler computes the next time itself.
   */
  private afterCommit() {
    if (!this.engine) return
    const now = Date.now()
    const backingOff = (this.store.exec<{ attempts: number }>(`SELECT attempts FROM do_entity WHERE id = 1`)[0]?.attempts ?? 0) > 0
    const outboxAt = !backingOff && this.engine.outboxPending(1).length > 0 ? now : null
    const wake = this.wakeAt(now)
    const want = outboxAt === null ? wake : wake === null ? outboxAt : Math.min(outboxAt, wake)
    if (want === null) return
    void this.ctx.storage.getAlarm().then((t) => (t === null || t > want ? this.ctx.storage.setAlarm(want) : undefined))
  }

  /** RPC: one op from an authenticated principal. Requester frames return; events fan out to subscribers. */
  async submit(entity: string, principal: Principal, frame: OpFrame): Promise<SubmitResult> {
    const engine = this.bind(entity)
    const frames: Array<OwnerFrame> = []
    engine.submit(principal, frame, (target, f) => (target === "all" ? this.broadcast(f) : frames.push(f)))
    this.afterCommit()
    this.afterOp(principal, frame.op, frames)
    return { frames }
  }

  async readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<ReadResult> {
    const engine = this.bind(entity)
    const r = this.read(engine.currentState, op, params, principal)
    return r.ok ? { ...r, revision: String(engine.currentSeq) } : r
  }

  async debug(entity: string) {
    return this.bind(entity).debugDump()
  }

  /** WebSocket gateway (cmux.wire/1 subset). The Worker sets the principal headers after authentication. */
  override async fetch(request: Request): Promise<Response> {
    const entity = request.headers.get("x-cmux-entity")
    const principalJson = request.headers.get("x-cmux-principal")
    if (!entity || !principalJson || request.headers.get("Upgrade") !== "websocket") return new Response("bad request", { status: 400 })
    const principal = JSON.parse(principalJson) as Principal
    const engine = this.bind(entity)
    if (!this.maySubscribe(engine.currentState, principal)) return new Response("forbidden", { status: 403 })
    const pair = new WebSocketPair()
    const [client, server] = [pair[0], pair[1]]
    this.ctx.acceptWebSocket(server)
    server.serializeAttachment({ principal, subscribed: false } satisfies Attachment)
    safeSend(server, JSON.stringify({ t: "welcome", principal: { user: principal.user, team: principal.team, install: principal.install }, server_time: Date.now(), streams: [engine.stream] }))
    return new Response(null, { status: 101, webSocket: client, headers: { "Sec-WebSocket-Protocol": "cmux.wire.v1" } })
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer) {
    const a = ws.deserializeAttachment() as Attachment
    // A socket lives no longer than its token.
    if (a.principal.expires_at !== undefined && a.principal.expires_at <= Date.now()) return ws.close(4401, "token expired")
    const row = this.store.exec<{ entity: string }>(`SELECT entity FROM do_entity WHERE id = 1`)[0]
    if (!row) return ws.close(1011, "unbound")
    const engine = this.open(row.entity)
    let frame: { t?: string; after_seq?: number; pending?: Array<string> } & Partial<Omit<OpFrame, "t">>
    try {
      frame = JSON.parse(typeof message === "string" ? message : new TextDecoder().decode(message))
    } catch {
      return safeSend(ws, JSON.stringify({ t: "error", code: "validation.invalid", message: "frames are JSON" }))
    }
    switch (frame.t) {
      case "subscribe": {
        a.subscribed = true
        ws.serializeAttachment(a)
        const after = typeof frame.after_seq === "number" ? frame.after_seq : undefined
        const pending = frame.pending ?? []
        // Resume by replaying the gap when the client holds no unconfirmed intents and the gap is
        // small; otherwise a snapshot, which carries the decided keys that settle those intents.
        const gap = after !== undefined && after <= engine.currentSeq && engine.currentSeq - after <= 1000 && pending.length === 0
        if (gap) {
          for (const e of engine.eventsAfter(after)) if (this.mayReceive(engine.currentState, e, a.principal)) safeSend(ws, JSON.stringify(e))
        } else safeSend(ws, this.snapshotFor(engine, a.principal, pending))
        return
      }
      case "snapshot.request":
        safeSend(ws, this.snapshotFor(engine, a.principal, frame.pending ?? []))
        return
      case "unsubscribe":
        a.subscribed = false
        ws.serializeAttachment(a)
        return
      case "op": {
        const frames: Array<OwnerFrame> = []
        engine.submit(a.principal, frame as OpFrame, (target, f) => (target === "all" ? this.broadcast(f) : (frames.push(f), safeSend(ws, JSON.stringify(f)))))
        this.afterCommit()
        this.afterOp(a.principal, (frame as OpFrame).op, frames)
        return
      }
      default:
        if (this.onFrame(ws, frame as { t?: string } & Record<string, unknown>)) return
        safeSend(ws, JSON.stringify({ t: "error", code: "validation.invalid", message: `unknown frame ${frame.t}` }))
    }
  }

  override async webSocketClose(ws: WebSocket, code: number) {
    // 1005/1006 are reserved: they report "no code" and "abnormal" and cannot be sent.
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code, "closing")
    } catch {}
  }

  /**
   * Drains the outbox into PlanetScale with idempotent upserts keyed by
   * (stream, seq), then runs the owner's own wake work, then sets the alarm to
   * the earlier of the drain retry and the owner's next wake.
   */
  override async alarm() {
    if (!this.engine) return
    let outboxAt: number | null = null
    const rows = this.engine.outboxPending(100)
    if (rows.length > 0) {
      try {
        await drainOutbox(this.env, this.engine.stream, rows)
        this.engine.outboxMarkSent(rows.map((r) => r.id))
        this.store.exec(`UPDATE do_entity SET attempts = 0 WHERE id = 1`)
        if (this.engine.outboxPending(1).length > 0) outboxAt = Date.now()
      } catch (e) {
        const attempts = (this.store.exec<{ attempts: number }>(`SELECT attempts FROM do_entity WHERE id = 1`)[0]?.attempts ?? 0) + 1
        this.store.exec(`UPDATE do_entity SET attempts = ? WHERE id = 1`, attempts)
        console.error(JSON.stringify({ msg: "outbox drain failed", stream: this.engine.stream, attempts, error: String(e) }))
        outboxAt = Date.now() + Math.min(MAX_BACKOFF_MS, 1000 * 2 ** attempts)
      }
    }
    // Bounded prune; if more remain, the oldest is still past the window and the alarm comes back at once.
    this.engine.pruneLedger(Date.now() - LEDGER_RETENTION_MS)
    this.onPrune(Date.now() - LEDGER_RETENTION_MS)
    // A failing wake backs off like the drain; otherwise its past-due work would refire the alarm at once, forever.
    let wakeRetryAt: number | null = null
    try {
      await this.onWake(Date.now())
      this.store.exec(`DELETE FROM do_wake`)
    } catch (e) {
      const attempts = (this.store.exec<{ attempts: number }>(`SELECT attempts FROM do_wake WHERE id = 1`)[0]?.attempts ?? 0) + 1
      this.store.exec(`INSERT INTO do_wake (id, attempts) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET attempts = excluded.attempts`, attempts)
      wakeRetryAt = Date.now() + Math.min(MAX_BACKOFF_MS, 1000 * 2 ** attempts)
      console.error(JSON.stringify({ msg: "owner wake failed", stream: this.engine.stream, attempts, error: String(e) }))
    }
    // Ops committed during the wake may have added outbox rows (their afterCommit saw the running alarm).
    if (outboxAt === null && this.engine.outboxPending(1).length > 0) outboxAt = Date.now()
    const due = this.wakeAt(Date.now())
    const wake = wakeRetryAt !== null && due !== null ? Math.max(due, wakeRetryAt) : due
    const at = outboxAt === null ? wake : wake === null ? outboxAt : Math.min(outboxAt, wake)
    if (at !== null) await this.ctx.storage.setAlarm(at)
  }
}
