import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import vectors from "../../../cmux-tui/crates/cmux-transport/tests/vectors/relay-hub-frames.json"
import { checkFrame, hubHeader, RELAY_FRAME_HEADER_LEN } from "../src/relay-frame.ts"
import { uuidToBytes } from "../src/team-hub.ts"
import { connect, register, sockOf, token, worker, type Sock } from "./helpers.ts"

// RFD 0142 R6, PROTOCOL.md "Three-way hub": the Mac and the VM upload a session's events to one room; each viewer
// gets the newest (epoch, seq) once. Real HTTP/1.1 WebSocket upgrades on the Worker's own host.

const hex = (text: string): Uint8Array => Uint8Array.from(text.match(/../g) ?? [], (h) => Number.parseInt(h, 16))
const toHex = (bytes: Uint8Array) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")

const ROLE = { mac: 1, vm: 2 } as const
const TO = { viewers: 0, mac: 1, vm: 2 } as const

/** A hub frame: the clear header, then a stand-in for the sealed body (the relay never opens it). */
const hubFrame = (sessionId: string, epoch: number, seq: number, source: "mac" | "vm", to: keyof typeof TO = "viewers", body = [0xb0, 0xd1]) => {
  const head = new Uint8Array(35)
  const view = new DataView(head.buffer)
  head[0] = 1
  head.set(uuidToBytes(sessionId), 1)
  view.setBigUint64(17, BigInt(epoch))
  view.setBigUint64(25, BigInt(seq))
  head[33] = ROLE[source]
  head[34] = TO[to]
  return new Uint8Array([1, 5, ...new Array(16).fill(0xee), ...head, ...body])
}

const seqOf = (frame: Uint8Array) => Number(hubHeader(frame.subarray(RELAY_FRAME_HEADER_LEN))!.seq)
const sourceOf = (frame: Uint8Array) => hubHeader(frame.subarray(RELAY_FRAME_HEADER_LEN))!.source

const join = (tok: string, sessionId: string, deviceId: string, role: string, extra: Record<string, string> = {}) =>
  worker.fetch(`https://api.test/v1/hub/${sessionId}?deviceId=${deviceId}&role=${role}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${tok}`, ...extra } })

const joined = async (tok: string, sessionId: string, deviceId: string, role: string, extra: Record<string, string> = { "Sec-WebSocket-Protocol": "cmux-hub.v1" }): Promise<Sock> => {
  const res = await join(tok, sessionId, deviceId, role, extra)
  expect(res.status, await (res.status === 101 ? Promise.resolve("") : res.text())).toBe(101)
  const s = sockOf(res.webSocket!)
  await s.until((x) => x.frames.some((f) => f.type === "joined"))
  return s
}

const stats = async (s: Sock) => {
  const before = s.frames.filter((f) => f.type === "stats").length
  s.ws.send('{"type":"stats"}')
  await s.until((x) => x.frames.filter((f) => f.type === "stats").length > before)
  const { forwarded, dropped } = s.frames.filter((f) => f.type === "stats").at(-1) as { forwarded: number; dropped: number }
  return { forwarded, dropped }
}

/** A Mac, a VM (registered as kind mac, as the VM's daemon is) and a phone of `user`, all in the room. */
const room = async (user = "alice", team = "team-a") => {
  const tok = await token(user)
  const [mac, vm, phone] = [await register(tok, "mac", team), await register(tok, "mac", team), await register(tok, "phone", team)]
  const sessionId = crypto.randomUUID()
  const viewer = await joined(tok, sessionId, phone, "viewer")
  const m = await joined(tok, sessionId, mac, "mac")
  const v = await joined(tok, sessionId, vm, "vm")
  return { tok, mac, vm, phone, sessionId, viewer, m, v }
}

describe("hub frames: the golden vectors cmux-transport checks too", () => {
  it("reads every valid vector's clear header the way the Rust decoder does", () => {
    const valid = vectors.cases.filter((c) => c.valid === "yes")
    expect(valid.length).toBeGreaterThanOrEqual(4)
    for (const c of valid as unknown as Array<Record<string, string>>) {
      const bytes = hex(c.hex!)
      expect(checkFrame(bytes)).toEqual({ ok: true, kind: "hub" })
      const h = hubHeader(bytes.subarray(RELAY_FRAME_HEADER_LEN))!
      expect(toHex(h.session)).toBe(c.session)
      expect(h.epoch.toString()).toBe(c.epoch)
      expect(h.seq.toString()).toBe(c.seq)
      expect(h.source).toBe(c.source)
      expect(h.to).toBe(c.to)
    }
  })

  it("refuses every invalid vector with the same error", () => {
    const invalid = vectors.cases.filter((c) => c.valid === "no") as unknown as Array<Record<string, string>>
    expect(invalid.length).toBeGreaterThanOrEqual(5)
    for (const c of invalid) expect(checkFrame(hex(c.hex!)), c.name).toEqual({ ok: false, error: c.error })
  })
})

