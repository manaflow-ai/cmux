import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import vectors from "../../../cmux-tui/crates/cmux-transport/tests/vectors/relay-frames.json"
import { checkFrame } from "../src/relay-frame.ts"
import { linkStatLine, uuidToBytes } from "../src/team-hub.ts"
import { connect, register, sockOf, token, worker, type Sock } from "./helpers.ts"

// PROTOCOL.md "WebSocket relay": the last way a WireGuard link reaches its peer, WireGuard datagrams in relay
// frames over a real HTTP/1.1 WebSocket upgrade on the Worker's own host. Only the two devices the owner's hub
// bound to a session at its first signal can join that session's relay.

const hex = (text: string): Uint8Array => Uint8Array.from(text.match(/../g) ?? [], (h) => Number.parseInt(h, 16))
const toHex = (bytes: Uint8Array) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")

/** A `datagrams` frame carrying `datagrams`, with `peer` as the sender wrote it (the relay overwrites it). */
const frame = (datagrams: Uint8Array[], peer = new Uint8Array(16).fill(0xee), kind = 1) => {
  const records = datagrams.flatMap((d) => [d.length >> 8, d.length & 0xff, ...d])
  return new Uint8Array([1, kind, ...peer, ...records])
}

const join = (tok: string, sessionId: string, deviceId: string, extra: Record<string, string> = {}) =>
  worker.fetch(`https://api.test/v1/relay/${sessionId}?deviceId=${deviceId}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${tok}`, ...extra } })

const joined = async (tok: string, sessionId: string, deviceId: string, extra: Record<string, string> = {}): Promise<Sock> => {
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
  return { tok, phone, mac, p, m, sessionId }
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
