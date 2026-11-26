import { runInDurableObject } from "cloudflare:test"
import { env } from "cloudflare:workers"
import { describe, expect, it, vi } from "vitest"
import vectors from "../../../cmux-tui/crates/cmux-transport/tests/vectors/relay-frames.json"
import type { Env } from "../src/env.ts"
import type { LinkRelay } from "../src/link-relay.ts"
import { relayRoomName } from "../src/placement.ts"
import { checkFrame } from "../src/relay-frame.ts"
import { linkStatLine, userHubName, uuidToBytes } from "../src/team-hub.ts"
import { connect, register, sockOf, token, worker, type Sock } from "./helpers.ts"

// PROTOCOL.md "WebSocket relay": the last way a WireGuard link reaches its peer, WireGuard datagrams in relay
// frames over a real HTTP/1.1 WebSocket upgrade on the Worker's own host. Only the two devices the owner's hub
// bound to a session at its first signal can join that session's relay, each with the ticket the hub stamped on
// the signals it forwarded to that device's own signaling socket (`relayTicket`).

const hex = (text: string): Uint8Array => Uint8Array.from(text.match(/../g) ?? [], (h) => Number.parseInt(h, 16))
const toHex = (bytes: Uint8Array) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")

/** A `datagrams` frame carrying `datagrams`, with `peer` as the sender wrote it (the relay overwrites it). */
const frame = (datagrams: Uint8Array[], peer = new Uint8Array(16).fill(0xee), kind = 1) => {
  const records = datagrams.flatMap((d) => [d.length >> 8, d.length & 0xff, ...d])
  return new Uint8Array([1, kind, ...peer, ...records])
}

/** Each device's relay ticket per session, as its signaling socket received it (`relayTicket`). */
const tickets = new Map<string, string>()
const TICKET = "x-cmux-relay-ticket"

/** A join as `deviceId`, with that device's own ticket unless `extra` names another (or `null`: none). */
const join = (tok: string, sessionId: string, deviceId: string, extra: Record<string, string | null> = {}) => {
  const headers: Record<string, string> = { Upgrade: "websocket", authorization: `Bearer ${tok}` }
  const own = tickets.get(`${sessionId}|${deviceId}`)
  if (own) headers[TICKET] = own
  for (const [k, v] of Object.entries(extra)) {
    if (v === null) delete headers[k]
    else headers[k] = v
  }
  return worker.fetch(`https://api.test/v1/relay/${sessionId}?deviceId=${deviceId}`, { headers })
}

/** The ticket stamped on the last signal of `sessionId` that `sock` (device `deviceId`) received, recorded. */
const recordTicket = (sock: Sock, sessionId: string, deviceId: string) => {
  const signal = sock.frames.filter((f) => f.type === "signal" && f.sessionId === sessionId).at(-1)
  expect(typeof signal?.relayTicket, JSON.stringify(signal)).toBe("string")
  tickets.set(`${sessionId}|${deviceId}`, signal.relayTicket)
  return signal.relayTicket as string
}

/** The Mac answers the phone's `wg-init` with `wg-resp`; both devices' tickets are then recorded. */
const exchange = async (p: Sock, phone: string, m: Sock, mac: string, sessionId: string) => {
  const macTicket = recordTicket(m, sessionId, mac)
  m.send({ type: "signal", to: phone, from: mac, sessionId, payload: { kind: "wg-resp", publicKey: "k", endpoints: [], overlayIP: "10.77.0.1" } })
  await p.until((x) => x.frames.some((f) => f.type === "signal" && f.sessionId === sessionId && f.payload?.kind === "wg-resp"))
  return { macTicket, phoneTicket: recordTicket(p, sessionId, phone) }
}

const joined = async (tok: string, sessionId: string, deviceId: string, extra: Record<string, string | null> = {}): Promise<Sock> => {
  const res = await join(tok, sessionId, deviceId, extra)
  expect(res.status, await (res.status === 101 ? Promise.resolve("") : res.text())).toBe(101)
  const s = sockOf(res.webSocket!)
  await s.until((x) => x.frames.some((f) => f.type === "joined"))
  return s
}

/** A phone and a Mac of `user`, signaling, with a session the phone opened toward the Mac (its `wg-init`). */
const session = async (user = "alice", team = "team-a") => {
  const tok = await token(user)
  const phone = await register(tok, "phone", team)
  const mac = await register(tok, "mac", team)
  const p = await connect(tok, team, phone)
  const m = await connect(tok, team, mac)
  for (const s of [p, m]) await s.until((x) => x.frames.some((f) => f.type === "hello"))
  const sessionId = crypto.randomUUID()
  p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "wg-init", publicKey: "k", endpoints: [], overlayIP: "10.77.0.2" } })
  await m.until((x) => x.frames.some((f) => f.type === "signal" && f.sessionId === sessionId))
  const { macTicket, phoneTicket } = await exchange(p, phone, m, mac, sessionId)
  return { tok, phone, mac, p, m, sessionId, macTicket, phoneTicket }
}