describe("hub: who may join", () => {
  it("admits the owner's devices only, sources only from Mac-kind devices, and validates the request", async () => {
    const tok = await token("alice")
    const mac = await register(tok, "mac", "team-a")
    const phone = await register(tok, "phone", "team-a")
    const sessionId = crypto.randomUUID()
    expect((await worker.fetch(`https://api.test/v1/hub/${sessionId}?deviceId=${mac}&role=mac`, { headers: { Upgrade: "websocket" } })).status).toBe(401)
    expect((await worker.fetch(`https://api.test/v1/hub/${sessionId}?deviceId=${mac}&role=mac`, { headers: { authorization: `Bearer ${tok}` } })).status).toBe(426)
    expect((await join(tok, "nope", mac, "mac")).status).toBe(400)
    expect((await join(tok, sessionId, mac, "boss")).status).toBe(400)
    // A phone views; it is never a source.
    const asSource = await join(tok, sessionId, phone, "vm")
    expect(asSource.status).toBe(403)
    expect(JSON.stringify(await asSource.json())).toContain("not_a_source")
    // Bob shares the team, but these are not his devices; an unregistered id is nobody's.
    const bob = await token("bob")
    expect((await join(bob, sessionId, mac, "viewer")).status).toBe(403)
    expect((await join(tok, sessionId, crypto.randomUUID(), "viewer")).status).toBe(403)
    const a = await joined(tok, sessionId, phone, "viewer")
    expect(a.frames.find((f) => f.type === "joined")).toEqual({ type: "joined", hub: 1, sources: { mac: false, vm: false } })
    const b = await joined(tok, sessionId, mac, "mac")
    await a.until((x) => x.frames.some((f) => f.type === "source" && f.role === "mac" && f.online === true))
    a.ws.close()
    b.ws.close()
  })

  it("the kill switch refuses every join with 503 hub_off", async () => {
    const tok = await token("alice")
    const mac = await register(tok, "mac", "team-a")
    const vars = env as unknown as { HUB_RELAY_MODE?: string }
    vars.HUB_RELAY_MODE = "off"
    try {
      const res = await join(tok, crypto.randomUUID(), mac, "mac")
      expect(res.status).toBe(503)
      expect(JSON.stringify(await res.json())).toContain("hub_off")
    } finally {
      delete vars.HUB_RELAY_MODE
    }
  })
})

