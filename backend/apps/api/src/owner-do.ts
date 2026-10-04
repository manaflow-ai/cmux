import { DurableObject } from "cloudflare:workers"
import { EVENT_RETENTION_MS, LEDGER_RETENTION_MS, OwnerEngine, type Domain, type EngineOptions, type EventFrame, type OpFrame, type OutboxFailure, type OwnerFrame, type Principal, type Reject, type SqlStore } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { groupTargets, type DeliverResult, type TargetItem } from "./do-outbox.ts"
import { drainOutbox, isTransientError } from "./projection.ts"
import { refusalOnInitial } from "./owner-preflight.ts"
import { SnapshotBatcher } from "./snapshot-batcher.ts"

/** DO SQLite as the engine's synchronous store. Output gates hold every outgoing message until writes are durable. */
const doSql = (storage: DurableObjectStorage): SqlStore => ({
  exec: <T>(q: string, ...params: Array<unknown>) => storage.sql.exec(q, ...params).toArray() as Array<T>,
  transaction: <T>(fn: () => T): T => storage.transactionSync(fn)
})

export interface Attachment {
  readonly principal: Principal
  /** Subscribed to this object's primary stream. */
  subscribed: boolean
  /** Secondary streams this socket subscribed to (for example `inbox`). */
  streams?: Array<string>
}

/** Engine options a subclass may set: row mode and redaction (row-backed domains). */
export type OwnerEngineOptions = Pick<EngineOptions, "rowMode" | "redact" | "eventsNotReplayed">

export interface SubmitResult {
  readonly frames: ReadonlyArray<OwnerFrame>
}

export type ReadResult = { readonly ok: true; readonly value: unknown; readonly revision: string } | ({ readonly ok: false } & Reject)

/** Upper bound of the owner-wake retry backoff. */
const MAX_BACKOFF_MS = 5 * 60_000
/** How long hidden events coalesce before the filtered resync snapshot. */
const RESYNC_BATCH_MS = 250
/** How long a socket's install status from UserDO is trusted before its events wait for a new check. */
const INSTALL_CHECK_MS = 60_000

const closeQuietly = (ws: WebSocket, code: number, reason: string) => {
  try {
    ws.close(code, reason)
  } catch {}
}

/** Dead outbox items are replayed this long after they died (automatic replay tool). */
const DEAD_REPLAY_MS = 24 * 3600_000

/**
 * Transient (backoff forever) or poison (counts toward dead letter) for a failed outbox delivery.
 * PlanetScale errors are classified by SQLSTATE (isTransientError); a DO target only by the
 * runtime's own `retryable`/`overloaded` flags, never by message text (security review P2).
 */
