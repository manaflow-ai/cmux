import { EVENT_RETENTION_MS, LEDGER_RETENTION_MS, OwnerEngine, type Domain, type OpFrame, type OwnerFrame, type Principal, type SqlStore } from "@cmux/ownership"
import type { Attachment, OwnerEngineOptions } from "./owner-do.ts"

/**
 * A second stream inside one Durable Object (lane 15 need E2): its own engine (table prefix,
 * sequence, ledger, events, outbox), its own subscribers on the object's sockets, the same
 * frames as the primary stream. UserDO hosts `inbox:<user>` this way next to `user:<user>`.
 */
export interface SecondarySpec<S> {
  /** Stream prefix, for example `inbox` (stream `inbox:<entity>`). */
  readonly prefix: string
  /** SQL table prefix, for example `inbox_`. */
  readonly tablePrefix: string
  readonly domain: Domain<S>
  readonly engine?: OwnerEngineOptions
  /** Ops this stream owns (routed here from `op` frames and system deliveries). */
  readonly owns: (op: string) => boolean
  readonly maySubscribe: (state: S, principal: Principal, entity: string) => boolean
}

const send = (ws: WebSocket, frame: unknown) => {
  try {
    ws.send(typeof frame === "string" ? frame : JSON.stringify(frame))
  } catch {}
}

export class SecondaryStream<S> {
  private engine: OwnerEngine<S> | undefined

  constructor(
    private readonly ctx: DurableObjectState,
    private readonly store: SqlStore,
    readonly spec: SecondarySpec<S>
  ) {}

  open(entity: string): OwnerEngine<S> {
    this.engine ??= new OwnerEngine(this.store, this.spec.domain, { stream: `${this.spec.prefix}:${entity}`, prefix: this.spec.tablePrefix, ...this.spec.engine })
    return this.engine
  }

  get bound(): OwnerEngine<S> | undefined {
    return this.engine
  }

  /** True for frames that belong to this stream. */
  handles(frame: { readonly t?: string; readonly stream?: unknown; readonly op?: unknown }): boolean {
    if (typeof frame.stream === "string") return frame.stream.startsWith(`${this.spec.prefix}:`)
    return frame.t === "op" && typeof frame.op === "string" && this.spec.owns(frame.op)
  }

  publish(frame: OwnerFrame): void {
    const text = JSON.stringify(frame)
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment() as Attachment | null
      if (a?.streams?.includes(this.spec.prefix)) send(ws, text)
    }
  }

  submit(principal: Principal, frame: OpFrame, reply: (f: OwnerFrame) => void): void {
    this.engine!.submit(principal, frame, (target, f) => (target === "all" ? this.publish(f) : reply(f)))
  }

  /** Handles one socket frame of this stream. The caller checked `handles`. */
  onFrame(ws: WebSocket, a: Attachment, entity: string, frame: { readonly t?: string; readonly after_seq?: unknown; readonly pending?: unknown } & Record<string, unknown>): void {
    const engine = this.open(entity)
    const pending = Array.isArray(frame.pending) ? (frame.pending as Array<string>).filter((k) => typeof k === "string") : []
    switch (frame.t) {
      case "subscribe": {
        if (!this.spec.maySubscribe(engine.currentState, a.principal, entity)) return send(ws, { t: "error", code: "auth.forbidden", message: `not allowed on ${engine.stream}` })
        a.streams = [...new Set([...(a.streams ?? []), this.spec.prefix])]
        ws.serializeAttachment(a)
        const after = typeof frame.after_seq === "number" ? frame.after_seq : undefined
        const replay = after !== undefined && after <= engine.currentSeq && engine.currentSeq - after <= 1000 && pending.length === 0 && engine.canReplayFrom(after)
        if (replay) for (const e of engine.eventsAfter(after)) send(ws, e)
        else send(ws, engine.snapshot(a.principal.identity, pending))
        return
      }
      case "snapshot.request":
        if (!a.streams?.includes(this.spec.prefix)) return send(ws, { t: "error", code: "validation.invalid", message: "subscribe first" })
        return send(ws, engine.snapshot(a.principal.identity, pending))
      case "unsubscribe":
        a.streams = (a.streams ?? []).filter((p) => p !== this.spec.prefix)
        ws.serializeAttachment(a)
        return
      case "op":
        return this.submit(a.principal, frame as unknown as OpFrame, (f) => send(ws, f))
      default:
        return send(ws, { t: "error", code: "validation.invalid", message: `unknown frame ${frame.t}` })
    }
  }

  /** Ledger and event retention, like the primary stream (called from the owner's alarm). */
  prune(now: number): void {
    if (!this.engine) return
    this.engine.pruneLedger(now - LEDGER_RETENTION_MS)
    this.engine.pruneEvents(now - EVENT_RETENTION_MS)
  }

  /** When this stream next needs the alarm (pruning), or null. */
  nextWakeAt(): number | null {
    if (!this.engine) return null
    const oldest = this.engine.oldestLedgerAt()
    const times = [oldest === null ? null : oldest + LEDGER_RETENTION_MS + 3600_000, this.engine.nextEventPruneAt()].filter((t): t is number => t !== null)
    return times.length ? Math.min(...times) : null
  }
}
