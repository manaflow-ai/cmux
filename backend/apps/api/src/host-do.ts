import { DurableObject } from "cloudflare:workers"
import type { Env } from "./env.ts"
import { route, type Endpoint } from "./host-relay/route.ts"

interface Attachment {
  readonly role: "host" | "client"
  /** Relay peer id (hex) derived by the Worker from the authenticated principal. */
  readonly peer: string
}

const HOST_TAG = "host"
const clientTag = (peer: string) => `client:${peer}`

/**
 * HostDO: one object per host (plans/cmux-next/transport.md section 6). This first slice is the
 * datagram relay: the host keeps one hibernating WebSocket here, clients of that host connect with
 * their own sockets, and binary relay frames move between them under `route` (peer rewrite,
 * reachability compiled by `TeamDO`, offline ends dropped). Pings are answered by the runtime's
 * auto-response, so an idle host costs no duration. The Worker authenticates every socket (relay
 * ticket from `UserDO`) and passes the derived peer id; frames never choose identity.
 * Not yet: rendezvous storage, wake, presence, cached tails, per-client budgets.
 */
export class HostDO extends DurableObject<Env> {
  private reachable: Set<string> | undefined

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS host_relay (id INTEGER PRIMARY KEY CHECK (id = 1), host_peer TEXT NOT NULL, reachable TEXT NOT NULL)`)
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"))
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
    if (typeof message === "string") return
    const from = ws.deserializeAttachment() as Attachment | null
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
}
