import type { Principal } from "@cmux/ownership"
import { mobileCatalog } from "@cmux/protocol"
import type { Env } from "./env.ts"
import { HostForwards } from "./host-forward.ts"
import { HostStreams, MAX_SNAPSHOT_BYTES } from "./host-mirror.ts"
import { deviceRemove, deviceSet, initialHostState, macCaps, macConnected, macPresence, type HostChange, type HostStreamState } from "./host-presence.ts"
import { parseSignal, SignalBudget } from "./host-signal.ts"
import { answerHello, errorFrame, MAX_CONTROL_FRAME, readFields, readReply, sendJson, type ErrorBody } from "./mobile-session.ts"
import { mintTurnCredentials, turnAsRead } from "./realtime-turn.ts"
import { closeQuietly, SocketGate } from "./socket-gate.ts"
import { MOBILE_RATE_LIMITED, MOBILE_RATE_RETRY_SECONDS, mobileRateKey, takeMobileRate } from "./mobile-rate.ts"
import { ACCESS_CHECK_MS, HOST_CAPS, MAX_DEVICES, type ControlAttachment } from "./host-control-types.ts"
export { ACCESS_CHECK_MS, HOST_CAPS, MAX_DEVICES, type ControlAttachment } from "./host-control-types.ts"

/**
 * HostDO's control sockets (b1-control-do.md): the Mac (`host`) and the phones and other clients
 * (`device`) of one host speak cmux.mobile/1 JSON frames here, next to the binary datagram relay.
 * HostDO owns `host:<host>`, mirrors `workspace:<host>` and `task:<host>` from the Mac, forwards
 * device ops and reads to the Mac, and relays WebRTC signals. The Worker authenticated the socket
 * and resolved its role (TeamDO.hostAccess); frames never choose identity.
 */

const KEY = /^[A-Za-z0-9._:-]{8,128}$/
const HOST_TAG = "ctl:host"
const devTag = (identity: string) => `ctl:dev:${identity}`
const identityOf = (p: Principal) => p.install ?? p.identity
const opsOf = (family: string, kind: string): Set<string> => new Set<string>(mobileCatalog.families.find((f) => f.name === family)?.messages.filter((m) => m.kind === kind).map((m) => m.name) ?? [])
const DEVICE_OPS = new Set([...opsOf("workspace", "op"), ...opsOf("task", "op")])
const FORWARD_READS = opsOf("task", "read")

type Frame = Record<string, unknown> & { t?: unknown }

export class HostControl {
  private readonly streams: HostStreams
  private readonly forwards: HostForwards
  private readonly budget = new SignalBudget()
  private readonly compacting = new Set<string>()
  readonly gate: SocketGate

  constructor(
    private readonly ctx: DurableObjectState,
    private readonly env: Env
  ) {
    const sql = ctx.storage.sql
    sql.exec(`CREATE TABLE IF NOT EXISTS host_ctl (id INTEGER PRIMARY KEY CHECK (id = 1), host TEXT NOT NULL, host_install TEXT NOT NULL)`)
    this.streams = new HostStreams(sql)
    this.forwards = new HostForwards(sql)
    this.gate = new SocketGate(ctx, env, () => true, (ws, a) => this.resync(ws, a as unknown as ControlAttachment))
  }

  private ids(): { host: string; hostInstall: string } | undefined {
    const row = this.ctx.storage.sql.exec<{ host: string; host_install: string }>(`SELECT host, host_install FROM host_ctl WHERE id = 1`).toArray()[0]
    return row ? { host: row.host, hostInstall: row.host_install } : undefined
  }

  private streamNames(host: string) {
    return { host: `host:${host}`, workspace: `workspace:${host}`, task: `task:${host}` }
  }