const outboxFailure = (channel: string, e: unknown): OutboxFailure => {
  if (channel === "") return isTransientError(e) ? "transient" : "poison"
  const flags = e as { retryable?: unknown; overloaded?: unknown } | null
  if (flags?.retryable === true || flags?.overloaded === true) return "transient"
  if (e instanceof Error && e.message.startsWith("no binding for ")) return "transient"
  return "poison"
}

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
    private readonly eventActor?: (p: Principal) => Principal,
    private readonly engineOptions: OwnerEngineOptions = {}
  ) {
    super(ctx, env)
    this.store = doSql(ctx.storage)
    void ctx.blockConcurrencyWhile(async () => {
      // An object nobody created has no tables: the constructor only reads, so naming an id writes nothing.
      const row = this.boundEntity()
      if (row !== null) {
        this.store.exec(`CREATE TABLE IF NOT EXISTS do_wake (id INTEGER PRIMARY KEY CHECK (id = 1), attempts INTEGER NOT NULL)`)
        this.open(row)
      }
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
        ...(this.eventActor ? { eventActor: this.eventActor } : {}),
        ...this.engineOptions
      })
    return this.engine
  }

  /** The entity this object is bound to, or null for an object that was never created (no write). */
  protected boundEntity(): string | null {
    if (this.store.exec(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'do_entity'`).length === 0) return null
    return this.store.exec<{ entity: string }>(`SELECT entity FROM do_entity WHERE id = 1`)[0]?.entity ?? null
  }

  /** `{entity}` of a bound object, or undefined (the shape subclasses read before). Never writes. */
  protected boundRow(): { entity: string } | undefined {
    const e = this.boundEntity()
    return e === null ? undefined : { entity: e }
  }

  /** True when this object exists for `entity`; refuses any other entity. Never writes. */
  protected isBound(entity: string): boolean {
    const row = this.boundEntity()
    if (row !== null && row !== entity) throw new Error(`object bound to ${row}, not ${entity}`)
    return row !== null
  }

  /** Binds this object to its entity on first use (creates its storage); refuses any other entity. */
  protected bind(entity: string): OwnerEngine<S> {
    if (!this.isBound(entity)) {
      this.store.exec(`CREATE TABLE IF NOT EXISTS do_entity (id INTEGER PRIMARY KEY CHECK (id = 1), entity TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0)`)
      this.store.exec(`CREATE TABLE IF NOT EXISTS do_wake (id INTEGER PRIMARY KEY CHECK (id = 1), attempts INTEGER NOT NULL)`)
      this.store.exec(`INSERT INTO do_entity (id, entity) VALUES (1, ?)`, entity)
    }
    return this.open(entity)
  }

  /** Whether this owner asks UserDO about install revocation (UserDO closes its own sockets on revoke). */
  protected checksInstallRevocation = true
  /** Install status per `user\0install\0grant`, from UserDO, at most INSTALL_CHECK_MS old (memory only). */
  private readonly installChecks = new Map<string, { active: boolean; at: number }>()
  /** Sockets whose events are held until their install is checked again; they get a snapshot after. */
  private readonly heldForCheck = new Set<WebSocket>()
  private checking = false

  private installKey = (p: Principal) => `${p.user}\u0000${p.install}\u0000${p.grant ?? ""}`

  /**
   * Whether a socket may receive a frame now (P0, coordinator 2026-10-03). An expired token closes
   * the socket (4401 "token expired"). An install whose status is older than INSTALL_CHECK_MS is
   * held (no frame) while UserDO is asked; a revoked install closes (4401 "install revoked").
   */
  protected socketLive(ws: WebSocket, a: Attachment, now = Date.now()): boolean {
    if (a.principal.expires_at !== undefined && a.principal.expires_at <= now) {
      closeQuietly(ws, 4401, "token expired")
      return false
    }
    const p = a.principal
    if (this.checksInstallRevocation && p.kind === "install" && p.install && p.user) {
      const c = this.installChecks.get(this.installKey(p))
      if (c && !c.active) {
        closeQuietly(ws, 4401, "install revoked")
        return false
      }
      if (!c || now - c.at > INSTALL_CHECK_MS) {
        this.heldForCheck.add(ws)
        this.ctx.waitUntil(this.runInstallChecks())
        return false
      }
    }
    return !this.heldForCheck.has(ws)
  }

  /** Asks UserDO about every held socket's install, then closes revoked ones and resyncs the rest. */
  private async runInstallChecks(): Promise<void> {
    if (this.checking) return
    this.checking = true
    try {
      while (this.heldForCheck.size > 0) {
        const held = [...this.heldForCheck]
        const byUser = new Map<string, Map<string, { install: string; grant: string | undefined }>>()
        for (const ws of held) {
          const p = (ws.deserializeAttachment() as Attachment | null)?.principal
          if (!p?.user || !p.install) continue
          const m = byUser.get(p.user) ?? new Map()
          m.set(this.installKey(p), { install: p.install, grant: p.grant })
          byUser.set(p.user, m)
        }
        const now = Date.now()
        const results = await Promise.all([...byUser].map(async ([user, installs]) => ({ installs, status: await this.askUserDO(user, [...installs.values()]) })))
        // Unreachable UserDO: fail closed (the sockets stay held; the next frame asks again).
        if (results.some((r) => r.status === null)) return
        for (const { installs, status } of results) [...installs.keys()].forEach((k, i) => this.installChecks.set(k, { active: status![i] === true, at: now }))
        for (const ws of held) {
          this.heldForCheck.delete(ws)
          const a = ws.deserializeAttachment() as Attachment | null
          if (!a || !this.socketLive(ws, a)) continue
          if (a.subscribed && this.engine) safeSend(ws, this.snapshotFor(this.engine, a.principal, []))
        }
      }
    } finally {
      this.checking = false
    }
  }

  private askUserDO(user: string, list: ReadonlyArray<{ install: string; grant: string | undefined }>): Promise<ReadonlyArray<boolean> | null> {
    const stub = this.env.USER_DO.get(this.env.USER_DO.idFromName(user)) as unknown as { installsActive(entity: string, list: ReadonlyArray<{ install: string; grant: string | undefined }>): Promise<ReadonlyArray<boolean>> }
    return stub.installsActive(user, list).catch(() => null)
  }

  /**
   * Gate for frames a socket sends: an expired token closes the socket; an install whose cached
   * status is revoked closes it; a stale status is checked now (one UserDO RPC) before the frame is
   * routed. An unreachable UserDO refuses the frame (fail closed) and keeps the socket.
   */
  private async frameAllowed(ws: WebSocket, a: Attachment): Promise<boolean> {
    const p = a.principal
    if (p.expires_at !== undefined && p.expires_at <= Date.now()) {
      closeQuietly(ws, 4401, "token expired")
      return false
    }
    if (!this.checksInstallRevocation || p.kind !== "install" || !p.install || !p.user) return true
    const key = this.installKey(p)
    let c = this.installChecks.get(key)
    if (!c || Date.now() - c.at > INSTALL_CHECK_MS) {
      const status = await this.askUserDO(p.user, [{ install: p.install, grant: p.grant }])
      if (!status) {
        safeSend(ws, JSON.stringify({ t: "error", code: "owner.unreachable", message: "could not check this install; retry" }))
        return false
      }
      c = { active: status[0] === true, at: Date.now() }
      this.installChecks.set(key, c)
    }
    if (!c.active) {
      closeQuietly(ws, 4401, "install revoked")
      return false
    }
    return true
  }

  /** Test hook: forget cached install status (as if INSTALL_CHECK_MS passed). */
  forgetInstallChecks(): void {
    this.installChecks.clear()
  }

  /** Closes sockets whose token expired (alarm sweep: also with no events). */
  private sweepExpiredSockets(now: number): void {
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment() as Attachment | null
      if (a?.principal.expires_at !== undefined && a.principal.expires_at <= now) closeQuietly(ws, 4401, "token expired")
    }
  }

  /** The earliest token expiry of an open socket, or null. */
  private nextSocketExpiry(): number | null {
    let at: number | null = null
    for (const ws of this.ctx.getWebSockets()) {
      const e = (ws.deserializeAttachment() as Attachment | null)?.principal.expires_at
      // A past expiry belongs to a socket the sweep already closed (it may still be listed while closing).
      if (typeof e === "number" && e > Date.now() && (at === null || e < at)) at = e
    }
    return at
  }

  private broadcast(frame: OwnerFrame) {
    const extras = frame.t === "event" ? this.eventExtras(frame) : undefined
    const text = JSON.stringify(extras ? { ...frame, ...extras } : frame)
    const state = this.engine?.currentState
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment() as Attachment | null
      if (!a?.subscribed) continue
      if (!this.socketLive(ws, a)) continue
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
      if (text && a?.subscribed && this.socketLive(ws, a)) safeSend(ws, text)
    }
  })

  /** What a subscriber may see of the state in snapshots (default: all of it). */
  protected subscriberView(state: S, _principal: Principal): unknown {
    return state
  }

  /**
   * Extra fields on a live event frame, computed after the commit (for example
   * FeedDO's changed items, so clients mirror owner-written records instead of
   * replaying the reducer). Resumed events from the log do not carry them.
   */
  protected eventExtras(_event: EventFrame): Record<string, unknown> | undefined {
    return undefined
  }

  /** Whether a subscriber receives a committed event (default: yes). */
  protected mayReceive(_state: S, _event: EventFrame, _principal: Principal): boolean {
    return true
  }

  /**
   * What a subscriber may see of a snapshot: the state through `subscriberView`, and (row
   * mode) the tail rows. Override to filter the tail rows as well.
   */
  protected subscriberSnapshot(snap: ReturnType<OwnerEngine<S>["snapshot"]>, principal: Principal): unknown {
    return { ...snap, state: this.subscriberView(snap.state as S, principal) }
  }

  private snapshotFor(engine: OwnerEngine<S>, principal: Principal, pending: ReadonlyArray<string>): string {
    return JSON.stringify(this.subscriberSnapshot(engine.snapshot(principal.identity, pending), principal))
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

  /**
   * Runs before the base handles a frame: a subclass with secondary streams takes frames that
   * name another stream (`stream: "inbox:<user>"`) or an op that stream owns. Return true when
   * handled.
   */
  protected routeFrame(_ws: WebSocket, _attachment: Attachment, _frame: { readonly t?: string; readonly stream?: unknown; readonly op?: unknown } & Record<string, unknown>): boolean {
    return false
  }

  /**
   * Which engine commits a system op delivered by another owner's outbox (E4). Default: the
   * primary engine. A subclass with secondary streams routes their ops (for example
   * `inbox.bump`) to them; `publish` sends the committed events to that stream's subscribers.
   */
  protected systemEngine(_op: string, entity: string): { engine: OwnerEngine<unknown>; publish: (frame: OwnerFrame) => void } {
    return { engine: this.bind(entity) as OwnerEngine<unknown>, publish: (f) => this.broadcast(f) }
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
    const events = this.engine.nextEventPruneAt()
    const eventPrune = events === null ? null : events + PRUNE_SLACK_MS
    // Dead outbox items come back once a day by themselves (a fix deployed since then drains them).
    const dead = this.engine.outbox.oldestDeadAt()
    const replay = dead === null ? null : dead + DEAD_REPLAY_MS
    const sockets = this.nextSocketExpiry()
    const times = [wake, prune, eventPrune, replay, sockets].filter((t): t is number => t !== null)
    return times.length ? Math.min(...times) : null
  }

  /**
   * Binding of another owner class for DO-to-DO delivery. Convention: class `FooBarDO`
   * is bound as `FOO_BAR_DO`.
   */
  protected targetNamespace(className: string): DurableObjectNamespace | undefined {
    const binding = `${className.replace(/DO$/, "").replace(/([a-z0-9])([A-Z])/g, "$1_$2").toUpperCase()}_DO`
    return (this.env as unknown as Record<string, DurableObjectNamespace | undefined>)[binding]
  }

  /**
   * RPC from another owner's outbox drain (E4). Each item is committed as a system op with its
   * own idempotency key, so a redelivery replays from the ledger. Returns the ids decided
   * (applied, replayed or refused for good); a throw stops the batch and the rest is retried.
   */
  async systemDeliver(entity: string, source: string, items: ReadonlyArray<TargetItem>): Promise<DeliverResult> {
    this.bind(entity)
    const principal: Principal = { identity: `system:${source}`, kind: "system" }
    const done: Array<number> = []
    for (const item of items) {
      const frames: Array<OwnerFrame> = []
      const { engine, publish } = this.systemEngine(item.op, entity)
      engine.submit(principal, { t: "op", op: item.op, params: item.params, idempotency_key: item.key, origin: "script" }, (target, f) =>
        target === "all" ? publish(f) : frames.push(f)
      )
      const reject = frames.find((f) => f.t === "reject")
      if (reject && reject.t === "reject") console.warn(JSON.stringify({ msg: "system op refused", target: engine.stream, source, op: item.op, code: reject.code }))
      this.afterOp(principal, item.op, frames)
      done.push(item.id)
    }
    this.afterCommit()
    return { done }
  }

  /** Runs in the alarm after the outbox drain. A throw is logged and the alarm is rescheduled. */
  protected async onWake(_now: number): Promise<void> {}

  /** The object's SQLite store, for subclasses that host secondary streams or side tables. */
  protected get sqlStore(): SqlStore {
    return this.store
  }

  /** Moves the alarm earlier when a subclass committed outside the base paths (secondary streams). */
  protected scheduleAlarm(): void {
    this.afterCommit()
  }

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
  protected submitSystem(op: string, params: unknown, idempotencyKey: string, identity = `system:${this.streamPrefix}`): SubmitResult {
    if (!this.engine) throw new Error("submitSystem before the object is bound")
    const principal: Principal = { identity, kind: "system" }
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
    // Per channel: a backed-off channel waits, a healthy one drains now (outbox.ts).
    const outboxAt = this.engine.outbox.nextDueAt(now)
    const wake = this.wakeAt(now)
    const want = outboxAt === null ? wake : wake === null ? outboxAt : Math.min(outboxAt, wake)
    if (want === null) return
    void this.ctx.storage.getAlarm().then((t) => (t === null || t > want ? this.ctx.storage.setAlarm(want) : undefined))
  }

  /**
   * One op from an authenticated principal. Requester frames return; events fan out to subscribers.
   * An op on an object that does not exist yet is decided on the initial state first, and storage
   * is created only when it would commit (home-scale review: no empty objects from refused ops).
   * Such a refusal has no ledger entry: a retry with the same key is decided again.
   */
  async submit(entity: string, principal: Principal, frame: OpFrame): Promise<SubmitResult> {
    if (!this.isBound(entity)) {
      const refused = refusalOnInitial(this.domain, `${this.streamPrefix}:${entity}`, principal, frame)
      if (refused) return { frames: refused }
    }
    const engine = this.bind(entity)
    const frames: Array<OwnerFrame> = []
    engine.submit(principal, frame, (target, f) => (target === "all" ? this.broadcast(f) : frames.push(f)))
    this.afterCommit()
    this.afterOp(principal, frame.op, frames)
    return { frames }
  }

  async readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<ReadResult> {
    if (!this.isBound(entity)) {
      const r = this.read(this.domain.initial(), op, params, principal)
      return r.ok ? { ...r, revision: "0" } : r
    }
    const engine = this.bind(entity)
    const r = this.read(engine.currentState, op, params, principal)
    return r.ok ? { ...r, revision: String(engine.currentSeq) } : r
  }

  /** Operator replay tool (admin-outbox.ts): dead outbox items go back to the queue. */
  async replayDeadLetters(entity: string, ids?: ReadonlyArray<number>): Promise<{ replayed: number; dead: number }> {
    // Never creates an object: an unknown name has nothing to replay.
    if (!this.isBound(entity)) return { replayed: 0, dead: 0 }
    const engine = this.bind(entity)
    const replayed = engine.outbox.replayDead(Date.now(), ids ? { ids } : {})
    this.afterCommit()
    return { replayed, dead: engine.outbox.deadCount() }
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
    if (!this.isBound(entity) && !this.maySubscribe(this.domain.initial(), principal)) return new Response("forbidden", { status: 403 })
    const engine = this.bind(entity)
    if (!this.maySubscribe(engine.currentState, principal)) return new Response("forbidden", { status: 403 })
    const pair = new WebSocketPair()
    const [client, server] = [pair[0], pair[1]]
    this.ctx.acceptWebSocket(server)
    server.serializeAttachment({ principal, subscribed: false } satisfies Attachment)
    // The Worker checked the install just now; the alarm closes the socket at its token's expiry.
    if (principal.kind === "install" && principal.install && principal.user) this.installChecks.set(this.installKey(principal), { active: true, at: Date.now() })
    this.afterCommit()
    safeSend(server, JSON.stringify({ t: "welcome", principal: { user: principal.user, team: principal.team, install: principal.install }, server_time: Date.now(), streams: [engine.stream] }))
    return new Response(null, { status: 101, webSocket: client, headers: { "Sec-WebSocket-Protocol": "cmux.wire.v1" } })
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer) {
    const a = ws.deserializeAttachment() as Attachment
    // A socket lives no longer than its token, and a revoked install's frames are never routed.
    if (!(await this.frameAllowed(ws, a))) return
    const row = this.boundEntity()
    if (row === null) return ws.close(1011, "unbound")
    const engine = this.open(row)
    let frame: { t?: string; after_seq?: number; pending?: Array<string> } & Partial<Omit<OpFrame, "t">>
    try {
      frame = JSON.parse(typeof message === "string" ? message : new TextDecoder().decode(message))
    } catch {
      return safeSend(ws, JSON.stringify({ t: "error", code: "validation.invalid", message: "frames are JSON" }))
    }
    if (this.routeFrame(ws, a, frame as { t?: string } & Record<string, unknown>)) return
    switch (frame.t) {
      case "subscribe": {
        a.subscribed = true
        ws.serializeAttachment(a)
        const after = typeof frame.after_seq === "number" ? frame.after_seq : undefined
        const pending = frame.pending ?? []
        // Resume by replaying the gap when the client holds no unconfirmed intents and the gap is
        // small; otherwise a snapshot, which carries the decided keys that settle those intents.
        const gap = after !== undefined && after <= engine.currentSeq && engine.currentSeq - after <= 1000 && pending.length === 0 && engine.canReplayFrom(after)
        if (gap) {
          // A hidden event in the gap means a filtered snapshot instead (no stale mirror at the tail).
          const events = engine.eventsAfter(after)
          if (events.every((e) => this.mayReceive(engine.currentState, e, a.principal))) for (const e of events) safeSend(ws, JSON.stringify(e))
          else safeSend(ws, this.snapshotFor(engine, a.principal, pending))
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
    this.heldForCheck.delete(ws)
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
    this.sweepExpiredSockets(Date.now())
    if (!this.engine) return
    const outbox = this.engine.outbox
    // Each channel (PlanetScale projections, or one target object) reads, fails and backs off on
    // its own, so a dead target cannot stop projections or healthy targets.
    for (const channel of outbox.dueChannels(Date.now())) {
      // After a failure a target channel sends its head alone, so a poison item is found by itself.
      const rows = outbox.pending(channel, channel !== "" && outbox.isolating(channel) ? 1 : 100)
      if (rows.length === 0) continue
      try {
        if (channel === "") {
          const res = await drainOutbox(this.env, this.engine.stream, rows)
          outbox.markSent(res.sent, Date.now())
          // Only the bad row leaves the queue; the rest of the batch committed (home-scale review P1).
          for (const d of res.dead) {
            outbox.deadLetter(d.id, Date.now())
            console.error(JSON.stringify({ msg: "outbox row dead-lettered", stream: this.engine.stream, channel: "planetscale", dead_letter: d.id, error: d.error }))
          }
        } else {
          const batch = groupTargets(rows)[0]!
          outbox.markSent(batch.superseded, Date.now())
          const ns = this.targetNamespace(batch.class)
          if (!ns) throw new Error(`no binding for ${batch.class}`)
          const stub = ns.get(ns.idFromName(batch.name)) as unknown as { systemDeliver(entity: string, source: string, items: ReadonlyArray<TargetItem>): Promise<DeliverResult> }
          const res = await stub.systemDeliver(batch.name, this.engine.stream, batch.items)
          outbox.markSent(res.done, Date.now())
          if (res.done.length < batch.items.length) throw new Error(`${batch.items.length - res.done.length} items not delivered`)
        }
        outbox.succeeded(channel)
      } catch (e) {
        const dead = outbox.failed(channel, Date.now(), outboxFailure(channel, e))
        console.error(JSON.stringify({ msg: "outbox delivery failed", stream: this.engine.stream, channel: channel || "planetscale", error: String(e), ...(dead === null ? {} : { dead_letter: dead }) }))
      }
    }
    const replayed = outbox.replayDead(Date.now(), { deadBefore: Date.now() - DEAD_REPLAY_MS })
    if (replayed > 0) console.warn(JSON.stringify({ msg: "outbox dead letters replayed", stream: this.engine.stream, count: replayed }))
    this.engine.pruneEvents(Date.now() - EVENT_RETENTION_MS)
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
    // Includes rows committed during the wake (their afterCommit saw the running alarm).
    const outboxAt = this.engine.outbox.nextDueAt(Date.now())
    const due = this.wakeAt(Date.now())
    const wake = wakeRetryAt !== null && due !== null ? Math.max(due, wakeRetryAt) : due
    const at = outboxAt === null ? wake : wake === null ? outboxAt : Math.min(outboxAt, wake)
    if (at !== null) await this.ctx.storage.setAlarm(at)
  }
}
