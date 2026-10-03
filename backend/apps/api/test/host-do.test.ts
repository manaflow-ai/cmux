import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"

const ns = (env as unknown as { HOST_DO: DurableObjectNamespace }).HOST_DO
const HOST = "f0e1d2c3b4a5968778695a4b3c2d1e0f"
const ALICE = "00112233445566778899aabbccddeeff"
const MALLORY = "ffeeddccbbaa99887766554433221100"
const hex = (t: string) => Uint8Array.from(t.match(/../g) ?? [], (h) => Number.parseInt(h, 16))
const toHex = (b: ArrayBuffer) => Array.from(new Uint8Array(b), (x) => x.toString(16).padStart(2, "0")).join("")
const datagramFrame = (peer: string) => hex(`0101${peer}0020${"04000000" + "00".repeat(28)}`)

interface Opened {
  readonly status: number
  readonly ws?: WebSocket
  /** Resolves with the next binary message as hex (no polling). */
  next(): Promise<string>
  closed: Promise<number>
}
const open = async (stub: DurableObjectStub, role: string, peer: string): Promise<Opened> => {
  const res = await stub.fetch("https://relay/ws", { headers: { Upgrade: "websocket", "x-cmux-relay-role": role, "x-cmux-relay-peer": peer } })
  const queue: Array<string> = []
  const waiters: Array<(v: string) => void> = []
  let onClose: (code: number) => void = () => {}
  const closed = new Promise<number>((r) => (onClose = r))
  const ws = res.webSocket ?? undefined
  const deliver = (v: string) => {
    const w = waiters.shift()
    if (w) w(v)
    else queue.push(v)
  }
  if (ws) {
    ws.addEventListener("message", (e) => {
      const data = e.data as string | ArrayBuffer | Blob
      if (typeof data === "string") deliver(`text:${data}`)
      else if (data instanceof Blob) void data.arrayBuffer().then((b) => deliver(toHex(b)))
      else deliver(toHex(data))
    })
    ws.addEventListener("close", (e) => onClose(e.code))
    ws.accept()
  }
  return {
    status: res.status,
    ws,
    closed,
    next: () => (queue.length > 0 ? Promise.resolve(queue.shift()!) : new Promise<string>((r) => waiters.push(r)))
  }
}

// The first call creates the object class; on a loaded machine that can take several seconds.
describe("HostDO datagram relay", { timeout: 30_000 }, () => {
  it("relays between a host and a reachable client and rewrites peer ids", async () => {
    const stub = ns.get(ns.idFromName("host-a")) as unknown as DurableObjectStub & { setReachability(h: string, p: Array<string>): Promise<void> }
    await stub.setReachability(HOST, [ALICE])
    const host = await open(stub, "host", HOST)
    const alice = await open(stub, "client", ALICE)
    expect([host.status, alice.status]).toEqual([101, 101])
    alice.ws!.send(datagramFrame(MALLORY).buffer) // claims another id; the relay overwrites it
    expect((await host.next()).slice(4, 36)).toBe(ALICE)
    host.ws!.send(datagramFrame(ALICE).buffer)
    expect((await alice.next()).slice(4, 36)).toBe(HOST)
  })

  it("refuses unreachable clients and wrong host ids, and drops clients that lose reachability", async () => {
    const stub = ns.get(ns.idFromName("host-b")) as unknown as DurableObjectStub & { setReachability(h: string, p: Array<string>): Promise<void> }
    await stub.setReachability(HOST, [ALICE])
    expect((await open(stub, "client", MALLORY)).status).toBe(403)
    expect((await open(stub, "host", ALICE)).status).toBe(403)
    const alice = await open(stub, "client", ALICE)
    await stub.setReachability(HOST, [])
    expect(await alice.closed).toBe(4003)
  })
})
