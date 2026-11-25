import { DurableObject } from "cloudflare:workers"
import type { Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { route, type Endpoint } from "./host-relay/route.ts"
import { ReplicaStore } from "./host-replica/store.ts"
import { replicaPrincipal, ReplicaWire, type ReplicaAttachment } from "./host-replica/wire.ts"

interface Attachment {
  readonly role: "host" | "client"
  /** Relay peer id (hex) derived by the Worker from the authenticated principal. */
  readonly peer: string
  /** When the socket was accepted, and when a frame last came from it (ms, the object's clock). */
  readonly at?: number
  readonly seen?: number
}

/**
 * Liveness (cmuxterm-hq docs/handbook/connections-and-lifetimes.md): a socket whose peer vanished
 * without a close (sleep, network change, NAT timeout: no FIN) still looks open here. A client
 * sends the text `ping` every PING_INTERVAL_MS (the runtime answers `pong` without waking the
 * object); a socket with no ping and no frame for STALE_AFTER_MS (two missed pings and a grace)
 * is closed with STALE_CODE and run through the normal close path, so presence flips and ops in
 * flight are refused at once. Relay sockets are always held to it. Replica sockets are held once
 * they have pinged: today's publishers send no ping, and an idle healthy Mac must not flap.
 */
export const PING_INTERVAL_MS = 15_000
export const STALE_AFTER_MS = 45_000
export const STALE_CODE = 4408
/** At most one `relay.dropped` notice per sender and reason in this window: a flood never echoes a flood. */
export const DROP_NOTICE_WINDOW_MS = 1_000
/** A frame refreshes `seen` at most this often (one attachment write per second per busy socket). */
const SEEN_GRANULARITY_MS = 1_000

const HOST_TAG = "host"
const clientTag = (peer: string) => `client:${peer}`
const PUBLISHER_TAG = "replica:publisher"
const READERS_TAG = "replica:reader"
const publisherTag = (id: string) => `replica:publisher:${id}`
const openSocket = (ws: WebSocket | undefined) => (ws && ws.readyState === WebSocket.READY_STATE_OPEN ? ws : undefined)
const readerTag = (id: string) => `replica:reader:${id}`

const isReplica = (a: unknown): a is ReplicaAttachment => {
  const role = (a as { role?: unknown } | null)?.role
  return role === "publisher" || role === "reader"
}

const closeQuietly = (ws: WebSocket, code: number, reason: string) => {
  try {
    ws.close(code, reason)
  } catch {}
}

const sendQuietly = (ws: WebSocket, data: string | Uint8Array) => {
  try {
    ws.send(data)
  } catch {}
}

/**
 * HostDO: one object per host (plans/cmux-next/transport.md section 6). This first slice is the
 * datagram relay: the host keeps one hibernating WebSocket here, clients of that host connect with
 * their own sockets, and binary relay frames move between them under `route` (peer rewrite,
 * reachability compiled by `TeamDO`). Pings are answered by the runtime's auto-response, so an
 * idle host costs no duration but one liveness alarm per STALE_AFTER_MS. The Worker authenticates
 * every socket (relay ticket from `UserDO`) and passes the derived peer id; frames never choose
 * identity. Relay sockets also get text control frames (JSON, never binary, so a datagram reader
 * is not confused): `relay.host {status: "online" | "offline"}` to clients on connect and
 * whenever the host comes or goes, and `relay.dropped {reason, peer?}` to a sender whose frame
 * was not forwarded (`host_offline`, `client_offline`, `not_reachable` or a frame error).
 *
 * The second role is the read replica of the host's host-homed streams (object-sync phase 3,
 * host-replica/): the host publishes snapshots and events, readers subscribe with the ordinary
 * `cmux.wire/1` client frames and read with the host off, and ops are forwarded to the online host
 * or refused. Its sockets use the `x-cmux-replica-role` header the Worker sets after TeamDO named
 * the role (TeamDO.hostReplicaRole).
 * Not yet: rendezvous storage, wake, per-client budgets.
 */
export class HostDO extends DurableObject<Env> {
  private reachable: Set<string> | undefined
  private replicaWire: ReplicaWire | undefined
  /** The last `relay.dropped` notice per sender and reason (in memory: a wake may send one more). */
  private readonly notices = new Map<string, number>()
  /** The relay host status clients were last told (in memory: a wake may tell them once more). */
  private toldHost: "online" | "offline" | undefined
  /** The object's clock; a field so tests can move it (test/host-do-liveness.test.ts). */
  clock: () => number = () => Date.now()

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS host_relay (id INTEGER PRIMARY KEY CHECK (id = 1), host_peer TEXT NOT NULL, reachable TEXT NOT NULL)`)
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS replica_dropped (id INTEGER PRIMARY KEY CHECK (id = 1), at INTEGER NOT NULL, reason TEXT NOT NULL)`)
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"))
  }

  /** The replica of `host` (the object's name, passed by the Worker on every replica request). */
  private replica(host: string): ReplicaWire {
    if (!this.replicaWire) {
      this.ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS replica_host (id INTEGER PRIMARY KEY CHECK (id = 1), host TEXT NOT NULL)`)
      this.ctx.storage.sql.exec(`INSERT INTO replica_host (id, host) VALUES (1, ?) ON CONFLICT(id) DO NOTHING`, host)
      const ctx = this.ctx
      this.replicaWire = new ReplicaWire(new ReplicaStore(ctx.storage.sql), {
        host,
        publisher: (id) => openSocket(ctx.getWebSockets(publisherTag(id))[0]),
        readers: () => ctx.getWebSockets(READERS_TAG),
        reader: (id) => openSocket(ctx.getWebSockets(readerTag(id))[0]),
        now: () => this.clock()
      })
    }
    return this.replicaWire
  }

  /** After hibernation the object has no name in memory: the stored one. */
  private storedReplica(): ReplicaWire | undefined {
    if (this.replicaWire) return this.replicaWire
    const exists = this.ctx.storage.sql.exec(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'replica_host'`).toArray().length > 0
    const host = exists ? this.ctx.storage.sql.exec<{ host: string }>(`SELECT host FROM replica_host WHERE id = 1`).toArray()[0]?.host : undefined
    return host ? this.replica(host) : undefined
  }

  /** A replica socket upgrade; the Worker set the host, the role and the principal. */
  private async replicaFetch(request: Request, role: string): Promise<Response> {
    const host = request.headers.get("x-cmux-host") ?? ""
    const principalJson = request.headers.get("x-cmux-principal")
    if ((role !== "publisher" && role !== "reader") || !/^host_[a-z0-9]{20}$/.test(host) || !principalJson) return new Response("forbidden", { status: 403 })
    // A dropped replica stays dropped: host ids are never reused, so a late upgrade (its role checked before the drop) gets nothing.
    if (this.replicaDropped()) return new Response("gone", { status: 410 })
    const principal = replicaPrincipal(JSON.parse(principalJson) as Principal)
    // An install socket lives only as long as its registry row, which needs the token's expiry.
    if (principal.kind === "install" && principal.expires_at === undefined) return new Response("forbidden", { status: 403 })
    const wire = this.replica(host)
    const { 0: client, 1: server } = new WebSocketPair()
    const id = crypto.randomUUID()
    if (role === "publisher") {
      // One publisher: a reconnect replaces the old socket (its close does not mark the host offline).
      for (const old of this.ctx.getWebSockets(PUBLISHER_TAG)) closeQuietly(old, 4000, "replaced")
      this.ctx.acceptWebSocket(server, [PUBLISHER_TAG, publisherTag(id)])
    } else this.ctx.acceptWebSocket(server, [READERS_TAG, readerTag(id)])
    server.serializeAttachment({ role, principal, id, streams: [], at: this.clock() } satisfies ReplicaAttachment)
    this.registerSocket(server, principal, host)
    await this.armAlarm()
    // A drop that ran during the await closed this socket; touch nothing it purged.
    if (this.replicaDropped() || server.readyState !== WebSocket.READY_STATE_OPEN) {
      closeQuietly(server, 4403, "replica dropped")
      return new Response("gone", { status: 410 })
    }
    if (role === "publisher") wire.publisherOpened(server, id)
    else wire.readerOpened(server, principal)
    return new Response(null, { status: 101, webSocket: client, headers: { "Sec-WebSocket-Protocol": "cmux.wire.v1" } })
  }

  /** Registers an install's socket in its UserDO, so `install.revoke` closes it here at once (socket-registry.ts). */
  private registerSocket(ws: WebSocket, p: ReturnType<typeof replicaPrincipal>, host: string) {
    if (p.kind !== "install" || !p.install || !p.user) return
    const stub = this.env.USER_DO.get(this.env.USER_DO.idFromName(p.user))
    this.ctx.waitUntil(
      stub.registerSocket(p.user, p.install, p.grant, "HostDO", host, p.expires_at ?? Date.now() + 3600_000, p.agent).then(
        (ok) => (ok ? undefined : closeQuietly(ws, 4401, "install revoked")),
        () => undefined
      )
    )
  }

  private replicaDropped(): boolean {
    return this.ctx.storage.sql.exec(`SELECT 1 FROM replica_dropped WHERE id = 1`).toArray().length > 0
  }

  /**
   * RPC from TeamDO (team-host-replica-drop.ts): the host was removed or its owner left the team.
   * Forgets every stored stream and closes every replica socket. A removed host (`tombstone`) also
   * answers later upgrades 410; an orphaned one keeps its id and may be enrolled again. Idempotent.
   */
  async dropReplica(reason: string, tombstone: boolean): Promise<boolean> {
    if (tombstone && !this.replicaDropped()) this.ctx.storage.sql.exec(`INSERT INTO replica_dropped (id, at, reason) VALUES (1, ?, ?)`, Date.now(), reason.slice(0, 200))
    new ReplicaStore(this.ctx.storage.sql).purge()
    for (const ws of this.ctx.getWebSockets()) if (isReplica(ws.deserializeAttachment())) closeQuietly(ws, 4403, reason.slice(0, 100))
    return true
  }

  /** RPC from UserDO (socket-registry.ts): an install was revoked; close its replica sockets now. */
  async closeInstall(_entity: string, install: string): Promise<boolean> {
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment() as unknown
      if (isReplica(a) && a.principal.install === install) closeQuietly(ws, 4401, "revoked")
    }
    return true
  }

  /**
   * When `ws` counts as dead if nothing more comes from it (for a replica socket that has not pinged:
   * when to look at it again; `heldToBound` decides whether silence closes it). The last sign of life is the latest of its accept, its last frame and the
   * runtime's last auto-response to its `ping` (which never wakes the object).
   */
  private staleAt(ws: WebSocket, now: number): number | null {
    const a = ws.deserializeAttachment() as (Attachment | ReplicaAttachment | null)
    if (!a) return null
    const pinged = this.ctx.getWebSocketAutoResponseTimestamp(ws)?.getTime() ?? null
    const last = Math.max(a.at ?? 0, a.seen ?? 0, pinged ?? 0)
    if (!isReplica(a)) return last + STALE_AFTER_MS
    if (pinged !== null) return last + STALE_AFTER_MS
    // A replica socket that has not pinged yet is never closed for silence (today's publishers send no
    // ping; their lifetime stays the token's), but is looked at again every bound: a ping does not wake
    // the object, so a socket that starts pinging late is held to the bound from the next look on.
    const at = a.at ?? now
    return at + (Math.floor((now - at) / STALE_AFTER_MS) + 1) * STALE_AFTER_MS
  }

  /** Relay sockets always; replica sockets once they have pinged. */
  private heldToBound(ws: WebSocket): boolean {
    return !isReplica(ws.deserializeAttachment()) || this.ctx.getWebSocketAutoResponseTimestamp(ws) !== null
  }

  /** The alarm closes replica sockets whose token expired and sockets gone silent, then waits for the next of either. */
  private async armAlarm(): Promise<void> {
    const now = this.clock()
    let at: number | null = null
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.readyState !== WebSocket.READY_STATE_OPEN) continue
      const a = ws.deserializeAttachment() as unknown
      const e = isReplica(a) ? a.principal.expires_at : undefined
      for (const t of [e, this.staleAt(ws, now)]) if (typeof t === "number" && (at === null || t < at)) at = t
    }
    const current = await this.ctx.storage.getAlarm()
    if (at !== null && (current === null || at < current)) await this.ctx.storage.setAlarm(Math.max(at, now))
  }

  override async alarm(): Promise<void> {
    const now = this.clock()
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.readyState !== WebSocket.READY_STATE_OPEN) continue
      const a = ws.deserializeAttachment() as unknown
      if (isReplica(a) && a.principal.expires_at !== undefined && a.principal.expires_at <= now) {
        this.closeDead(ws, 4401, "token expired")
        continue
      }
      const stale = this.staleAt(ws, now)
      if (stale !== null && stale <= now && this.heldToBound(ws)) this.closeDead(ws, STALE_CODE, `stale: no ping or frame for ${Math.round(STALE_AFTER_MS / 1000)} s`)
    }
    await this.armAlarm()
  }

  /**
   * Closes `ws` and runs its close path now: a peer that vanished sends no close frame, so
   * `webSocketClose` may never run for it. Each close step is idempotent, so a late close event is harmless.
   */
  private closeDead(ws: WebSocket, code: number, reason: string): void {
    closeQuietly(ws, code, reason)
    this.socketGone(ws)
  }

  override async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    this.socketGone(ws)
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code, "closing")
    } catch {}
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    this.socketGone(ws)
  }

  /** A socket went away: the current publisher's close makes the host offline; the relay host's tells its clients. */
  private socketGone(ws: WebSocket): void {
    const a = ws.deserializeAttachment() as unknown
    if (!isReplica(a)) {
      const r = a as Attachment | null
      if (!r) return
      for (const key of this.notices.keys()) if (key.startsWith(`${r.role}:${r.peer}:`)) this.notices.delete(key)
      if (r.role === "host") this.broadcastHost()
      return
    }
    const wire = this.storedReplica()
    if (a.role === "publisher") wire?.publisherClosed(a.id)
    else wire?.readerClosed(a.id)
  }

  /** Whether an open relay host socket exists (a closing or vanished one does not count). */
  private hostOnline(): boolean {
    return this.ctx.getWebSockets(HOST_TAG).some((s) => s.readyState === WebSocket.READY_STATE_OPEN)
  }

  /**
   * Every relay client learns whether the host is there now, once per change: a socket's close runs
   * from the alarm (closeDead) and again from its close event, and a replaced host's close changes nothing.
   */
  private broadcastHost(): void {
    const status = this.hostOnline() ? "online" : "offline"
    if (status === this.toldHost) return
    this.toldHost = status
    const frame = JSON.stringify({ t: "relay.host", status })
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment() as Attachment | null
      if (a?.role === "client" && ws.readyState === WebSocket.READY_STATE_OPEN) sendQuietly(ws, frame)
    }
  }

  /** Set by `TeamDO` whenever the compiled reachability of this host changes. */
  async setReachability(hostPeer: string, peers: ReadonlyArray<string>): Promise<void> {
    this.ctx.storage.sql.exec(
      `INSERT INTO host_relay (id, host_peer, reachable) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET host_peer = excluded.host_peer, reachable = excluded.reachable`,
      hostPeer,
      JSON.stringify(peers)
    )
    this.reachable = new Set(peers)
    // A client that lost reachability loses its socket at once, not at ticket expiry.
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment() as Attachment | null
      if (a?.role === "client" && !this.reachable.has(a.peer)) ws.close(4003, "not reachable")
    }
  }

  private state(): { hostPeer: string; reachable: Set<string> } | undefined {
    const row = this.ctx.storage.sql.exec<{ host_peer: string; reachable: string }>(`SELECT host_peer, reachable FROM host_relay WHERE id = 1`).toArray()[0]
    if (!row) return undefined
    this.reachable ??= new Set(JSON.parse(row.reachable) as Array<string>)
    return { hostPeer: row.host_peer, reachable: this.reachable }
  }

  /** WebSocket upgrade. The Worker sets `x-cmux-relay-role` and `x-cmux-relay-peer` after auth. */
  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") return new Response("expected websocket", { status: 426 })
    const replicaRole = request.headers.get("x-cmux-replica-role")
    if (replicaRole !== null) return this.replicaFetch(request, replicaRole)
    const role = request.headers.get("x-cmux-relay-role")
    const peer = request.headers.get("x-cmux-relay-peer") ?? ""
    const state = this.state()
    if ((role !== "host" && role !== "client") || !/^[0-9a-f]{32}$/.test(peer) || !state) return new Response("forbidden", { status: 403 })
    if (role === "host" && peer !== state.hostPeer) return new Response("forbidden", { status: 403 })
    if (role === "client" && !state.reachable.has(peer)) return new Response("forbidden", { status: 403 })
    const { 0: client, 1: server } = new WebSocketPair()
    const tag = role === "host" ? HOST_TAG : clientTag(peer)
    // One live socket per role and peer: a reconnect replaces the old socket.
    for (const old of this.ctx.getWebSockets(tag)) old.close(4000, "replaced")
    this.ctx.acceptWebSocket(server, [tag])
    const now = this.clock()
    server.serializeAttachment({ role, peer, at: now, seen: now } satisfies Attachment)
    await this.armAlarm()
    // Presence from the first moment: a client knows at once whether its frames can reach the host.
    if (role === "host") this.broadcastHost()
    else sendQuietly(server, JSON.stringify({ t: "relay.host", status: this.hostOnline() ? "online" : "offline" }))
    return new Response(null, { status: 101, webSocket: client })
  }

  /** Records that a frame came from `ws` (at most once per SEEN_GRANULARITY_MS). */
  private touch<T extends { readonly seen?: number }>(ws: WebSocket, a: T): T {
    const now = this.clock()
    if (a.seen !== undefined && now - a.seen < SEEN_GRANULARITY_MS) return a
    const next = { ...a, seen: now }
    try {
      ws.serializeAttachment(next)
    } catch {}
    return next
  }

  /** Tells a relay sender its frame was not forwarded, and why; one notice per reason per window. */
  private dropped(ws: WebSocket, from: Attachment, reason: string, peer: string | undefined): void {
    const key = `${from.role}:${from.peer}:${reason}`
    const now = this.clock()
    const last = this.notices.get(key)
    if (last !== undefined && now - last < DROP_NOTICE_WINDOW_MS) return
    this.notices.set(key, now)
    sendQuietly(ws, JSON.stringify({ t: "relay.dropped", reason, ...(peer ? { peer } : {}) }))
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const attached = ws.deserializeAttachment() as unknown
    if (isReplica(attached)) return this.onReplicaMessage(ws, attached, message)
    const attachment = attached as Attachment | null
    const state = this.state()
    if (!attachment || !state) return
    // Any frame is a sign of life (a text `ping` never gets here: the runtime answers it).
    const from = this.touch(ws, attachment)
    if (typeof message === "string") return
    // Only open sockets count: a closing or vanished one would swallow what is sent to it.
    const connectedClients = new Set(
      this.ctx
        .getWebSockets()
        .filter((s) => s.readyState === WebSocket.READY_STATE_OPEN)
        .map((s) => s.deserializeAttachment() as Attachment | null)
        .filter((a): a is Attachment => a?.role === "client")
        .map((a) => a.peer)
    )
    const endpoint: Endpoint = from.role === "host" ? { role: "host" } : { role: "client", peer: from.peer }
    const hostPeer = Uint8Array.from(state.hostPeer.match(/../g) ?? [], (h) => Number.parseInt(h, 16))
    const r = route({ hostPeer, hostConnected: this.hostOnline(), connectedClients, reachable: state.reachable }, endpoint, new Uint8Array(message))
    if (!r.forward) return this.dropped(ws, from, r.reason, r.peer)
    const targets = this.ctx.getWebSockets(r.to.role === "host" ? HOST_TAG : clientTag(r.to.peer)).filter((s) => s.readyState === WebSocket.READY_STATE_OPEN)
    for (const target of targets) sendQuietly(target, r.bytes)
  }

  private onReplicaMessage(ws: WebSocket, attached: ReplicaAttachment, message: string | ArrayBuffer): void {
    if (attached.principal.expires_at !== undefined && attached.principal.expires_at <= this.clock()) return closeQuietly(ws, 4401, "token expired")
    const wire = this.storedReplica()
    if (!wire) return closeQuietly(ws, 1011, "no replica")
    if (this.replicaDropped()) return closeQuietly(ws, 4403, "replica dropped")
    const a = this.touch(ws, attached)
    if (a.role === "publisher") return wire.isCurrentPublisher(a.id) ? wire.onPublisher(message) : closeQuietly(ws, 4000, "replaced")
    const next = wire.onReader(ws, a, message)
    if (next === a) return
    try {
      ws.serializeAttachment(next)
    } catch {
      closeQuietly(ws, 1011, "subscription state too large")
    }
  }
}