describe("link relay: who may join", () => {
  it("refuses a join without a token, without an upgrade, or with ids that are not UUIDs", async () => {
    const { tok, phone, sessionId } = await session()
    expect((await worker.fetch(`https://api.test/v1/relay/${sessionId}?deviceId=${phone}`, { headers: { Upgrade: "websocket" } })).status).toBe(401)
    expect((await worker.fetch(`https://api.test/v1/relay/${sessionId}?deviceId=${phone}`, { headers: { authorization: `Bearer ${tok}` } })).status).toBe(426)
    expect((await join(tok, "not-a-uuid", phone)).status).toBe(400)
    expect((await join(tok, sessionId, "nope")).status).toBe(400)
  })

  it("admits only the two devices of the session, of the session's own user", async () => {
    const { tok, phone, mac, sessionId } = await session()
    // A third device of the same user is not a party of this session.
    const other = await register(tok, "phone", "team-a")
    const third = await join(tok, sessionId, other)
    expect(third.status).toBe(403)
    expect(((await third.json()) as any).error?.code ?? "").toMatch(/not_in_session/)
    // Bob shares the team but is another user: the session is not in his hub.
    const bob = await token("bob")
    expect((await join(bob, sessionId, phone)).status).toBe(403)
    expect((await join(bob, sessionId, mac)).status).toBe(403)
    // A session id no signal ever opened.
    expect((await join(tok, crypto.randomUUID(), phone)).status).toBe(403)
    // The parties themselves.
    const a = await joined(tok, sessionId, phone)
    const b = await joined(tok, sessionId, mac)
    a.ws.close()
    b.ws.close()
  })

  it("admits a device only with its own ticket: another device of the same user cannot pass the phone's id", async () => {
    const { tok, phone, mac, sessionId, macTicket, phoneTicket } = await session()
    // The same user's token, the phone's id: without the phone's ticket it is refused, whatever it sends instead.
    for (const ticket of [null, "", "not-a-ticket", macTicket, phoneTicket.slice(0, -2) + (phoneTicket.endsWith("A") ? "BB" : "AA")]) {
      const res = await join(tok, sessionId, phone, { [TICKET]: ticket })
      expect(res.status, `ticket ${ticket}`).toBe(403)
    }
    // A ticket is bound to its device and its session.
    expect((await join(tok, sessionId, mac, { [TICKET]: phoneTicket })).status).toBe(403)
    const other = await session()
    expect((await join(other.tok, other.sessionId, other.phone, { [TICKET]: phoneTicket })).status).toBe(403)
    expect((await join(tok, sessionId, phone)).status).toBe(101)
  })

  it("stamps each device's own ticket on what it receives: distinct per device and per session, and stable", async () => {
    const { phone, mac, p, m, sessionId, macTicket, phoneTicket } = await session()
    expect(macTicket).not.toBe(phoneTicket)
    expect(phoneTicket.length).toBeGreaterThanOrEqual(43)
    // A later signal of the same session carries the same ticket.
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "wg-endpoints", generation: 1, endpoints: [] } })
    await m.until((x) => x.frames.filter((f) => f.type === "signal" && f.sessionId === sessionId).length === 2)
    expect(m.frames.filter((f) => f.type === "signal").at(-1).relayTicket).toBe(macTicket)
    // A client cannot plant a ticket: the hub drops whatever the sender wrote.
    m.send({ type: "signal", to: phone, from: mac, sessionId, relayTicket: "planted", payload: { kind: "wg-relay" } })
    await p.until((x) => x.frames.some((f) => f.type === "signal" && f.payload?.kind === "wg-relay"))
    expect(p.frames.find((f) => f.payload?.kind === "wg-relay").relayTicket).toBe(phoneTicket)
  })

  it("a session ended by bye takes no new joins", async () => {
    const { tok, phone, mac, p, m, sessionId } = await session()
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "bye", reason: "closed" } })
    await m.until((x) => x.frames.some((f) => f.type === "signal" && f.payload?.kind === "bye"))
    expect((await join(tok, sessionId, phone)).status).toBe(403)
  })

  it("a dev build space's session is joined only in that space", async () => {
    const tok = await token("alice")
    const space = { "x-cmux-build-space": "dev:relay-space" }
    const reg = async (kind: "mac" | "phone") => {
      const deviceId = crypto.randomUUID()
      const r = await worker.fetch("https://api.test/v1/devices", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${tok}`, ...space }, body: JSON.stringify({ deviceId, kind, name: kind, teamId: "team-a" }) })
      expect(r.status).toBe(200)
      return deviceId
    }
    const phone = await reg("phone")
    const mac = await reg("mac")
    const open = async (id: string) => {
      const res = await worker.fetch(`https://api.test/v1/teams/team-a/signal?deviceId=${id}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${tok}`, ...space } })
      expect(res.status).toBe(101)
      const s = sockOf(res.webSocket!)
      await s.until((x) => x.frames.some((f) => f.type === "hello"))
      return s
    }
    const p = await open(phone)
    const m = await open(mac)
    const sessionId = crypto.randomUUID()
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "wg-init", publicKey: "k", endpoints: [], overlayIP: "10.77.0.2" } })
    await m.until((x) => x.frames.some((f) => f.type === "signal"))
    await exchange(p, phone, m, mac, sessionId)
    // Without the space the stable hub has no such session.
    expect((await join(tok, sessionId, phone)).status).toBe(403)
    const a = await joined(tok, sessionId, phone, space)
    const b = await joined(tok, sessionId, mac, space)
    a.ws.send(frame([new Uint8Array([4, 0, 0, 0, 9])]))
    await b.until((x) => x.binary.length === 1)
    a.ws.close()
    b.ws.close()
  })

  it("the kill switch refuses every join with 503 relay_off", async () => {
    const { tok, phone, sessionId } = await session()
    const vars = env as unknown as { LINK_RELAY_MODE?: string }
    vars.LINK_RELAY_MODE = "off"
    try {
      const res = await join(tok, sessionId, phone)
      expect(res.status).toBe(503)
      expect(JSON.stringify(await res.json())).toContain("relay_off")
    } finally {
      delete vars.LINK_RELAY_MODE
    }
  })
})