describe("hub: the newest copy, once", () => {
  it("forwards each position once from whichever source is ahead and drops the other copy", async () => {
    const { sessionId, viewer, m, v, mac, vm } = await room()
    // Both sources stream seq 1..4; the Mac is ahead for 1 and 2, the VM for 3 and 4.
    m.ws.send(hubFrame(sessionId, 1, 1, "mac"))
    await viewer.until((x) => x.binary.length === 1)
    v.ws.send(hubFrame(sessionId, 1, 1, "vm"))
    m.ws.send(hubFrame(sessionId, 1, 2, "mac"))
    await viewer.until((x) => x.binary.length === 2)
    v.ws.send(hubFrame(sessionId, 1, 2, "vm"))
    v.ws.send(hubFrame(sessionId, 1, 3, "vm"))
    await viewer.until((x) => x.binary.length === 3)
    m.ws.send(hubFrame(sessionId, 1, 3, "mac"))
    v.ws.send(hubFrame(sessionId, 1, 4, "vm"))
    await viewer.until((x) => x.binary.length === 4)
    m.ws.send(hubFrame(sessionId, 1, 4, "mac"))
    expect(await stats(viewer)).toEqual({ forwarded: 4, dropped: 4 })
    expect(viewer.binary.map(seqOf)).toEqual([1, 2, 3, 4])
    expect(viewer.binary.map(sourceOf)).toEqual(["mac", "mac", "vm", "vm"])
    // The peer id is the sender's device, and the rest of the frame is untouched.
    expect(toHex(viewer.binary[0]!.subarray(2, 18))).toBe(toHex(uuidToBytes(mac)))
    expect(toHex(viewer.binary[2]!.subarray(2, 18))).toBe(toHex(uuidToBytes(vm)))
    expect(toHex(viewer.binary[0]!.subarray(18))).toBe(toHex(hubFrame(sessionId, 1, 1, "mac").subarray(18)))
    for (const s of [viewer, m, v]) s.ws.close()
  })

  it("the Mac sleeps mid-turn: the VM's stream continues with no missing event", async () => {
    const { sessionId, viewer, m, v } = await room()
    for (let seq = 1; seq <= 5; seq++) {
      m.ws.send(hubFrame(sessionId, 1, seq, "mac"))
      await viewer.until((x) => x.binary.length === seq)
      v.ws.send(hubFrame(sessionId, 1, seq, "vm"))
    }
    m.ws.close(1001, "sleep")
    await viewer.until((x) => x.frames.some((f) => f.type === "source" && f.role === "mac" && f.online === false))
    for (let seq = 6; seq <= 10; seq++) v.ws.send(hubFrame(sessionId, 1, seq, "vm"))
    await viewer.until((x) => x.binary.length === 10)
    expect(viewer.binary.map(seqOf)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    // A new epoch (the VM took the log over) beats any sequence of the old one.
    v.ws.send(hubFrame(sessionId, 2, 0, "vm"))
    await viewer.until((x) => x.binary.length === 11)
    v.ws.send(hubFrame(sessionId, 1, 99, "vm"))
    expect((await stats(viewer)).dropped).toBe(6)
    for (const s of [viewer, v]) s.ws.close()
  })

  it("every viewer gets the stream, and Mac-to-VM sync crosses between the sources only", async () => {
    const { tok, sessionId, viewer, m, v } = await room()
    const phone2 = await register(tok, "phone", "team-a")
    const second = await joined(tok, sessionId, phone2, "viewer")
    m.ws.send(hubFrame(sessionId, 1, 1, "mac"))
    await viewer.until((x) => x.binary.length === 1)
    await second.until((x) => x.binary.length === 1)
    m.ws.send(hubFrame(sessionId, 7, 7, "mac", "vm", [9, 9]))
    await v.until((x) => x.binary.length === 1)
    expect(toHex(v.binary[0]!.subarray(18))).toBe(toHex(hubFrame(sessionId, 7, 7, "mac", "vm", [9, 9]).subarray(18)))
    v.ws.send(hubFrame(sessionId, 7, 8, "vm", "mac"))
    await m.until((x) => x.binary.length === 1)
    // Sync never reached a viewer and never moved the viewer high-water mark.
    m.ws.send(hubFrame(sessionId, 1, 2, "mac"))
    await viewer.until((x) => x.binary.length === 2)
    expect(second.binary.map(seqOf)).toEqual([1])
    await second.until((x) => x.binary.length === 2)
    for (const s of [viewer, second, m, v]) s.ws.close()
  })

  it("forwards nothing a socket may not say: a viewer's frame, a role it is not, another session, other kinds", async () => {
    const { tok, vm, sessionId, viewer, m, v } = await room()
    viewer.ws.send(hubFrame(sessionId, 1, 1, "mac"))
    await viewer.until((x) => x.frames.some((f) => f.type === "error" && f.code === "bad_hub:viewer"))
    m.ws.send(hubFrame(sessionId, 1, 1, "vm"))
    await m.until((x) => x.frames.some((f) => f.type === "error" && f.code === "bad_hub:role"))
    v.ws.send(hubFrame(crypto.randomUUID(), 1, 1, "vm"))
    await v.until((x) => x.frames.some((f) => f.type === "error" && f.code === "bad_hub:session"))
    const datagrams = new Uint8Array([1, 1, ...new Array(16).fill(0), 0, 1, 7])
    m.ws.send(datagrams)
    await new Promise((r) => setTimeout(r, 100))
    // Notices are rate-limited per socket, so the next refusal is shown on a fresh VM socket (it replaces `v`).
    const v2 = await joined(tok, sessionId, vm, "vm")
    v2.ws.send(hubFrame(sessionId, 1, 1, "vm", "vm"))
    await v2.until((x) => x.frames.some((f) => f.type === "error" && f.code === "bad_frame:bad_hub"))
    // A good frame still crosses afterwards, and it is the only one.
    v2.ws.send(hubFrame(sessionId, 1, 1, "vm"))
    await viewer.until((x) => x.binary.length === 1)
    await new Promise((r) => setTimeout(r, 100))
    expect(viewer.binary.length).toBe(1)
    for (const s of [viewer, m, v2]) s.ws.close()
  })

  it("a source's newer socket replaces its older one without telling the room it left", async () => {
    const { tok, mac, sessionId, viewer, m } = await room()
    const again = await joined(tok, sessionId, mac, "mac")
    await m.until((x) => x.closed)
    expect(m.closeCode).toBe(4000)
    await new Promise((r) => setTimeout(r, 100))
    expect(viewer.frames.filter((f) => f.type === "source" && f.role === "mac" && f.online === false)).toEqual([])
    again.ws.send(hubFrame(sessionId, 1, 1, "mac"))
    await viewer.until((x) => x.binary.length === 1)
    for (const s of [viewer, again]) s.ws.close()
  })
})

describe("hub: lockstep with clients and relays that predate it", () => {
  it("new client, new relay: the hub subprotocol is echoed only when offered", async () => {
    const tok = await token("alice")
    const mac = await register(tok, "mac", "team-a")
    const sessionId = crypto.randomUUID()
    const offered = await join(tok, sessionId, mac, "mac", { "Sec-WebSocket-Protocol": "cmux-hub.v1" })
    expect(offered.status).toBe(101)
    expect(offered.headers.get("sec-websocket-protocol")).toBe("cmux-hub.v1")
    offered.webSocket!.accept()
    offered.webSocket!.close()
    const plain = await join(tok, sessionId, mac, "mac", {})
    expect(plain.status).toBe(101)
    expect(plain.headers.get("sec-websocket-protocol")).toBeNull()
    plain.webSocket!.accept()
    plain.webSocket!.close()
  })

  it("new client, old relay: the two-party LinkRelay answers a hub frame with bad_frame:kind", async () => {
    // The LinkRelay is the relay every earlier Worker has; a hub client that reaches it falls back on this code
    // (cmux_transport::hub::relay_error_means_no_hub).
    const tok = await token("alice")
    const phone = await register(tok, "phone", "team-a")
    const mac = await register(tok, "mac", "team-a")
    const p = await connect(tok, "team-a", phone)
    const m = await connect(tok, "team-a", mac)
    for (const s of [p, m]) await s.until((x) => x.frames.some((f) => f.type === "hello"))
    const sessionId = crypto.randomUUID()
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "wg-init", publicKey: "k", endpoints: [], overlayIP: "10.77.0.2" } })
    await m.until((x) => x.frames.some((f) => f.type === "signal" && f.sessionId === sessionId))
    const res = await worker.fetch(`https://api.test/v1/relay/${sessionId}?deviceId=${phone}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${tok}` } })
    expect(res.status).toBe(101)
    const a = sockOf(res.webSocket!)
    await a.until((x) => x.frames.some((f) => f.type === "joined"))
    a.ws.send(hubFrame(sessionId, 1, 1, "mac"))
    await a.until((x) => x.frames.some((f) => f.type === "error" && f.code === "bad_frame:kind"))
    a.ws.close()
  })

  it("old client, new relay: a client that never asks for the hub keeps the LinkRelay as it was", async () => {
    // An old client sends datagrams to /v1/relay; nothing in the hub changes what it gets.
    const tok = await token("alice")
    const phone = await register(tok, "phone", "team-a")
    const mac = await register(tok, "mac", "team-a")
    const p = await connect(tok, "team-a", phone)
    const m = await connect(tok, "team-a", mac)
    for (const s of [p, m]) await s.until((x) => x.frames.some((f) => f.type === "hello"))
    const sessionId = crypto.randomUUID()
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "wg-init", publicKey: "k", endpoints: [], overlayIP: "10.77.0.2" } })
    await m.until((x) => x.frames.some((f) => f.type === "signal" && f.sessionId === sessionId))
    const open = async (id: string) => {
      const res = await worker.fetch(`https://api.test/v1/relay/${sessionId}?deviceId=${id}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${tok}`, "Sec-WebSocket-Protocol": "cmux-relay.v1" } })
      expect(res.status).toBe(101)
      expect(res.headers.get("sec-websocket-protocol")).toBe("cmux-relay.v1")
      const s = sockOf(res.webSocket!)
      await s.until((x) => x.frames.some((f) => f.type === "joined"))
      return s
    }
    const a = await open(phone)
    const b = await open(mac)
    a.ws.send(new Uint8Array([1, 1, ...new Array(16).fill(0), 0, 3, 4, 0, 0]))
    await b.until((x) => x.binary.length === 1)
    expect(Array.from(b.binary[0]!.subarray(18))).toEqual([0, 3, 4, 0, 0])
    a.ws.close()
    b.ws.close()
  })
})
