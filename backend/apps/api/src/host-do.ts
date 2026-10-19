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
}

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

/**
 * HostDO: one object per host (plans/cmux-next/transport.md section 6). This first slice is the
 * datagram relay: the host keeps one hibernating WebSocket here, clients of that host connect with
 * their own sockets, and binary relay frames move between them under `route` (peer rewrite,
 * reachability compiled by `TeamDO`, offline ends dropped). Pings are answered by the runtime's
 * auto-response, so an idle host costs no duration. The Worker authenticates every socket (relay
 * ticket from `UserDO`) and passes the derived peer id; frames never choose identity.
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

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS host_relay (id INTEGER PRIMARY KEY CHECK (id = 1), host_peer TEXT NOT NULL, reachable TEXT NOT NULL)`)
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
        now: () => Date.now()
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
    server.serializeAttachment({ role, principal, id, streams: [] } satisfies ReplicaAttachment)
    this.registerSocket(server, principal, host)
    await this.armExpiry()
    if (role === "publisher") wire.publisherOpened(server, id)
    else wire.readerOpened(server, principal)
    return new Response(null, { status: 101, webSocket: client, headers: { "Sec-WebSocket-Protocol": "cmux.wire.v1" } })
  }

  /** Registers an install's socket in its UserDO, so `install.revoke` closes it here at once (socket-registry.ts). */
  private registerSocket(ws: WebSocket, p: ReturnType<typeof replicaPrincipal>, host: string) {
    if (p.kind !== "install" || !p.install || !p.user) return
    const stub = this.env.USER_DO.get(this.env.USER_DO.idFromName(p.user)) as unknown as {
      registerSocket(entity: string, install: string, grant: string | undefined, cls: string, name: string, expiresAt: number, agent?: string): Promise<boolean>
    }
    this.ctx.waitUntil(
      stub.registerSocket(p.user, p.install, p.grant, "HostDO", host, p.expires_at ?? Date.now() + 3600_000, p.agent).then(
        (ok) => (ok ? undefined : closeQuietly(ws, 4401, "install revoked")),
        () => undefined
      )
    )
  }

  /** RPC from UserDO (socket-registry.ts): an install was revoked; close its replica sockets now. */
  async closeInstall(_entity: string, install: string): Promise<boolean> {
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment() as unknown
      if (isReplica(a) && a.principal.install === install) closeQuietly(ws, 4401, "revoked")
    }
    return true
  }

  /** The alarm closes replica sockets whose token expired, then waits for the next expiry. */
  private async armExpiry(): Promise<void> {
    let at: number | null = null
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment() as unknown
      const e = isReplica(a) ? a.principal.expires_at : undefined
      if (typeof e === "number" && (at === null || e < at)) at = e
    }
    const current = await this.ctx.storage.getAlarm()
    if (at !== null && (current === null || at < current)) await this.ctx.storage.setAlarm(Math.max(at, Date.now()))
  }

  override async alarm(): Promise<void> {
    const now = Date.now()
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment() as unknown
      if (isReplica(a) && a.principal.expires_at !== undefined && a.principal.expires_at <= now) closeQuietly(ws, 4401, "token expired")
    }
    await this.armExpiry()
  }

  override async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    this.replicaClosed(ws)
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code, "closing")
    } catch {}
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    this.replicaClosed(ws)
  }

  /** A replica socket went away: the current publisher's close makes the host offline. */
  private replicaClosed(ws: WebSocket): void {
    const a = ws.deserializeAttachment() as unknown
    if (!isReplica(a)) return
    const wire = this.storedReplica()
    if (a.role === "publisher") wire?.publisherClosed(a.id)
    else wire?.readerClosed(a.id)
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
    server.serializeAttachment({ role, peer } satisfies Attachment)
    return new Response(null, { status: 101, webSocket: client })
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const attached = ws.deserializeAttachment() as unknown
    if (isReplica(attached)) return this.onReplicaMessage(ws, attached, message)
    if (typeof message === "string") return
    const from = attached as Attachment | null
    const state = this.state()
    if (!from || !state) return
    const connectedClients = new Set(
      this.ctx
        .getWebSockets()
        .map((s) => s.deserializeAttachment() as Attachment | null)
        .filter((a): a is Attachment => a?.role === "client")
        .map((a) => a.peer)
    )
    const endpoint: Endpoint = from.role === "host" ? { role: "host" } : { role: "client", peer: from.peer }
    const hostPeer = Uint8Array.from(state.hostPeer.match(/../g) ?? [], (h) => Number.parseInt(h, 16))
    const r = route({ hostPeer, hostConnected: this.ctx.getWebSockets(HOST_TAG).length > 0, connectedClients, reachable: state.reachable }, endpoint, new Uint8Array(message))
    if (!r.forward) return
    const targets = this.ctx.getWebSockets(r.to.role === "host" ? HOST_TAG : clientTag(r.to.peer))
    for (const target of targets) {
      try {
        target.send(r.bytes)
      } catch {}
    }
  }

  private onReplicaMessage(ws: WebSocket, a: ReplicaAttachment, message: string | ArrayBuffer): void {
    if (a.principal.expires_at !== undefined && a.principal.expires_at <= Date.now()) return closeQuietly(ws, 4401, "token expired")
    const wire = this.storedReplica()
    if (!wire) return closeQuietly(ws, 1011, "no replica")
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
