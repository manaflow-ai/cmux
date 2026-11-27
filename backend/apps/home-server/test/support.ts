import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import type { Server } from "bun"
import { Admission, type AccessConfig } from "../src/admission.ts"
import { Router } from "../src/router.ts"
import { buildServerRuntime, type ServerRuntime } from "../src/server-env.ts"
import { listen } from "../src/server.ts"
import type { PeerIdentity, Tailnet, TailnetSelf } from "../src/tailscale.ts"

/** Fake tailnet: peer address -> WhoIs answer. */
export class FakeTailnet implements Tailnet {
  constructor(readonly peers: Record<string, PeerIdentity>, readonly me: TailnetSelf = { addresses: ["100.64.0.1"], dns_name: "mini.tail0.ts.net", login: "alice@example.com", tagged: false }) {}
  async whois(address: string): Promise<PeerIdentity> {
    return this.peers[address] ?? { ok: false, code: "unknown_peer" }
  }
  async self() {
    return this.me
  }
}

export const PEERS = {
  alice: "100.64.0.2",
  bob: "100.64.0.3",
  carol: "100.64.0.4",
  tagged: "100.64.0.9",
  self: "100.64.0.1",
  outside: "192.168.1.20"
} as const

export const tailnet = () =>
  new FakeTailnet({
    [PEERS.alice]: { ok: true, login: "alice@example.com", display_name: "Alice Example", node: "alice-mac" },
    [PEERS.bob]: { ok: true, login: "bob@example.com", display_name: "Bob Example", node: "bob-iphone" },
    [PEERS.carol]: { ok: true, login: "carol@example.com", display_name: "Carol Example", node: "carol-mac" },
    [PEERS.tagged]: { ok: false, code: "tagged_node" }
  })

/** One running server on loopback; `x-test-peer` names the fake tailnet address of a request. */
export interface TestServer {
  readonly base: string
  readonly ws: string
  readonly runtime: ServerRuntime
  readonly dataDir: string
  stop(): void
}

export const startServer = (dataDir = mkdtempSync(join(tmpdir(), "cmux-chat-server-")), access: AccessConfig = { owner: "alice@example.com", allow: ["bob@example.com"] }): TestServer => {
  const runtime = buildServerRuntime(dataDir)
  const net = tailnet()
  const admission = new Admission(net, () => access, () => net.me.addresses)
  const router = new Router(runtime, admission, () => ({ server_name: "mini", url: "http://mini.tail0.ts.net:7320" }))
  const [srv] = listen(["127.0.0.1"], 0, router, runtime, (req, s: Server<unknown>) => req.headers.get("x-test-peer") ?? new URL(req.url).searchParams.get("peer") ?? s.requestIP(req)?.address ?? "")
  return {
    base: `http://127.0.0.1:${srv!.port}`,
    ws: `ws://127.0.0.1:${srv!.port}`,
    runtime,
    dataDir,
    stop: () => {
      srv!.stop(true)
      runtime.runtime.stop()
    }
  }
}

/** A person's client: HTTP ops and reads as one tailnet peer. */
export const client = (s: TestServer, peer: string) => {
  const post = async (path: string, body: unknown) => {
    const r = await fetch(`${s.base}${path}`, { method: "POST", headers: { "content-type": "application/json", "x-test-peer": peer }, body: JSON.stringify(body) })
    return { status: r.status, json: (await r.json().catch(() => null)) as any }
  }
  return {
    info: async () => {
      const r = await fetch(`${s.base}/v1/selfhost/info`, { headers: { "x-test-peer": peer } })
      return { status: r.status, json: (await r.json().catch(() => null)) as any }
    },
    op: (op: string, params: unknown, key: string = crypto.randomUUID()) => post("/v1/ops", { op, params, idempotency_key: key, origin: "user" }),
    read: (op: string, params: unknown) => post("/v1/read", { op, params }),
    /** A conversation (or user) socket with a frame inbox. */
    socket: async (path: string) => {
      const frames: Array<any> = []
      const waiters: Array<() => void> = []
      const ws = new WebSocket(`${s.ws}${path}?peer=${peer}`, ["cmux.wire.v1"])
      ws.onmessage = (e) => {
        frames.push(JSON.parse(String(e.data)))
        for (const w of waiters.splice(0)) w()
      }
      await new Promise<void>((resolve, reject) => {
        ws.onopen = () => resolve()
        ws.onerror = () => reject(new Error(`socket ${path} failed`))
      })
      const next = async (match: (f: any) => boolean, timeoutMs = 3000): Promise<any> => {
        const deadline = Date.now() + timeoutMs
        for (;;) {
          const i = frames.findIndex(match)
          if (i >= 0) return frames.splice(i, 1)[0]
          const left = deadline - Date.now()
          if (left <= 0) throw new Error(`no matching frame on ${path}; got ${JSON.stringify(frames).slice(0, 600)}`)
          // A frame arrival wakes the wait; the timeout bounds a test that would otherwise hang.
          await new Promise<void>((r) => {
            const t = setTimeout(r, left)
            waiters.push(() => (clearTimeout(t), r()))
          })
        }
      }
      return { ws, frames, next, send: (f: unknown) => ws.send(JSON.stringify(f)), close: () => ws.close() }
    }
  }
}