describe("link relay: what it carries", () => {
  it("carries datagram frames both ways, with the peer id set to the sender's device", async () => {
    const { tok, phone, mac, sessionId } = await session()
    const a = await joined(tok, sessionId, phone)
    expect(a.frames.find((f) => f.type === "joined")).toEqual({ type: "joined", peer: false })
    const b = await joined(tok, sessionId, mac, { "Sec-WebSocket-Protocol": "cmux-relay.v1" })
    expect(b.frames.find((f) => f.type === "joined")).toEqual({ type: "joined", peer: true })
    // The phone heard its peer arrive.
    await a.until((x) => x.frames.some((f) => f.type === "peer" && f.online === true))

    const one = new Uint8Array([1, 0, 0, 0, ...new Array(144).fill(0xab)])
    const two = new Uint8Array([4, 0, 0, 0, 7, 7, 7])
    a.ws.send(frame([one, two]))
    await b.until((x) => x.binary.length === 1)
    const got = b.binary[0]!
    // The relay rewrote the peer the phone wrote (0xee...) to the phone's own id, and nothing else.
    expect(toHex(got.subarray(2, 18))).toBe(toHex(uuidToBytes(phone)))
    expect(toHex(got.subarray(18))).toBe(toHex(frame([one, two]).subarray(18)))
    expect([got[0], got[1]]).toEqual([1, 1])

    b.ws.send(frame([two]))
    await a.until((x) => x.binary.length === 1)
    expect(toHex(a.binary[0]!.subarray(2, 18))).toBe(toHex(uuidToBytes(mac)))
    a.ws.close()
    b.ws.close()
  })

  it("says the peer is not there instead of dropping frames without a word, and when it leaves", async () => {
    const { tok, phone, mac, sessionId } = await session()
    const a = await joined(tok, sessionId, phone)
    a.ws.send(frame([new Uint8Array([4, 0, 0, 0, 1])]))
    await a.until((x) => x.frames.some((f) => f.type === "peer" && f.online === false))
    const b = await joined(tok, sessionId, mac)
    await a.until((x) => x.frames.some((f) => f.type === "peer" && f.online === true))
    b.ws.close(1000, "done")
    await a.until((x) => x.frames.filter((f) => f.type === "peer" && f.online === false).length >= 2)
    a.ws.close()
  })

  it("forwards nothing that is not a well-formed datagrams frame", async () => {
    const { tok, phone, mac, sessionId } = await session()
    const a = await joined(tok, sessionId, phone)
    const b = await joined(tok, sessionId, mac)
    // A records list that does not tile, a wake frame, a text frame and a frame too short to have a header.
    const bad = frame([new Uint8Array([1, 2, 3])])
    bad[bad.length - 1] = 0
    a.ws.send(new Uint8Array([...bad.subarray(0, 18), 0, 9, 1]))
    a.ws.send(frame([new Uint8Array([1])], undefined, 3))
    a.ws.send("hello")
    a.ws.send(new Uint8Array([1, 1, 0]))
    await a.until((x) => x.frames.some((f) => f.type === "error" && String(f.code).startsWith("bad_frame")))
    // A good frame after them still crosses, and it is the only one that did.
    a.ws.send(frame([new Uint8Array([4, 0, 0, 0, 5])]))
    await b.until((x) => x.binary.length === 1)
    await new Promise((r) => setTimeout(r, 100))
    expect(b.binary.length).toBe(1)
    a.ws.close()
    b.ws.close()
  })

  it("a device's newer socket replaces its older one, and the peer is not told it left", async () => {
    const { tok, phone, mac, sessionId } = await session()
    const b = await joined(tok, sessionId, mac)
    const first = await joined(tok, sessionId, phone)
    const second = await joined(tok, sessionId, phone)
    await first.until((x) => x.closed)
    expect(first.closeCode).toBe(4000)
    await new Promise((r) => setTimeout(r, 100))
    expect(b.frames.filter((f) => f.type === "peer" && f.online === false)).toEqual([])
    b.ws.send(frame([new Uint8Array([4, 0, 0, 0, 2])]))
    await second.until((x) => x.binary.length === 1)
    expect(first.binary.length).toBe(0)
    second.ws.close()
    b.ws.close()
  })

  it("answers the application ping without a frame of its own", async () => {
    const { tok, phone, sessionId } = await session()
    const a = await joined(tok, sessionId, phone)
    const pong = new Promise<string>((resolve) => a.ws.addEventListener("message", (e) => typeof e.data === "string" && e.data === "pong" && resolve(e.data)))
    a.ws.send("ping")
    expect(await pong).toBe("pong")
    a.ws.close()
  })
})