  private sockets(): Array<{ ws: WebSocket; a: ControlAttachment }> {
    const out: Array<{ ws: WebSocket; a: ControlAttachment }> = []
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment() as ControlAttachment | null
      if (a?.ctl) out.push({ ws, a })
    }
    return out
  }

  private macOnline(except?: WebSocket): boolean {
    return this.ctx.getWebSockets(HOST_TAG).some((ws) => ws !== except && ws.readyState === WebSocket.READY_STATE_OPEN)
  }

  private toMac(frame: unknown): boolean {
    let sent = false
    for (const ws of this.ctx.getWebSockets(HOST_TAG)) {
      const a = ws.deserializeAttachment() as ControlAttachment | null
      if (a && this.gate.answerable(ws, a as never)) [sendJson(ws, frame), (sent = true)]
    }
    return sent
  }

  private toDevice(identity: string, frame: unknown): boolean {
    let sent = false
    for (const ws of this.ctx.getWebSockets(devTag(identity))) {
      const a = ws.deserializeAttachment() as ControlAttachment | null
      if (a && this.gate.answerable(ws, a as never)) [sendJson(ws, frame), (sent = true)]
    }
    return sent
  }

  private publish(stream: string, frame: unknown, except?: WebSocket) {
    const text = JSON.stringify(frame)
    for (const { ws, a } of this.sockets()) {
      if (ws === except || !a.streams.includes(stream) || !this.gate.live(ws, a as never)) continue
      try {
        ws.send(text)
      } catch {}
    }
  }

  /** Commits HostDO's own changes to `host:` and publishes each event. */
  private commitHost(changes: ReadonlyArray<HostChange | null>, actor: string): number {
    const ids = this.ids()
    let seq = 0
    if (!ids) return seq
    const stream = this.streamNames(ids.host).host
    for (const c of changes) {
      if (!c) continue
      const e = this.streams.commitOwned(stream, c.state, (s) => ({ t: "event", stream, seq: s, tx: `tx_${ids.host}_${s}`, op: c.op, params: c.params, actor: { identity: actor }, origin: "remote", at: c.state.at }))
      seq = e.seq
      this.publish(stream, e)
    }
    return seq
  }

  private hostState(): HostStreamState {
    const ids = this.ids()!
    return (this.streams.head(this.streamNames(ids.host).host)?.state as HostStreamState | undefined) ?? initialHostState(ids.host, Date.now())
  }

  /** WebSocket upgrade for a control socket; the Worker set the headers after authentication. */
  accept(request: Request): Response {
    const host = request.headers.get("x-cmux-entity")
    const hostInstall = request.headers.get("x-cmux-host-install")
    const role = request.headers.get("x-cmux-ctl-role")
    const principalJson = request.headers.get("x-cmux-principal")
    const team = request.headers.get("x-cmux-team") ?? ""
    if (!host || !hostInstall || !principalJson || (role !== "host" && role !== "device")) return new Response("bad request", { status: 400 })
    const principal = JSON.parse(principalJson) as Principal
    if (role === "host" && principal.install !== hostInstall) return new Response("forbidden", { status: 403 })
    const known = this.ids()
    // HostDO placement is part of the TeamDO enrollment.  A warm or hibernated
    // object must never accept a different enrollment for the same name: doing so
    // would silently move the durable mirror and relay state to another install.
    if (known && (known.host !== host || known.hostInstall !== hostInstall)) return new Response("forbidden", { status: 403 })
    this.ctx.storage.sql.exec(`INSERT INTO host_ctl (id, host, host_install) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET host_install = excluded.host_install`, host, hostInstall)
    const tag = role === "host" ? HOST_TAG : devTag(identityOf(principal))
    const devices = new Set(this.sockets().filter((s) => s.a.role === "device").map((s) => identityOf(s.a.principal)))
    if (role === "device" && !devices.has(identityOf(principal)) && devices.size >= MAX_DEVICES) return new Response("too many devices", { status: 429 })
    const { 0: client, 1: server } = new WebSocketPair()
    // One live socket per role and identity: a reconnect replaces the old one.
    const replaced = this.ctx.getWebSockets(tag)
    for (const old of replaced) closeQuietly(old, 4000, "replaced")
    // A replaced Mac socket cannot answer its forwards: the devices resend with the same keys.
    if (role === "host" && replaced.length > 0) this.failForwards(this.forwards.drainAll(), "the Mac reconnected")
    this.ctx.acceptWebSocket(server, [tag])
    server.serializeAttachment({ ctl: true, role, principal, subscribed: false, streams: [], team, checkedAt: Date.now() } satisfies ControlAttachment)
    this.gate.seed(server, principal, { cls: "HostDO", name: host })
    const names = this.streamNames(host)
    this.reconcile(server, role === "host")
    if (!this.streams.head(names.host)) this.streams.commitOwned(names.host, initialHostState(host, Date.now()), (s) => ({ seq: s, t: "event", stream: names.host, tx: `tx_${host}_${s}`, op: "host.presence.set", params: { host, presence: "offline", viewers: 0, at: Date.now() }, actor: { identity: `host:${host}` }, origin: "remote", at: Date.now() }))
    if (role === "host") this.commitHost([macConnected(this.hostState(), true, Date.now())], `host:${host}`)
    sendJson(server, { t: "welcome", principal: { user: principal.user, team: principal.team, install: principal.install }, server_time: Date.now(), streams: [names.host, names.workspace, names.task], role })
    void this.scheduleAlarm()
    return new Response(null, { status: 101, webSocket: client, headers: { "Sec-WebSocket-Protocol": "cmux.wire.v1" } })
  }

  async message(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    await this.gate.enqueue(ws, message, () => this.handle(ws, message), "host")
  }

  private async handle(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const a = ws.deserializeAttachment() as ControlAttachment
    const text = typeof message === "string" ? message : new TextDecoder().decode(message)
    if (text.length > MAX_CONTROL_FRAME) return sendJson(ws, errorFrame({ code: "validation.invalid", message: `frames are at most ${MAX_CONTROL_FRAME} bytes`, retryable: false }))
    let frame: Frame
    try {
      frame = JSON.parse(text) as Frame
      if (typeof frame !== "object" || frame === null || Array.isArray(frame)) throw new Error("not an object")
    } catch {
      return sendJson(ws, errorFrame({ code: "validation.invalid", message: "frames are JSON objects", retryable: false }))
    }
    if (!(await this.stillAdmitted(ws, a))) return
    if (frame.t === "hello") return this.hello(ws, a, frame)
    if (!a.mobile) return sendJson(ws, errorFrame({ code: "proto.hello_required", message: "send hello first", retryable: false }))
    switch (frame.t) {
      case "subscribe":
      case "snapshot.request":
        return this.subscribe(ws, a, frame)
      case "unsubscribe": {
        const stream = typeof frame.stream === "string" ? frame.stream : this.streamNames(this.ids()!.host).host
        a.streams = a.streams.filter((s) => s !== stream)
        return ws.serializeAttachment(a)
      }
      case "signal":
        return this.signal(ws, a, frame)
    }
    if (a.role === "device") return this.deviceFrame(ws, a, frame)
    return this.macFrame(ws, a, frame)
  }

  private async hello(ws: WebSocket, a: ControlAttachment, frame: Frame) {
    const session = answerHello(ws, frame, HOST_CAPS)
    if (!session) return
    a.mobile = session
    ws.serializeAttachment(a)
    const ids = this.ids()!
    const names = this.streamNames(ids.host)
    if (a.role === "device") {
      const p = a.principal
      this.commitHost(deviceSet(this.hostState(), { install: identityOf(p), platform: session.client.platform, app_version: session.client.app_version, active: true, since: Date.now() }, Date.now()), identityOf(p))
    } else {
      // A (re)connected Mac sends its current snapshots; the mirror replaces what it held.
      for (const stream of [names.workspace, names.task]) sendJson(ws, { t: "snapshot.request", stream })
    }
    const resume = Array.isArray(frame.resume) ? (frame.resume as Array<{ stream?: unknown; seq?: unknown }>) : []
    for (const r of resume.slice(0, 8)) if (typeof r?.stream === "string" && Number.isInteger(r.seq)) await this.subscribe(ws, a, { t: "subscribe", stream: r.stream, after_seq: r.seq })
  }

  private emptyState(stream: string, host: string): unknown {
    return stream.startsWith("workspace:") ? { host, workspaces: [] } : { host, tasks: [] }
  }

  private async subscribe(ws: WebSocket, a: ControlAttachment, frame: Frame) {
    const ids = this.ids()!
    const names = this.streamNames(ids.host)
    const stream = typeof frame.stream === "string" ? frame.stream : names.host
    if (stream !== names.host && stream !== names.workspace && stream !== names.task) return sendJson(ws, errorFrame({ code: "auth.forbidden", message: `not a stream of ${ids.host}`, retryable: false }))
    if (!a.streams.includes(stream)) [a.streams.push(stream), ws.serializeAttachment(a)]
    let pending = Array.isArray(frame.pending) ? (frame.pending as Array<unknown>).filter((k): k is string => typeof k === "string" && KEY.test(k)).slice(0, 256) : []
    const after = frame.t === "subscribe" && Number.isInteger(frame.after_seq) ? (frame.after_seq as number) : undefined
    // Pending intents need the owner's decided keys: the Mac follows with this device's own snapshot.
    // The mirror's snapshot goes first, so a Mac that never answers leaves no subscriber without state.
    if (stream !== names.host && pending.length > 0 && a.role === "device" && this.macOnline()) {
      const identity = identityOf(a.principal)
      if (!(await takeMobileRate(this.env.MOBILE_PENDING_LIMIT, mobileRateKey("pending", identity), true))) {
        sendJson(ws, errorFrame({ code: MOBILE_RATE_LIMITED, message: "too many pending snapshot requests; retry shortly", retryable: true, details: { retry_after_s: MOBILE_RATE_RETRY_SECONDS } }))
        // Still serve the local mirror below; the client can retry its pending keys later.
        pending = []
      } else {
        this.toMac({ t: "snapshot.request", stream, pending, to: identity })
      }
    }
    const epoch = typeof frame.epoch === "string" ? frame.epoch : undefined
    const r = this.streams.resume(stream, pending.length > 0 ? undefined : after, epoch)
    if (!r) return sendJson(ws, { t: "snapshot", stream, seq: 0, state: this.emptyState(stream, ids.host), decided: [] })
    if (r.snapshot) sendJson(ws, { t: "snapshot", stream, seq: r.snapshot.seq, state: r.snapshot.state, decided: [], ...(r.snapshot.epoch ? { epoch: r.snapshot.epoch } : {}) })
    for (const e of r.events) sendJson(ws, e)
  }

  /** After a held socket passes the install check again: a fresh snapshot of each stream it follows. */
  private resync(ws: WebSocket, a: ControlAttachment) {
    for (const stream of a.streams ?? []) void this.subscribe(ws, a, { t: "snapshot.request", stream })
  }

  private reject(ws: WebSocket, key: string, stream: string, e: ErrorBody) {
    sendJson(ws, { t: "reject", tx: "", idempotency_key: key, code: e.code, message: e.message, retryable: e.retryable, replayed: false })
    sendJson(ws, { t: "request-settled", tx: "", idempotency_key: key, stream, sequence: 0, ok: false })
  }

  private async deviceFrame(ws: WebSocket, a: ControlAttachment, frame: Frame) {
    const ids = this.ids()!
    const me = identityOf(a.principal)
    switch (frame.t) {
      case "op": {
        const key = typeof frame.idempotency_key === "string" ? frame.idempotency_key : ""
        const op = typeof frame.op === "string" ? frame.op : ""
        const family = op.split(".")[0] ?? ""
        const stream = `${family === "host" ? "host" : family}:${ids.host}`
        if (!KEY.test(key)) return this.reject(ws, key, stream, { code: "validation.invalid", message: "idempotency_key must be 8 to 128 of [A-Za-z0-9._:-]", retryable: false })
        const params = (typeof frame.params === "object" && frame.params !== null ? frame.params : {}) as Record<string, unknown>
        if (params.host !== undefined && params.host !== ids.host) return this.reject(ws, key, stream, { code: "validation.invalid", message: "params.host names another host", retryable: false })
        if (op === "host.wake") {
          if (!this.macOnline()) return this.reject(ws, key, stream, { code: "host.not_wakeable", message: "the host is offline and cannot be woken from here", retryable: true })
          const seq = this.streams.head(stream)?.head ?? 0
          sendJson(ws, { t: "result", tx: `tx_${ids.host}_wake`, idempotency_key: key, value: { presence: this.hostState().presence }, revision: String(seq), replayed: false })
          return sendJson(ws, { t: "request-settled", tx: `tx_${ids.host}_wake`, idempotency_key: key, stream, sequence: 0, ok: true })
        }
        if (!DEVICE_OPS.has(op)) return this.reject(ws, key, stream, { code: family === "workspace" || family === "task" ? "auth.forbidden" : "validation.invalid", message: `${op} is not a device op on this host`, retryable: false })
        // Nothing queues while the owner is away (OWNERSHIP-PRINCIPLES "Offline").
        if (!this.macOnline()) return this.reject(ws, key, stream, { code: "owner.unreachable", message: "the Mac is offline", retryable: true })
        this.failForwards(this.forwards.expire(Date.now()), "the Mac did not answer in time")
        if (!this.forwards.addOp(me, key, Date.now())) return this.reject(ws, key, stream, { code: "rate.limited", message: "too many requests in flight", retryable: true })
        const p = a.principal
        // Device ops are remote by definition (OWNERSHIP-PRINCIPLES origin rule): they never move the Mac's focus.
        this.toMac({ t: "op", op, params, idempotency_key: key, origin: "remote", ...(typeof frame.expected_revision === "string" ? { expected_revision: frame.expected_revision } : {}), stream, from: me, actor: { identity: me, ...(p.user ? { user: p.user } : {}), ...(p.install ? { install: p.install } : {}), kind: p.kind ?? "install" } })
        return void this.scheduleAlarm()
      }
      case "read": {
        const r = readFields(frame)
        if (!r.ok) return sendJson(ws, r.error)
        const requestedHost = typeof r.params === "object" && r.params !== null ? (r.params as { host?: unknown }).host : undefined
        // HostDO is already scoped to one host.  Do not let a device smuggle a
        // different host selector through the Mac forward path; the HTTP read
        // path applies the same selector ownership before reaching an owner.
        if (requestedHost !== undefined && requestedHost !== ids.host) return sendJson(ws, errorFrame({ code: "validation.invalid", message: "read params.host names another host", retryable: false }, r.id))
        if (r.op === "signal.turn_credentials") {
          if (!(await takeMobileRate(this.env.MOBILE_TURN_LIMIT, mobileRateKey("turn", me), true))) return sendJson(ws, readReply(r.id, { ok: false, code: MOBILE_RATE_LIMITED, message: "too many TURN credential requests; retry shortly", retryable: true, details: { retry_after_s: MOBILE_RATE_RETRY_SECONDS } }))
          return sendJson(ws, readReply(r.id, turnAsRead(await mintTurnCredentials(this.env, me))))
        }
        if (!FORWARD_READS.has(r.op)) return sendJson(ws, errorFrame({ code: "validation.invalid", message: `unknown read ${r.op}`, retryable: false }, r.id))
        if (!this.macOnline()) return sendJson(ws, errorFrame({ code: "owner.unreachable", message: "the Mac is offline", retryable: true }, r.id))
        this.failForwards(this.forwards.expire(Date.now()), "the Mac did not answer in time")
        const id = this.forwards.addRead(me, r.id, Date.now())
        if (id === null) return sendJson(ws, errorFrame({ code: "rate.limited", message: "too many requests in flight", retryable: true }, r.id))
        this.toMac({ t: "read", id, op: r.op, params: r.params, from: me })
        return void this.scheduleAlarm()
      }
      case "presence.set": {
        const state = frame.state as { active?: unknown } | undefined
        if (typeof state?.active !== "boolean") return sendJson(ws, errorFrame({ code: "validation.invalid", message: "presence.set needs state.active", retryable: false }))
        const old = this.hostState().devices.find((d) => d.install === me)
        if (!old) return
        return void this.commitHost(deviceSet(this.hostState(), { ...old, active: state.active }, Date.now()), me)
      }
      default:
        return sendJson(ws, errorFrame({ code: "proto.unknown_frame", message: `unknown frame ${String(frame.t)}`, retryable: false }))
    }
  }

  private signal(ws: WebSocket, a: ControlAttachment, frame: Frame) {
    if (!this.budget.take(ws)) return sendJson(ws, errorFrame({ code: "signal.rate_limited", message: "too many signals", retryable: true }))
    const s = parseSignal(frame)
    if (!s.ok) return sendJson(ws, errorFrame(s.error))
    const ids = this.ids()!
    // `from` is always the sender's authenticated identity; a client value is dropped.
    const relayed = { t: "signal", kind: s.kind, session: s.session, to: s.to, from: identityOf(a.principal), body: s.body }
    if (a.role === "device") {
      if (s.to !== ids.host && s.to !== ids.hostInstall) return sendJson(ws, errorFrame({ code: "auth.forbidden", message: "devices signal only their host", retryable: false }))
      if (!this.toMac(relayed)) sendJson(ws, errorFrame({ code: "signal.peer_offline", message: "the host is not connected", retryable: true }))
      return
    }
    if (!this.toDevice(s.to, relayed)) sendJson(ws, errorFrame({ code: "signal.peer_offline", message: "that device is not connected to this host", retryable: true }))
  }

  private async macFrame(ws: WebSocket, a: ControlAttachment, frame: Frame) {
    const ids = this.ids()!
    const names = this.streamNames(ids.host)
    const mirrored = (s: unknown): s is string => s === names.workspace || s === names.task
    switch (frame.t) {
      case "read": {
        // The Mac's WebRTC acceptor needs ICE servers too (b2-webrtc.md 5); it is the only read the host role asks.
        const r = readFields(frame)
        if (!r.ok) return sendJson(ws, r.error)
        const requestedHost = typeof r.params === "object" && r.params !== null ? (r.params as { host?: unknown }).host : undefined
        if (requestedHost !== undefined && requestedHost !== ids.host) return sendJson(ws, errorFrame({ code: "validation.invalid", message: "read params.host names another host", retryable: false }, r.id))
        if (r.op !== "signal.turn_credentials") return sendJson(ws, errorFrame({ code: "validation.invalid", message: `unknown read ${r.op}`, retryable: false }, r.id))
        const identity = identityOf(a.principal)
        if (!(await takeMobileRate(this.env.MOBILE_TURN_LIMIT, mobileRateKey("turn", identity), true))) return sendJson(ws, readReply(r.id, { ok: false, code: MOBILE_RATE_LIMITED, message: "too many TURN credential requests; retry shortly", retryable: true, details: { retry_after_s: MOBILE_RATE_RETRY_SECONDS } }))
        return sendJson(ws, readReply(r.id, turnAsRead(await mintTurnCredentials(this.env, identity))))
      }
      case "op": {
        const key = typeof frame.idempotency_key === "string" ? frame.idempotency_key : ""
        const params = (typeof frame.params === "object" && frame.params !== null ? frame.params : {}) as Record<string, unknown>
        const now = Date.now()
        const change = frame.op === "host.presence.set" ? macPresence(this.hostState(), params.presence, now) : frame.op === "host.caps.set" ? macCaps(this.hostState(), params, now) : { error: `${String(frame.op)} is not a host op` }
        if (change && "error" in change) return this.reject(ws, key, names.host, { code: "validation.invalid", message: change.error, retryable: false })
        const seq = this.commitHost([change], identityOf(a.principal))
        const head = this.streams.head(names.host)?.head ?? 0
        sendJson(ws, { t: "result", tx: `tx_${ids.host}_${head}`, idempotency_key: key, value: { presence: this.hostState().presence }, revision: String(head), replayed: false })
        return sendJson(ws, { t: "request-settled", tx: `tx_${ids.host}_${head}`, idempotency_key: key, stream: names.host, sequence: seq, ok: true })
      }
      case "snapshot": {
        if (!mirrored(frame.stream) || !Number.isInteger(frame.seq) || (frame.seq as number) < 0 || typeof frame.state !== "object" || frame.state === null) return sendJson(ws, errorFrame({ code: "validation.invalid", message: "snapshot needs a mirrored stream, seq and state", retryable: false }))
        if (new TextEncoder().encode(JSON.stringify(frame.state)).length > MAX_SNAPSHOT_BYTES) return sendJson(ws, errorFrame({ code: "validation.invalid", message: `snapshots are at most ${MAX_SNAPSHOT_BYTES} bytes`, retryable: false }))
        const stream = frame.stream
        const seq = frame.seq as number
        const head = this.streams.head(stream)
        this.compacting.delete(stream)
        const epoch = typeof frame.epoch === "string" && frame.epoch.length > 0 && frame.epoch.length <= 128 ? frame.epoch : null
        // Once a stream has entered the epoch protocol, a snapshot without an epoch
        // is ambiguous: it could be a delayed response from the previous Mac process.
        // Refuse it before touching the durable mirror (including targeted pending-key
        // answers), so a stale producer cannot clear the persisted epoch.
        if (head?.epoch !== null && head?.epoch !== undefined && epoch === null) return sendJson(ws, errorFrame({ code: "validation.invalid", message: "snapshot epoch is required for an epoch-scoped stream", retryable: false }))
        // A new epoch replaces the mirror and its tail even at a lower seq (the Mac's store restarted).
        const moved = !head || head.head !== seq || head.epoch !== epoch
        if (moved || typeof frame.to !== "string") this.streams.replaceSnapshot(stream, seq, frame.state, epoch)
        const plain = { t: "snapshot", stream, seq, state: frame.state, decided: [], ...(epoch ? { epoch } : {}) }
        const target = typeof frame.to === "string" ? frame.to : undefined
        if (target) this.toDevice(target, { ...plain, decided: Array.isArray(frame.decided) ? frame.decided : [] })
        if (moved) for (const { ws: d, a: da } of this.sockets()) if (da.role === "device" && identityOf(da.principal) !== target && da.streams.includes(stream) && this.gate.live(d, da as never)) sendJson(d, plain)
        return
      }
      case "event": {
        if (!mirrored(frame.stream) || !Number.isInteger(frame.seq) || typeof frame.op !== "string" || !frame.op.startsWith(`${frame.stream.split(":")[0]}.`)) return sendJson(ws, errorFrame({ code: "validation.invalid", message: "event needs a mirrored stream, seq and an op of its family", retryable: false }))
        const stream = frame.stream
        const outcome = this.streams.appendMirrored(stream, frame as { seq: number })
        if (outcome === "applied") this.publish(stream, frame, ws)
        const wants = outcome === "gap" || outcome === "full" || (outcome === "applied" && this.streams.wantsCompaction(stream))
        if (wants && !this.compacting.has(stream)) {
          this.compacting.add(stream)
          sendJson(ws, { t: "snapshot.request", stream })
        }
        return
      }
      case "result":
      case "reject":
      case "request-settled": {
        const to = typeof frame.to === "string" ? frame.to : ""
        const key = typeof frame.idempotency_key === "string" ? frame.idempotency_key : ""
        if (!this.forwards.hasOp(to, key)) return
        const { to: _to, ...out } = frame
        this.toDevice(to, out)
        if (frame.t === "request-settled") this.forwards.endOp(to, key)
        return
      }
      case "read.result":
      case "error": {
        if (!Number.isInteger(frame.id)) return
        const fwd = this.forwards.takeRead(frame.id as number)
        if (fwd) this.toDevice(fwd.device, { ...frame, id: fwd.deviceId })
        return
      }
      default:
        return sendJson(ws, errorFrame({ code: "proto.unknown_frame", message: `unknown frame ${String(frame.t)}`, retryable: false }))
    }
  }

  /** Every in-flight forward of a departed Mac: outcome unknown, the device keeps its intent and resends. */
  private failForwards(list: ReturnType<HostForwards["drainAll"]>, why: string) {
    for (const o of list.ops) this.toDevice(o.device, { t: "error", code: "owner.unreachable", message: why, retryable: true, idempotency_key: o.key })
    for (const r of list.reads) this.toDevice(r.device, errorFrame({ code: "owner.unreachable", message: why, retryable: true }, r.deviceId))
  }

  /**
   * Presence from the sockets that are really open: a close callback lost to a deploy or reset
   * would otherwise leave `online` and stale devices forever. Runs at every accept.
   */
  private reconcile(except: WebSocket, macArriving: boolean) {
    const ids = this.ids()
    if (!ids || !this.streams.head(this.streamNames(ids.host).host)) return
    const now = Date.now()
    const live = new Set(this.sockets().filter((s) => s.ws !== except && s.a.role === "device" && s.ws.readyState === WebSocket.READY_STATE_OPEN).map((s) => identityOf(s.a.principal)))
    for (const d of this.hostState().devices) if (!live.has(d.install)) this.commitHost(deviceRemove(this.hostState(), d.install, now), `host:${ids.host}`)
    if (!macArriving && !this.macOnline(except) && this.hostState().presence !== "offline") this.commitHost([macConnected(this.hostState(), false, now)], `host:${ids.host}`)
  }

  /**
   * Admission is re-asked from TeamDO every ACCESS_CHECK_MS on the socket's frames: a member who
   * left the team or a removed host loses the socket (4403). A listen-only socket is bounded by its
   * token's expiry (access tokens live 10 minutes). An unreachable TeamDO refuses the frame.
   */
  private async stillAdmitted(ws: WebSocket, a: ControlAttachment): Promise<boolean> {
    if (Date.now() - a.checkedAt < ACCESS_CHECK_MS) return true
    const ids = this.ids()
    if (!ids || !a.team) return false
    let access: { role: string } | null
    try {
      access = await this.env.TEAM_DO.get(this.env.TEAM_DO.idFromName(a.team)).hostAccess(a.team, ids.host, a.principal)
    } catch {
      sendJson(ws, errorFrame({ code: "owner.unreachable", message: "could not check access; retry", retryable: true }))
      return false
    }
    if (!access || access.role !== a.role) {
      closeQuietly(ws, 4403, "access revoked")
      return false
    }
    a.checkedAt = Date.now()
    ws.serializeAttachment(a)
    return true
  }

  closed(ws: WebSocket, a: ControlAttachment): void {
    this.gate.closed(ws)
    const ids = this.ids()
    if (!ids) return
    const now = Date.now()
    if (a.role === "host") {
      if (this.macOnline(ws)) return
      this.commitHost([macConnected(this.hostState(), false, now)], `host:${ids.host}`)
      this.failForwards(this.forwards.drainAll(), "the Mac disconnected")
      return
    }
    const me = identityOf(a.principal)
    if (this.ctx.getWebSockets(devTag(me)).some((s) => s !== ws && s.readyState === WebSocket.READY_STATE_OPEN)) return
    this.commitHost(deviceRemove(this.hostState(), me, now), me)
  }

  /** UserDO revoked an install (socket-registry.ts): its control sockets close now. */
  closeInstall(install: string, agent?: string): void {
    if (!agent) this.gate.revoked(install)
    for (const { ws, a } of this.sockets()) if (a.principal.install === install && (!agent || a.principal.agent === agent)) closeQuietly(ws, 4401, "revoked")
  }

  async alarm(now: number): Promise<void> {
    this.gate.sweep(now)
    this.failForwards(this.forwards.expire(now), "the Mac did not answer in time")
    await this.scheduleAlarm()
  }

  private async scheduleAlarm(): Promise<void> {
    const times = [this.gate.nextExpiry(), this.forwards.nextExpiry()].filter((t): t is number => t !== null)
    if (times.length === 0) return
    const at = Math.max(Math.min(...times), Date.now())
    const current = await this.ctx.storage.getAlarm()
    if (current === null || current > at || current < Date.now()) await this.ctx.storage.setAlarm(at)
  }
}
