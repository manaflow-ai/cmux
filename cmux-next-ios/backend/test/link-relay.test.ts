import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import vectors from "../../../cmux-tui/crates/cmux-transport/tests/vectors/relay-frames.json"
import taggedVectors from "../../../cmux-tui/crates/cmux-transport/tests/vectors/relay-tagged-frames.json"
import { seqNewer, TaggedQueue } from "../src/relay-coalesce.ts"
import { checkFrame, splitTagged } from "../src/relay-frame.ts"
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

/** One hop/1 DATA record: `[class][flags][u32 key, u32 seq if tagged][u16 len][data]`. */
const rec = (cls: number, data: number[], tag?: [number, number]) => {
  const head = [cls, tag ? 1 : 0]
  if (tag) for (const v of tag) head.push((v >>> 24) & 255, (v >>> 16) & 255, (v >>> 8) & 255, v & 255)
  return new Uint8Array([...head, data.length >> 8, data.length & 255, ...data])
}
const tagged = (records: Uint8Array[], peer = new Uint8Array(16).fill(0xee)) => new Uint8Array([1, 4, ...peer, ...records.flatMap((r) => [...r])])

describe("tagged-datagrams frame (shared golden vectors with cmux-transport)", () => {
  interface Case {
    readonly name: string
    readonly valid: "yes" | "no"
    readonly hex: string
    readonly kind?: string
    readonly error?: string
    readonly records?: string
  }
  const cases = (taggedVectors as { cases: ReadonlyArray<Case> }).cases

  it("accepts every valid vector with its records and refuses every invalid one with the expected error", () => {
    expect(cases.filter((c) => c.valid === "yes").length).toBeGreaterThanOrEqual(5)
    for (const c of cases) {
      const bytes = hex(c.hex)
      const checked = checkFrame(bytes)
      if (c.valid === "no") {
        expect(checked, c.name).toEqual({ ok: false, error: c.error })
        continue
      }
      expect(checked, c.name).toEqual({ ok: true, kind: c.kind })
      const got = splitTagged(bytes.subarray(18))!.map((r) => {
        const body = r.raw.subarray(r.tag ? 12 : 4)
        return `${r.class}:${r.tag ? `${r.tag[0].toString(16).padStart(8, "0")}.${r.tag[1].toString(16).padStart(8, "0")}` : "-"}:${toHex(body)}`
      })
      expect(got.join(","), c.name).toBe(c.records)
    }
  })
})

describe("TaggedQueue (R5 latest-wins, as far as a Durable Object can do it)", () => {
  const one = (cls: number, data: number, tag?: [number, number]) => splitTagged(rec(cls, [data], tag))![0]!
  const dataOf = (q: TaggedQueue) => q.drain(new Uint8Array(16), 4).flatMap((f) => (splitTagged(f.subarray(18)) ?? []).map((r) => r.raw[r.raw.length - 1]))

  it("replaces an older class-1 record of the same key, keeps other keys, and drops a stale arrival", () => {
    const q = new TaggedQueue()
    q.add(one(1, 1, [7, 1]))
    q.add(one(1, 2, [8, 1]))
    expect(q.add(one(1, 3, [7, 2]))).toBe(1)
    expect(q.add(one(1, 4, [7, 1]))).toBe(1)
    expect(dataOf(q)).toEqual([2, 3])
  })

  it("never drops or reorders control, input, bulk, media or untagged class 1", () => {
    const q = new TaggedQueue()
    const input = [one(0, 1), one(1, 2, [7, 1]), one(2, 3), one(1, 9), one(3, 4), one(4, 5), one(1, 6, [7, 2]), one(0, 7), one(2, 8, [7, 1])]
    for (const r of input) q.add(r)
    // Only the superseded tagged class 1 (data 2) is gone; the class-2 record tagged with the same key survives.
    expect(dataOf(q)).toEqual([1, 3, 9, 4, 5, 6, 7, 8])
  })

  it("compares sequence numbers modulo 2^32", () => {
    expect(seqNewer(2, 1)).toBe(true)
    expect(seqNewer(1, 2)).toBe(false)
    expect(seqNewer(1, 1)).toBe(false)
    expect(seqNewer(0, 0xffffffff)).toBe(true)
  })

  it("packs a long queue into frames of at most 16 KiB, in order", () => {
    const q = new TaggedQueue()
    for (let i = 0; i < 40; i++) q.add(one(3, i & 255))
    const big = splitTagged(rec(3, new Array(5000).fill(1)))![0]!
    for (let i = 0; i < 6; i++) q.add(big)
    const frames = q.drain(new Uint8Array(16), 4)
    expect(frames.length).toBeGreaterThan(1)
    for (const f of frames) expect(f.length - 18).toBeLessThanOrEqual(16 * 1024)
    expect(frames.flatMap((f) => splitTagged(f.subarray(18))!).length).toBe(46)
  })
})