describe("link relay: tail replay on a rejoin (RFD 0142 R3)", () => {
  const dg = (n: number) => new Uint8Array([4, 0, 0, 0, n])
  /** The datagram bytes of a relayed frame (after its 18-byte header), as hex. */
  const body = (b: Uint8Array) => toHex(b.subarray(18))

  it("what went to the phone's old socket in the last second goes out again on its new one, oldest first, then live frames", async () => {
    const { tok, phone, mac, sessionId } = await session()
    const m = await joined(tok, sessionId, mac)
    const old = await joined(tok, sessionId, phone)
    // The Mac sends while the phone's old network is going away: the old socket is still open, so they are
    // "delivered" into it and lost there.
    m.ws.send(frame([dg(1)]))
    m.ws.send(frame([dg(2)]))
    await old.until((x) => x.binary.length === 2)
    // The phone is back on a new network: its new socket replaces the old.
    const fresh = await joined(tok, sessionId, phone)
    await fresh.until((x) => x.binary.length === 2)
    expect(fresh.binary.map(body)).toEqual([body(frame([dg(1)])), body(frame([dg(2)]))])
    // Stamped with the sender, as live frames are.
    expect(toHex(fresh.binary[0]!.subarray(2, 18))).toBe(toHex(uuidToBytes(mac)))
    m.ws.send(frame([dg(3)]))
    await fresh.until((x) => x.binary.length === 3)
    expect(body(fresh.binary[2]!)).toBe(body(frame([dg(3)])))
    // A second rejoin replays nothing already replayed (only what was sent since).
    const third = await joined(tok, sessionId, phone)
    await third.until((x) => x.binary.length === 1)
    await new Promise((r) => setTimeout(r, 100))
    expect(third.binary.map(body)).toEqual([body(frame([dg(3)]))])
    third.ws.close()
    m.ws.close()
  })

  it("what the Mac sent while the phone had no socket reaches the phone when it joins", async () => {
    const { tok, phone, mac, sessionId } = await session()
    const m = await joined(tok, sessionId, mac)
    const p = await joined(tok, sessionId, phone)
    p.ws.close(1000, "network gone")
    await m.until((x) => x.frames.some((f) => f.type === "peer" && f.online === false))
    m.ws.send(frame([dg(7)]))
    await m.until((x) => x.frames.filter((f) => f.type === "peer" && f.online === false).length >= 1)
    const back = await joined(tok, sessionId, phone)
    await back.until((x) => x.binary.length === 1)
    expect(body(back.binary[0]!)).toBe(body(frame([dg(7)])))
    back.ws.close()
    m.ws.close()
  })

  it("replays only the last second, and only toward the device that rejoined", async () => {
    const { tok, phone, mac, sessionId } = await session()
    const m = await joined(tok, sessionId, mac)
    const p = await joined(tok, sessionId, phone)
    m.ws.send(frame([dg(1)]))
    p.ws.send(frame([dg(9)]))
    await p.until((x) => x.binary.length === 1)
    await m.until((x) => x.binary.length === 1)
    await new Promise((r) => setTimeout(r, 1100))
    m.ws.send(frame([dg(2)]))
    await p.until((x) => x.binary.length === 2)
    const back = await joined(tok, sessionId, phone)
    await back.until((x) => x.binary.length === 1)
    await new Promise((r) => setTimeout(r, 100))
    // dg(1) is older than a second; dg(9) went the other way.
    expect(back.binary.map(body)).toEqual([body(frame([dg(2)]))])
    back.ws.close()
    m.ws.close()
  })

  it("LINK_RELAY_TAIL=off keeps nothing and replays nothing", async () => {
    const { tok, phone, mac, sessionId } = await session()
    const vars = env as unknown as { LINK_RELAY_TAIL?: string }
    vars.LINK_RELAY_TAIL = "off"
    try {
      const m = await joined(tok, sessionId, mac)
      const p = await joined(tok, sessionId, phone)
      m.ws.send(frame([dg(1)]))
      await p.until((x) => x.binary.length === 1)
      const back = await joined(tok, sessionId, phone)
      await new Promise((r) => setTimeout(r, 200))
      expect(back.binary.length).toBe(0)
      back.ws.close()
      m.ws.close()
    } finally {
      delete vars.LINK_RELAY_TAIL
    }
  })
})

describe("link relay: live sockets end with their session", () => {
  const closedWith = async (s: Sock, code: number) => {
    await s.until((x) => x.closed)
    expect(s.closeCode).toBe(code)
  }

  it("bye closes both live sockets of the session (4001), and nothing crosses after it", async () => {
    const { tok, phone, mac, p, m, sessionId } = await session()
    const a = await joined(tok, sessionId, phone)
    const b = await joined(tok, sessionId, mac)
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "bye", reason: "closed" } })
    await closedWith(a, 4001)
    await closedWith(b, 4001)
    await m.until((x) => x.frames.some((f) => f.payload?.kind === "bye"))
    expect((await join(tok, sessionId, phone)).status).toBe(403)
  })

  it("removing a device closes the live sockets of its sessions (4002)", async () => {
    const { tok, phone, mac, sessionId } = await session()
    const a = await joined(tok, sessionId, phone)
    const b = await joined(tok, sessionId, mac)
    const removed = await worker.fetch(`https://api.test/v1/devices/${phone}`, { method: "DELETE", headers: { authorization: `Bearer ${tok}` } })
    expect(removed.status).toBe(200)
    await closedWith(a, 4002)
    await closedWith(b, 4002)
  })

  it("the kill switch closes live sockets at their next frame (4003), not only new joins", async () => {
    const { tok, phone, mac, sessionId } = await session()
    const a = await joined(tok, sessionId, phone)
    const b = await joined(tok, sessionId, mac)
    a.ws.send(frame([new Uint8Array([4, 0, 0, 0, 1])]))
    await b.until((x) => x.binary.length === 1)
    const vars = env as unknown as { LINK_RELAY_MODE?: string }
    vars.LINK_RELAY_MODE = "off"
    try {
      a.ws.send(frame([new Uint8Array([4, 0, 0, 0, 2])]))
      await closedWith(a, 4003)
      await closedWith(b, 4003)
      expect(b.binary.length).toBe(1)
    } finally {
      delete vars.LINK_RELAY_MODE
    }
  })
})

describe("link relay: a per-user byte budget", () => {
  // vitest.config.ts sets LINK_RELAY_USER_MIB_PER_MIN to 2 for the tests (production: 480).
  const big = () => frame([new Uint8Array(16380).fill(7)])

  it("caps what one user relays per minute across its sessions, and says so; another user is unaffected", async () => {
    const carol = await session("carol", "team-c")
    const a = await joined(carol.tok, carol.sessionId, carol.phone)
    const b = await joined(carol.tok, carol.sessionId, carol.mac)
    for (let i = 0; i < 200; i++) a.ws.send(big())
    await a.until((x) => x.frames.some((f) => f.type === "error" && f.code === "rate_limited"))
    await new Promise((r) => setTimeout(r, 300))
    // About 2 MiB of the 3.2 MiB sent got through: grants of 64 KiB doubling to 1 MiB, until the budget ran out.
    expect(b.binary.length).toBeGreaterThanOrEqual(100)
    expect(b.binary.length).toBeLessThanOrEqual(140)
    // The budget is the user's, not the session's: a second session of the same user is held too.
    const again = await session("carol", "team-c")
    const c = await joined(carol.tok, again.sessionId, again.phone)
    const d = await joined(carol.tok, again.sessionId, again.mac)
    for (let i = 0; i < 80; i++) c.ws.send(big())
    await c.until((x) => x.frames.some((f) => f.type === "error" && f.code === "rate_limited"))
    await new Promise((r) => setTimeout(r, 200))
    expect(d.binary.length).toBeLessThan(80)
    // Another user's relay goes on.
    const dave = await session("dave", "team-c")
    const e = await joined(dave.tok, dave.sessionId, dave.phone)
    const f = await joined(dave.tok, dave.sessionId, dave.mac)
    for (let i = 0; i < 20; i++) e.ws.send(big())
    await f.until((x) => x.binary.length === 20)
    for (const sock of [a, b, c, d, e, f]) sock.ws.close()
  })
})

