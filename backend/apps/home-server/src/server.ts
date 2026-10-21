import type { Server, ServerWebSocket } from "bun"
import type { Principal } from "@cmux/ownership"
import { HibernatingSocket } from "./do-runtime/hibernating-socket.ts"
import type { Router, UpgradeTarget } from "./router.ts"
import type { ServerRuntime } from "./server-env.ts"

/** Per-socket data: which object it belongs to, its Durable Object view, and its frame queue. */
interface SocketData {
  readonly target: UpgradeTarget
  socket?: HibernatingSocket
  /** Frames of one socket run strictly in order, after the accept. */
  chain: Promise<void>
}

type OwnerInstance = {
  acceptSubscriber(ws: HibernatingSocket, entity: string, p: Principal): void
  webSocketMessage(ws: HibernatingSocket, m: string | ArrayBuffer): Promise<void>
  webSocketClose(ws: HibernatingSocket, code: number, reason: string, wasClean: boolean): Promise<void>
}

/**
 * Listens on each address (the host's tailnet addresses and loopback, never another interface):
 * HTTP goes to the router, WebSocket upgrades are admitted into the owning object through the same
 * `acceptSubscriber` path the Worker uses, and frames go to its `webSocketMessage`.
 */
export const listen = (
  addresses: ReadonlyArray<string>,
  port: number,
  router: Router,
  server: ServerRuntime,
  /** The peer address admission checks (tests map a header to a fake tailnet address). */
  peerOf: (request: Request, srv: Server<SocketData>) => string = (request, srv) => srv.requestIP(request)?.address ?? ""
): Array<Server<SocketData>> => {
  const run = (ws: ServerWebSocket<SocketData>, step: (o: OwnerInstance, s: HibernatingSocket) => Promise<void> | void) => {
    ws.data.chain = ws.data.chain
      .then(async () => {
        const o = await server.runtime.object(ws.data.target.binding, ws.data.target.entity)
        if (ws.data.socket) await step(o.instance as unknown as OwnerInstance, ws.data.socket)
      })
      .catch((e) => {
        if (!server.runtime.isStopped) console.error(JSON.stringify({ msg: "socket step failed", error: String(e).slice(0, 300) }))
      })
  }
  return addresses.map((hostname) =>
    Bun.serve<SocketData>({
      hostname,
      port,
      // A socket idles for minutes between frames; clients ping.
      idleTimeout: 255,
      async fetch(request, srv) {
        const peer = peerOf(request, srv)
        const answer = await router.handle(request, peer)
        if (answer instanceof Response) return answer
        const ok = srv.upgrade(request, { data: { target: answer, chain: Promise.resolve() }, headers: { "Sec-WebSocket-Protocol": "cmux.wire.v1" } })
        return ok ? undefined : new Response("upgrade failed", { status: 400 })
      },
      websocket: {
        idleTimeout: 960,
        open(ws) {
          ws.data.socket = new HibernatingSocket({ send: (d) => ws.send(d), close: (c, r) => ws.close(c, r) })
          run(ws, (o, s) => o.acceptSubscriber(s, ws.data.target.entity, ws.data.target.principal))
        },
        message(ws, message) {
          const m = typeof message === "string" ? message : message.buffer.slice(message.byteOffset, message.byteOffset + message.byteLength)
          run(ws, (o, s) => o.webSocketMessage(s, m as string | ArrayBuffer))
        },
        close(ws, code, reason) {
          const s = ws.data.socket
          if (!s) return
          s.markClosed()
          run(ws, async (o) => {
            const live = await server.runtime.object(ws.data.target.binding, ws.data.target.entity)
            live.state.forget(s)
            await o.webSocketClose(s, code, reason, true)
          })
        }
      }
    })
  )
}