describe("link relay: tagged-datagrams", () => {
  it("forwards tagged frames with the peer rewritten, and an old plain frame still crosses unchanged", async () => {
    const { tok, phone, mac, sessionId } = await session()
    const a = await joined(tok, sessionId, phone)
    const b = await joined(tok, sessionId, mac)
    await a.until((x) => x.frames.some((f) => f.type === "peer" && f.online === true))
    const sent = tagged([rec(1, [1, 2, 3], [5, 1]), rec(0, [9])])
    a.ws.send(sent)
    await b.until((x) => x.binary.length === 1)
    const got = b.binary[0]!
    expect([got[0], got[1]]).toEqual([1, 4])
    expect(toHex(got.subarray(2, 18))).toBe(toHex(uuidToBytes(phone)))
    expect(toHex(got.subarray(18))).toBe(toHex(sent.subarray(18)))
    // Old sender, new relay: a plain datagrams frame is forwarded as before.
    a.ws.send(frame([new Uint8Array([4, 0, 0, 0, 5])]))
    await b.until((x) => x.binary.length === 2)
    expect([b.binary[1]![0], b.binary[1]![1]]).toEqual([1, 1])
    a.ws.close()
    b.ws.close()
  })

  it("coalesces frames that arrive in one turn, drops superseded class-1 records, and keeps order", async () => {
    const { tok, phone, mac, sessionId } = await session()
    const a = await joined(tok, sessionId, phone)
    const b = await joined(tok, sessionId, mac)
    await a.until((x) => x.frames.some((f) => f.type === "peer" && f.online === true))
    a.ws.send(tagged([rec(0, [1])]))
    a.ws.send(tagged([rec(1, [2], [7, 1])]))
    a.ws.send(tagged([rec(1, [3], [7, 2]), rec(2, [4])]))
    a.ws.send(tagged([rec(1, [9], [7, 1])]))
    // A plain frame behind them never overtakes what is queued.
    a.ws.send(frame([new Uint8Array([0xaa])]))
    await b.until((x) => x.binary.length >= 2)
    await new Promise((r) => setTimeout(r, 100))
    const order = b.binary.flatMap((f) => (f[1] === 4 ? (splitTagged(f.subarray(18)) ?? []).map((r) => r.raw[r.raw.length - 1]!) : [0xaa]))
    // 2 is superseded by 3 (same key, newer seq), and the late seq 1 is stale.
    expect(order).toEqual([1, 3, 4, 0xaa])
    // Fewer frames than were sent: the tagged ones were merged.
    expect(b.binary.length).toBeLessThan(5)
    a.ws.close()
    b.ws.close()
  })

  it("refuses a tagged frame whose records do not tile, and an unknown kind with the notice an old relay sends", async () => {
    const { tok, phone, mac, sessionId } = await session()
    const a = await joined(tok, sessionId, phone)
    const b = await joined(tok, sessionId, mac)
    const bad = tagged([rec(1, [1, 2], [5, 1])])
    a.ws.send(bad.subarray(0, bad.length - 1))
    await a.until((x) => x.frames.some((f) => f.type === "error" && f.code === "bad_frame:bad_batch"))
    // The notice a sender falls back on (cmux_transport RelaySender): kind byte the relay does not know.
    const unknown = tagged([rec(0, [1])])
    unknown[1] = 9
    b.ws.send(unknown)
    await b.until((x) => x.frames.some((f) => f.type === "error" && f.code === "bad_frame:kind"))
    expect(b.binary.length + a.binary.length).toBe(0)
    a.ws.close()
    b.ws.close()
  })

  it("reports per-leg counters on request", async () => {
    const { tok, phone, mac, sessionId } = await session()
    const a = await joined(tok, sessionId, phone)
    const b = await joined(tok, sessionId, mac)
    await a.until((x) => x.frames.some((f) => f.type === "peer" && f.online === true))
    // One frame with a record and its successor (deterministic: separate frames share a turn only sometimes).
    a.ws.send(tagged([rec(1, [1], [7, 1]), rec(1, [2], [7, 2])]))
    await b.until((x) => x.binary.length >= 1)
    a.ws.send("stats")
    await a.until((x) => x.frames.some((f) => f.type === "stats"))
    const stats = a.frames.find((f) => f.type === "stats")!
    expect(stats.leg).toMatchObject({ framesIn: 1, recordsIn: 2, recordsSuperseded: 1 })
    expect(stats.peer).toMatchObject({ framesOut: 1 })
    a.ws.close()
    b.ws.close()
  })
})