describe("link relay: the budget holds under load and when the hub fails", () => {
  const big = () => frame([new Uint8Array(16380).fill(7)])
  /** The hub's count of budget calls for `user` (primary project: the owner key is the user id). */
  const hubs = (env as unknown as Env).TEAM_HUB
  const budgetCalls = (user: string) => hubs.get(hubs.idFromName(userHubName(user))).relayBudgetCalls({ ownerKey: user, space: "" })

  it("over budget, frames are dropped without asking the hub for each one", async () => {
    const erin = await session("erin", "team-e")
    const a = await joined(erin.tok, erin.sessionId, erin.phone)
    const b = await joined(erin.tok, erin.sessionId, erin.mac)
    for (let i = 0; i < 200; i++) a.ws.send(big())
    await a.until((x) => x.frames.some((f) => f.type === "error" && f.code === "rate_limited"))
    await new Promise((r) => setTimeout(r, 300))
    const delivered = b.binary.length
    const before = await budgetCalls("erin")
    for (let i = 0; i < 100; i++) a.ws.send(big())
    await new Promise((r) => setTimeout(r, 500))
    // Only what the bucket refilled crosses (2 MiB/min: well under 128 KiB in this second), not the 1.6 MiB sent.
    expect(b.binary.length - delivered).toBeLessThanOrEqual(8)
    // Review of #53240: 100 frames past the budget made 100 hub calls.
    expect((await budgetCalls("erin")) - before).toBeLessThanOrEqual(3)
    a.ws.close()
    b.ws.close()
  })

  it("a hub that fails grants nothing: no frames cross, and it is not asked per frame", async () => {
    const vars = env as unknown as { LINK_RELAY_TEST_BUDGET_ERROR?: string }
    const m = await session("mallory", "team-m")
    const a = await joined(m.tok, m.sessionId, m.phone)
    const b = await joined(m.tok, m.sessionId, m.mac)
    vars.LINK_RELAY_TEST_BUDGET_ERROR = "1"
    try {
      const before = await budgetCalls("mallory")
      for (let i = 0; i < 100; i++) a.ws.send(big())
      await a.until((x) => x.frames.some((f) => f.type === "error" && f.code === "rate_limited"))
      await new Promise((r) => setTimeout(r, 300))
      // Review of #53240: an erroring hub let 1.6 MiB cross a spent budget.
      expect(b.binary.length).toBe(0)
      expect((await budgetCalls("mallory")) - before).toBeLessThanOrEqual(2)
    } finally {
      delete vars.LINK_RELAY_TEST_BUDGET_ERROR
    }
    // The hub answers again: after its backoff the relay carries frames again.
    await new Promise((r) => setTimeout(r, 1200))
    a.ws.send(frame([new Uint8Array([4, 0, 0, 0, 1])]))
    await b.until((x) => x.binary.length === 1)
    a.ws.close()
    b.ws.close()
  })
})

describe("link relay: sockets end with every way a session ends", () => {
  const closedWith = async (s: Sock, code: number) => {
    await s.until((x) => x.closed)
    expect(s.closeCode).toBe(code)
  }

  it("a session pruned past its 24 h closes its relay, and a later device delete leaves nothing relaying", async () => {
    const { tok, phone, mac, p, sessionId } = await session("uma", "team-u")
    const a = await joined(tok, sessionId, phone)
    const b = await joined(tok, sessionId, mac)
    a.ws.send(frame([new Uint8Array([4, 0, 0, 0, 1])]))
    await b.until((x) => x.binary.length === 1)
    vi.useFakeTimers({ toFake: ["Date"], now: Date.now() + 25 * 3600_000, shouldAdvanceTime: true })
    try {
      // A newer session prunes the expired one (review of #53240: its relay stayed open).
      const newer = crypto.randomUUID()
      p.send({ type: "signal", to: mac, from: phone, sessionId: newer, payload: { kind: "wg-init", publicKey: "k", endpoints: [], overlayIP: "10.77.0.2" } })
      await closedWith(a, 4001)
      await closedWith(b, 4001)
      const removed = await worker.fetch(`https://api.test/v1/devices/${phone}`, { method: "DELETE", headers: { authorization: `Bearer ${await token("uma")}` } })
      expect(removed.status).toBe(200)
    } finally {
      vi.useRealTimers()
    }
    expect(b.binary.length).toBe(1)
    expect((await join(tok, sessionId, phone)).status).toBe(403)
  })

  it("bye ends the session and its relay even when the peer's signaling socket is closed", async () => {
    const { tok, phone, mac, p, m, sessionId } = await session()
    const a = await joined(tok, sessionId, phone)
    const b = await joined(tok, sessionId, mac)
    m.ws.close(1000, "mac asleep")
    await new Promise((r) => setTimeout(r, 100))
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "bye", reason: "closed" } })
    await closedWith(a, 4001)
    await closedWith(b, 4001)
  })

  it("deleting the account closes the relay sockets (4002)", async () => {
    const { tok, phone, mac, sessionId } = await session("vic", "team-u")
    const a = await joined(tok, sessionId, phone)
    const b = await joined(tok, sessionId, mac)
    const gone = await worker.fetch("https://api.test/v1/me", { method: "DELETE", headers: { authorization: `Bearer ${tok}` } })
    expect(gone.status).toBe(200)
    await closedWith(a, 4002)
    await closedWith(b, 4002)
  })
})

describe("link relay: malformed requests", () => {
  it("answers a malformed % escape in the path with 400, here and on team routes", async () => {
    const { tok, phone } = await session()
    const relay = await worker.fetch(`https://api.test/v1/relay/%zz?deviceId=${phone}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${tok}` } })
    expect(relay.status).toBe(400)
    expect(JSON.stringify(await relay.json())).toContain("bad_request")
    const team = await worker.fetch("https://api.test/v1/teams/%E0%A4%A/macs", { headers: { authorization: `Bearer ${tok}` } })
    expect(team.status).toBe(400)
    const device = await worker.fetch("https://api.test/v1/devices/%zz", { method: "DELETE", headers: { authorization: `Bearer ${tok}` } })
    expect(device.status).toBe(400)
  })
})

describe("link relay: signaling and stats", () => {
  it("forwards wg-relay, the ask to join, between the session's two devices only", async () => {
    const { tok, phone, mac, p, m, sessionId } = await session()
    m.send({ type: "signal", to: phone, from: mac, sessionId, payload: { kind: "wg-relay" } })
    await p.until((x) => x.frames.some((f) => f.type === "signal" && f.payload?.kind === "wg-relay"))
    expect(p.frames.find((f) => f.payload?.kind === "wg-relay")).toMatchObject({ from: mac, sessionId, fromUserId: "alice" })
    // Not to a device outside the session.
    const other = await register(tok, "phone", "team-a")
    m.send({ type: "signal", to: other, from: mac, sessionId, payload: { kind: "wg-relay" } })
    await m.until((x) => x.frames.some((f) => f.type === "error" && f.sessionId === sessionId))
    expect(m.frames.find((f) => f.type === "error")).toMatchObject({ code: "not_owner" })
  })

  it("logs a link that rides the relay as path https-relay", () => {
    const line = linkStatLine({ type: "link_stat", v: 1, transport: "wireguard", path: "https-relay", reason: "first", pings: 1, lost: 0 }, "phone", undefined, null)
    expect(line).toMatchObject({ path: "https-relay" })
  })
})

describe("relay frame (shared golden vectors with cmux-transport)", () => {
  interface Case {
    readonly name: string
    readonly valid: "yes" | "no"
    readonly hex: string
    readonly kind?: string
    readonly error?: string
  }
  const cases = (vectors as { cases: ReadonlyArray<Case> }).cases

  it("accepts every valid vector with its kind and refuses every invalid one with the expected error", () => {
    expect(cases.filter((c) => c.valid === "yes").length).toBeGreaterThanOrEqual(3)
    for (const c of cases) {
      const checked = checkFrame(hex(c.hex))
      if (c.valid === "yes") expect(checked, c.name).toEqual({ ok: true, kind: c.kind })
      else expect(checked, c.name).toEqual({ ok: false, error: c.error })
    }
  })
})

describe("netcheck targets (PROTOCOL.md \"Relay placement\")", () => {
  const probe = (tok: string | null, region: string, upgrade = true) =>
    worker.fetch(`https://api.test/v1/netcheck/${region}`, { headers: { ...(upgrade ? { Upgrade: "websocket" } : {}), ...(tok ? { authorization: `Bearer ${tok}` } : {}) } })

  it("answers ping with pong, per region, and refuses the rest", async () => {
    const tok = await token("alice")
    expect((await probe(null, "wnam")).status).toBe(401)
    expect((await probe(tok, "wnam", false)).status).toBe(426)
    expect((await probe(tok, "mars")).status).toBe(404)
    const res = await probe(tok, "weur")
    expect(res.status).toBe(101)
    const ws = res.webSocket!
    const got: string[] = []
    ws.accept()
    ws.addEventListener("message", (e) => got.push(String(e.data)))
    ws.send("ping")
    for (let i = 0; i < 50 && !got.length; i++) await new Promise((r) => setTimeout(r, 10))
    expect(got).toEqual(["pong"])
    // Anything but a ping closes it: a netcheck socket never carries relay frames.
    const closed = new Promise<number>((r) => ws.addEventListener("close", (e) => r(e.code)))
    ws.send(new Uint8Array([1, 1, ...new Uint8Array(16)]))
    expect(await closed).toBe(1008)
  })
})

// RFD 0142 R8, PROTOCOL.md "Relay-held sends": a sealed send to a Mac that is not joined is acked by the relay at
// once, held, and handed to the Mac when it joins; the Mac's ack deletes it. Off unless LINK_RELAY_HOLD=on.
describe("link relay: relay-held send queue (R8)", () => {
  const vars = env as unknown as { LINK_RELAY_HOLD?: string }
  const sealed = (n: number) => btoa(`sealed-${n}-${"x".repeat(40)}`).replace(/\+/g, "-").replace(/\//g, "_")
  const withHold = async (fn: () => Promise<void>) => {
    vars.LINK_RELAY_HOLD = "on"
    try {
      await fn()
    } finally {
      delete vars.LINK_RELAY_HOLD
    }
  }
  const answers = (s: Sock, id: string) => s.frames.filter((f) => (f.type === "held" || f.type === "hold_refused") && f.id === id)
  const itemsFor = (s: Sock, id: string) => s.frames.filter((f) => f.type === "held_item" && f.id === id)

  it("is off by default: a hold is refused with off and nothing is kept", async () => {
    const { tok, phone, mac, sessionId } = await session()
    const p = await joined(tok, sessionId, phone)
    const id = crypto.randomUUID()
    p.send({ type: "hold", id, sealed: sealed(1) })
    await p.until((s) => answers(s, id).length === 1)
    expect(answers(p, id)[0]).toMatchObject({ type: "hold_refused", code: "off" })
    const m = await joined(tok, sessionId, mac)
    await new Promise((r) => setTimeout(r, 100))
    expect(m.frames.some((f) => f.type === "held_item")).toBe(false)
  })

  it("acks while the Mac is away, delivers on its join, and the Mac's ack deletes it and tells the phone", async () =>
    withHold(async () => {
      const { tok, phone, mac, sessionId } = await session()
      const p = await joined(tok, sessionId, phone)
      const id = crypto.randomUUID()
      const t0 = Date.now()
      p.send({ type: "hold", id, sealed: sealed(1) })
      await p.until((s) => answers(s, id).length === 1)
      const acked = Date.now() - t0
      expect(answers(p, id)[0]).toMatchObject({ type: "held", depth: 1 })
      // The same id again (a lost ack, a retry): the first answer, nothing new held.
      p.send({ type: "hold", id: id.toUpperCase(), sealed: sealed(1) })
      await p.until((s) => answers(s, id).length === 2)
      expect(answers(p, id)[1]).toMatchObject({ type: "held", depth: 1, expiresAt: answers(p, id)[0].expiresAt })
      const m = await joined(tok, sessionId, mac)
      await m.until((s) => itemsFor(s, id).length === 1)
      // The relay hands over only what it was given: the sealed bytes, the sender's id, times.
      expect(Object.keys(itemsFor(m, id)[0]).sort()).toEqual(["at", "expiresAt", "from", "id", "sealed", "type"])
      expect(itemsFor(m, id)[0]).toMatchObject({ from: phone, sealed: sealed(1) })
      m.send({ type: "held_ack", id })
      await p.until((s) => s.frames.some((f) => f.type === "delivered" && f.id === id))
      // A rejoin gets nothing more; a late retry of the same id is answered delivered and not held again.
      m.ws.close()
      const m2 = await joined(tok, sessionId, mac)
      p.send({ type: "hold", id, sealed: sealed(1) })
      await p.until((s) => answers(s, id).length === 3)
      expect(answers(p, id)[2]).toMatchObject({ type: "held", delivered: true })
      await new Promise((r) => setTimeout(r, 100))
      expect(itemsFor(m2, id)).toHaveLength(0)
      console.log(JSON.stringify({ row: "relay-hold accept", ms: acked }))
    }))

  it("hands a hold to a joined Mac at once, and refuses bad ids and a full queue", async () =>
    withHold(async () => {
      const { tok, phone, mac, sessionId } = await session()
      const p = await joined(tok, sessionId, phone)
      const m = await joined(tok, sessionId, mac)
      const id = crypto.randomUUID()
      p.send({ type: "hold", id, sealed: sealed(2) })
      await m.until((s) => itemsFor(s, id).length === 1)
      p.send({ type: "hold", id: "nope", sealed: sealed(3) })
      await p.until((s) => s.frames.some((f) => f.type === "hold_refused" && f.code === "bad"))
      m.ws.close()
      const ids = Array.from({ length: 64 }, () => crypto.randomUUID())
      for (const [i, x] of ids.entries()) p.send({ type: "hold", id: x, sealed: sealed(i) })
      await p.until((s) => ids.every((x) => answers(s, x).length === 1))
      // 64 per session: the first item still counts, so the last one is refused full.
      expect(answers(p, ids.at(-1)!)[0]).toMatchObject({ type: "hold_refused", code: "full" })
      expect(ids.slice(0, 63).every((x) => answers(p, x)[0].type === "held")).toBe(true)
    }))

  it("kill and wake, 100 runs: 0 lost, and nothing redelivered after the Mac's ack", { timeout: 180_000 }, async () =>
    withHold(async () => {
      const { tok, phone, mac, sessionId } = await session()
      let p = await joined(tok, sessionId, phone)
      const applied = new Map<string, number>()
      let redelivered = 0
      let lost = 0
      const t0 = Date.now()
      for (let run = 0; run < 100; run++) {
        const id = crypto.randomUUID()
        // The Mac is unreachable at send. Every 4th run the phone dies after sending and redials, then retries.
        p.send({ type: "hold", id, sealed: sealed(run) })
        if (run % 4 === 1) {
          p.ws.close()
          p = await joined(tok, sessionId, phone)
          p.send({ type: "hold", id, sealed: sealed(run) })
        }
        await p.until((s) => answers(s, id).length >= 1)
        // The Mac wakes. Every 3rd run it dies after applying and before its ack, and wakes again.
        let m = await joined(tok, sessionId, mac)
        await m.until((s) => itemsFor(s, id).length >= 1)
        // The Mac side applies an id once (cmux_mobile_link::relay_hold::HeldInbox); count every hand-over.
        applied.set(id, (applied.get(id) ?? 0) + 1)
        if (run % 3 === 2) {
          m.ws.close()
          m = await joined(tok, sessionId, mac)
          await m.until((s) => itemsFor(s, id).length >= 1)
          applied.set(id, (applied.get(id) ?? 0) + 1)
        }
        m.send({ type: "held_ack", id })
        await p.until((s) => s.frames.some((f) => f.type === "delivered" && f.id === id))
        m.ws.close()
        const after = await joined(tok, sessionId, mac)
        await new Promise((r) => setTimeout(r, 20))
        redelivered += itemsFor(after, id).length
        after.ws.close()
      }
      for (const n of applied.values()) if (n < 1) lost += 1
      lost += 100 - applied.size
      const killWakes = [...applied.values()].filter((n) => n > 1).length
      console.log(JSON.stringify({ row: "relay-hold kill-and-wake", runs: 100, lost, redeliveredAfterAck: redelivered, macKilledBeforeAck: killWakes, ms: Date.now() - t0 }))
      expect(lost).toBe(0)
      expect(redelivered).toBe(0)
      expect(killWakes).toBe(33)
    }))
})

describe("relay prewarm (RFD 0142 C4, PROTOCOL.md \"Relay placement\")", () => {
  /** The session's relay, named as the Worker's relay route names it (dev is the primary project: no prefix). */
  const relays = (env as unknown as Env).LINK_RELAY
  const relayOf = (owner: string, sessionId: string, space = "") => relays.get(relays.idFromName(relayRoomName(owner, space, sessionId)))
  const prewarmedAt = (owner: string, sessionId: string, space = "") => runInDurableObject(relayOf(owner, sessionId, space), (r: LinkRelay) => r.prewarmedAt)
  const until = async (f: () => Promise<boolean>) => {
    for (let i = 0; i < 100; i++) {
      if (await f()) return true
      await new Promise((r) => setTimeout(r, 10))
    }
    return false
  }

  it("the hub creates the session's relay when it forwards the first wg-init, before anyone joins", async () => {
    const { tok, phone, mac, sessionId } = await session()
    expect(await until(async () => (await prewarmedAt("alice", sessionId)) !== undefined)).toBe(true)
    // A client that knows nothing of it joins and talks exactly as before.
    const a = await joined(tok, sessionId, phone)
    expect(a.frames.find((f) => f.type === "joined")).toEqual({ type: "joined", peer: false })
    const b = await joined(tok, sessionId, mac)
    expect(b.frames.find((f) => f.type === "joined")).toEqual({ type: "joined", peer: true })
    a.ws.send(frame([new Uint8Array([4, 0, 0, 0, 1])]))
    await b.until((x) => x.binary.length === 1)
    a.ws.close()
    b.ws.close()
  })

  it("prewarms once per session, not on other signals, and not with the kill switch", async () => {
    const { phone, mac, p, m, sessionId } = await session()
    expect(await until(async () => (await prewarmedAt("alice", sessionId)) !== undefined)).toBe(true)
    const first = await prewarmedAt("alice", sessionId)
    await new Promise((r) => setTimeout(r, 5))
    // A retried wg-init of the same session does not prewarm again.
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "wg-init", publicKey: "k", endpoints: [], overlayIP: "10.77.0.2" } })
    await m.until((x) => x.frames.filter((f) => f.type === "signal" && f.sessionId === sessionId).length === 2)
    await new Promise((r) => setTimeout(r, 50))
    expect(await prewarmedAt("alice", sessionId)).toBe(first)
    // A WebRTC session never rides the relay: no prewarm.
    const rtc = crypto.randomUUID()
    p.send({ type: "signal", to: mac, from: phone, sessionId: rtc, payload: { kind: "webrtc-offer", sdp: "v=0" } })
    await m.until((x) => x.frames.some((f) => f.type === "signal" && f.sessionId === rtc))
    await new Promise((r) => setTimeout(r, 50))
    expect(await prewarmedAt("alice", rtc)).toBeUndefined()
    // The relay's kill switch: no prewarm either.
    const vars = env as unknown as { LINK_RELAY_MODE?: string }
    vars.LINK_RELAY_MODE = "off"
    try {
      const off = crypto.randomUUID()
      p.send({ type: "signal", to: mac, from: phone, sessionId: off, payload: { kind: "wg-init", publicKey: "k", endpoints: [], overlayIP: "10.77.0.2" } })
      await m.until((x) => x.frames.some((f) => f.type === "signal" && f.sessionId === off))
      await new Promise((r) => setTimeout(r, 50))
      expect(await prewarmedAt("alice", off)).toBeUndefined()
    } finally {
      delete vars.LINK_RELAY_MODE
    }
  })

  it("names the relay as the route does in a dev build space, and the join lands on the prewarmed object", async () => {
    const tok = await token("alice")
    const spaceName = "dev:relay-prewarm"
    const space = { "x-cmux-build-space": spaceName }
    const reg = async (kind: "mac" | "phone") => {
      const deviceId = crypto.randomUUID()
      const r = await worker.fetch("https://api.test/v1/devices", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${tok}`, ...space }, body: JSON.stringify({ deviceId, kind, name: kind, teamId: "team-a" }) })
      expect(r.status).toBe(200)
      return deviceId
    }
    const phone = await reg("phone")
    const mac = await reg("mac")
    const open = async (id: string) => {
      const res = await worker.fetch(`https://api.test/v1/teams/team-a/signal?deviceId=${id}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${tok}`, ...space } })
      expect(res.status).toBe(101)
      const s = sockOf(res.webSocket!)
      await s.until((x) => x.frames.some((f) => f.type === "hello"))
      return s
    }
    const p = await open(phone)
    const m = await open(mac)
    const sessionId = crypto.randomUUID()
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "wg-init", publicKey: "k", endpoints: [], overlayIP: "10.77.0.2" } })
    await m.until((x) => x.frames.some((f) => f.type === "signal"))
    expect(await until(async () => (await prewarmedAt("alice", sessionId, spaceName)) !== undefined)).toBe(true)
    // The stable space's object of the same session was never made.
    expect(await prewarmedAt("alice", sessionId)).toBeUndefined()
    // The Mac answers, so both devices are the session's parties with their own relay tickets.
    await exchange(p, phone, m, mac, sessionId)
    const a = await joined(tok, sessionId, phone, space)
    // The join reached the very object the hub prewarmed: it holds the joiner's socket now.
    expect(await runInDurableObject(relayOf("alice", sessionId, spaceName), (_r: LinkRelay, state) => state.getWebSockets(phone).length)).toBe(1)
    a.ws.close()
  })

  it("a prewarm is no socket: the object answers it without an upgrade and holds nothing", async () => {
    const sessionId = crypto.randomUUID()
    const res = await relayOf("alice", sessionId).fetch("https://link-relay/prewarm", { method: "POST" })
    expect(res.status).toBe(204)
    expect(await runInDurableObject(relayOf("alice", sessionId), (_r: LinkRelay, state) => state.getWebSockets().length)).toBe(0)
  })
})
