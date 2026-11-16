import { runInDurableObject as runIn } from "cloudflare:test"
import { env, exports } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { STALE_AFTER_MS, STALE_CODE } from "../src/host-do.ts"
import { post, signedInWithInstall } from "./cloud-bind-support.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * HostDO liveness (cmuxterm-hq docs/handbook/connections-and-lifetimes.md): a peer that vanishes
 * without a close is found within STALE_AFTER_MS and closed with a reason, presence flips, and a
 * frame that cannot be forwarded is answered with why. The object's clock is a fake the test moves
 * (`clock`); the alarm is run by hand at the times that matter.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type F = any
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const ns = (env as unknown as { HOST_DO: DurableObjectNamespace }).HOST_DO
const worker = (exports as unknown as { default: Fetcher }).default

const hex = (text: string): Uint8Array => Uint8Array.from(text.match(/../g) ?? [], (h) => Number.parseInt(h, 16))
const HOST = "f0e1d2c3b4a5968778695a4b3c2d1e0f"
const ALICE = "00112233445566778899aabbccddeeff"
const BOB = "0123456789abcdef0123456789abcdef"
/** A `datagrams` relay frame naming `peer` (one 32-byte record). */
const datagram = (peer: string) => hex(`0101${peer}0020${"04000000" + "00".repeat(28)}`)

/** The test's end of a socket: JSON text frames, binary frames, and how it closed. */
const watch = (ws: WebSocket) => {
  const texts: Array<F> = []
  const binaries: Array<Uint8Array> = []
  let closed: { code: number; reason: string } | undefined
  let wake: (() => void) | undefined
  // Binary data may arrive as an ArrayBuffer, a view or a Blob: each is read into bytes, in order.
  let pending = Promise.resolve()
  const bytesOf = async (d: unknown): Promise<Uint8Array> => {
    if (d instanceof ArrayBuffer) return new Uint8Array(d.slice(0))
    if (ArrayBuffer.isView(d)) return new Uint8Array(d.buffer.slice(d.byteOffset, d.byteOffset + d.byteLength))
    if (d instanceof Blob) return new Uint8Array(await d.arrayBuffer())
    throw new Error(`binary message of type ${Object.prototype.toString.call(d)}`)
  }
  ws.addEventListener("message", (e) => {
    if (typeof e.data === "string") {
      texts.push(e.data === "pong" ? { t: "pong" } : JSON.parse(e.data))
      wake?.()
      return
    }
    const data = e.data as unknown
    pending = pending.then(async () => {
      binaries.push(await bytesOf(data))
      wake?.()
    })
  })
  ws.addEventListener("close", (e) => {
    closed = { code: e.code, reason: e.reason }
    wake?.()
  })
  ws.accept()
  const next = () => new Promise<void>((r) => (wake = r))
  /** The index of the first text frame at or after `from` that matches. */
  const until = async (match: (f: F) => boolean, from = 0): Promise<number> => {
    for (;;) {
      const i = texts.findIndex((f, n) => n >= from && match(f))
      if (i >= 0) return i
      if (closed) throw new Error(`closed ${closed.code} ${closed.reason} before a match: ${JSON.stringify(texts)}`)
      await next()
    }
  }
  const binary = async (n: number) => {
    while (binaries.length < n) {
      if (closed) throw new Error(`closed ${closed.code} before ${n} binary frames`)
      await next()
    }
    return binaries[n - 1]!
  }
  const closedWith = async () => {
    while (!closed) await next()
    return closed
  }
  return { ws, texts, until, binary, closedWith, send: (d: string | Uint8Array) => ws.send(d) }
}

const relaySocket = async (stub: DurableObjectStub, role: "host" | "client", peer: string) => {
  const res = await stub.fetch("https://api.test/relay", { headers: { Upgrade: "websocket", "x-cmux-relay-role": role, "x-cmux-relay-peer": peer } })
  expect(res.status).toBe(101)
  return watch(res.webSocket!)
}

/** A HostDO on a fake clock that starts at `start`; `set` moves it. */
const onFakeClock = async (stub: DurableObjectStub, start: number) => {
  const clock = { now: start }
  await runInDurableObject(stub, async (i) => {
    i.clock = () => clock.now
  })
  return clock
}

/** Runs the alarm as the runtime does: the scheduled one is taken first (setup/alarm.ts). */
const runAlarm = (stub: DurableObjectStub) => fireAlarm(stub)
const socketState = (stub: DurableObjectStub, tag: string) => runInDurableObject(stub, async (_i, state) => state.getWebSockets(tag).map((s) => s.readyState))
const OPEN = 1

describe("HostDO relay liveness", () => {
  it("finds a host that goes silent right after accept within the bound, and tells clients why their frames are not forwarded", async () => {
    const stub = ns.get(ns.idFromName(`relay-silent-${crypto.randomUUID()}`))
    // A fake clock well ahead of the real one, so the runtime never fires the alarm on its own.
    const clock = await onFakeClock(stub, Date.now() + 365 * 86_400_000)
    await (stub as unknown as { setReachability(h: string, p: Array<string>): Promise<void> }).setReachability(HOST, [ALICE, BOB])

    // Before any host: the client is told at connect, and a frame it sends comes back as why.
    const alice = await relaySocket(stub, "client", ALICE)
    await alice.until((f) => f.t === "relay.host" && f.status === "offline")
    for (let n = 0; n < 50; n++) alice.send(datagram(ALICE))
    await alice.until((f) => f.t === "relay.dropped" && f.reason === "host_offline")
    // A flood gets one notice per window, not one per frame.
    clock.now += 1_000
    alice.send(datagram(ALICE))
    const second = await alice.until((f) => f.t === "relay.dropped", alice.texts.findIndex((f) => f.t === "relay.dropped") + 1)
    expect(alice.texts.filter((f) => f.t === "relay.dropped")).toHaveLength(2)
    expect(alice.texts[second]).toEqual({ t: "relay.dropped", reason: "host_offline" })

    // The host connects, then sends nothing at all (a half-open socket: no ping, no frame, no FIN).
    const acceptedAt = (clock.now += 1_000)
    const host = await relaySocket(stub, "host", HOST)
    await alice.until((f) => f.t === "relay.host" && f.status === "online")
    const alarmAt = await runInDurableObject(stub, async (_i, state) => state.storage.getAlarm())
    expect(alarmAt).not.toBeNull()
    expect(alarmAt!).toBeLessThanOrEqual(acceptedAt + STALE_AFTER_MS)
    // Alice keeps talking, so only the host is silent.
    clock.now += 1_500
    alice.send(datagram(ALICE))

    // One millisecond inside the bound the host is still connected.
    clock.now = acceptedAt + STALE_AFTER_MS - 1
    await runAlarm(stub)
    expect(await socketState(stub, "host")).toEqual([OPEN])

    // At the bound it is closed with a code and a reason, and presence flips for the client.
    const offlineAt = alice.texts.length
    clock.now = acceptedAt + STALE_AFTER_MS
    await runAlarm(stub)
    const closed = await host.closedWith()
    expect(closed.code).toBe(STALE_CODE)
    expect(closed.reason).toMatch(/^stale: no ping or frame for 45 s$/)
    await alice.until((f) => f.t === "relay.host" && f.status === "offline", offlineAt)
    alice.send(datagram(ALICE))
    await alice.until((f) => f.t === "relay.dropped" && f.reason === "host_offline", offlineAt)
    console.log(`time-to-detect, host silent right after accept: ${clock.now - acceptedAt} ms (before: never)`)
  })

  it("finds a host that goes silent mid-stream within the bound, and tells the host which client is offline", async () => {
    const stub = ns.get(ns.idFromName(`relay-midstream-${crypto.randomUUID()}`))
    const start = Date.now() + 365 * 86_400_000
    const clock = await onFakeClock(stub, start)
    await (stub as unknown as { setReachability(h: string, p: Array<string>): Promise<void> }).setReachability(HOST, [ALICE, BOB])
    const alice = await relaySocket(stub, "client", ALICE)
    const host = await relaySocket(stub, "host", HOST)
    await alice.until((f) => f.t === "relay.host" && f.status === "online")

    // Mid-stream: the host's frames reach Alice with its own peer id; a frame to Bob (not connected) says so.
    const lastFrame = (clock.now = start + 20_000)
    host.send(datagram(ALICE))
    const got = await alice.binary(1)
    expect(Array.from(got.subarray(2, 18))).toEqual(Array.from(hex(HOST)))
    host.send(datagram(BOB))
    await host.until((f) => f.t === "relay.dropped" && f.reason === "client_offline" && f.peer === BOB)
    clock.now = start + 30_000
    alice.send(datagram(ALICE))
    await host.binary(1)

    // Then the host goes silent: still there one millisecond inside the bound, closed at it.
    clock.now = lastFrame + STALE_AFTER_MS - 1
    await runAlarm(stub)
    expect(await socketState(stub, "host")).toEqual([OPEN])
    const offlineAt = alice.texts.length
    clock.now = lastFrame + STALE_AFTER_MS
    await runAlarm(stub)
    expect(await host.closedWith()).toMatchObject({ code: STALE_CODE, reason: expect.stringMatching(/^stale/) })
    await alice.until((f) => f.t === "relay.host" && f.status === "offline", offlineAt)
    expect(await socketState(stub, `client:${ALICE}`)).toEqual([OPEN])
    console.log(`time-to-detect, host silent mid-stream: ${clock.now - lastFrame} ms (before: never)`)
  })
})

describe("HostDO replica publisher liveness", () => {
  const replicaSocket = async (host: string, token: string) => {
    const res = await worker.fetch(`https://api.test/v1/wire/host/${host}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": "cmux.wire.v1", authorization: `Bearer ${token}` } })
    expect(res.status).toBe(101)
    const s = watch(res.webSocket!)
    return { ...s, frame: (f: unknown) => s.send(JSON.stringify(f)) }
  }
  const enroll = async (name: string) => {
    const owner = await signedInWithInstall(name)
    const enrolled = await post("/v1/ops", owner.installToken, { op: "host.enroll", params: { name, platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(enrolled.body.ok).toBe(true)
    return { owner, host: enrolled.body.value.id as string }
  }

  it("evicts a publisher that pinged and then went silent: readers see offline and ops in flight are refused", async () => {
    const { owner, host } = await enroll("liveness-pinging-publisher")
    const stub = ns.get(ns.idFromName(host))
    const stream = `host:${host}/session`
    const pub = await replicaSocket(host, owner.installToken)
    await pub.until((f) => f.t === "welcome" && f.role === "publisher")
    // The runtime's auto-response timestamps are real time: the fake clock starts there.
    const clock = await onFakeClock(stub, Date.now())
    pub.send("ping")
    await pub.until((f) => f.t === "pong")
    pub.frame({ t: "publish", stream, snapshot: { t: "snapshot", stream, seq: 1, state: { title: "one" }, decided: [] } })
    const reader = await replicaSocket(host, owner.session)
    await reader.until((f) => f.t === "welcome" && f.owner.status === "online")
    reader.frame({ t: "subscribe", stream })
    await reader.until((f) => f.t === "snapshot")
    reader.frame({ t: "op", stream, op: "workspace.rename", params: { title: "two" }, idempotency_key: "live-1", origin: "user" })
    await pub.until((f) => f.t === "op" && f.idempotency_key === "live-1")

    // The publisher's last sign of life and the deadline the object holds it to.
    const { last, deadline } = await runInDurableObject(stub, async (i, state) => {
      const ws = state.getWebSockets("replica:publisher")[0]!
      const a = ws.deserializeAttachment() as { at: number; seen?: number }
      const pinged = state.getWebSocketAutoResponseTimestamp(ws)!.getTime()
      return { last: Math.max(a.at, a.seen ?? 0, pinged), deadline: i.staleAt(ws, clock.now) as number }
    })
    expect(deadline - last).toBe(STALE_AFTER_MS)

    clock.now = deadline - 1
    await runAlarm(stub)
    expect(await socketState(stub, "replica:publisher")).toEqual([OPEN])
    clock.now = deadline
    await runAlarm(stub)
    expect(await pub.closedWith()).toMatchObject({ code: STALE_CODE, reason: expect.stringMatching(/^stale/) })
    await reader.until((f) => f.t === "reject" && f.idempotency_key === "live-1" && f.code === "owner_unreachable" && f.retryable === true)
    await reader.until((f) => f.t === "owner.status" && f.status === "offline")
    console.log(`time-to-detect, pinging publisher gone silent: ${clock.now - last} ms (before: never; the reader's op waited forever)`)
  })

  it("holds a publisher whose first ping comes after the first look to the bound from then on", async () => {
    const { owner, host } = await enroll("liveness-late-ping-publisher")
    const stub = ns.get(ns.idFromName(host))
    const pub = await replicaSocket(host, owner.installToken)
    await pub.until((f) => f.t === "welcome" && f.role === "publisher")
    const acceptedAt = await runInDurableObject(stub, async (_i, state) => (state.getWebSockets("replica:publisher")[0]!.deserializeAttachment() as { at: number }).at)
    const clock = await onFakeClock(stub, acceptedAt)
    // The first look: no ping yet, so it stays open, and the next look is armed a bound later.
    clock.now = acceptedAt + STALE_AFTER_MS
    await runAlarm(stub)
    expect(await socketState(stub, "replica:publisher")).toEqual([OPEN])
    expect(await runInDurableObject(stub, async (_i, state) => state.storage.getAlarm())).toBe(acceptedAt + 2 * STALE_AFTER_MS)
    // Then it pings (which never wakes the object) and goes silent: the next look closes it.
    pub.send("ping")
    await pub.until((f) => f.t === "pong")
    clock.now = acceptedAt + 2 * STALE_AFTER_MS
    await runAlarm(stub)
    expect(await pub.closedWith()).toMatchObject({ code: STALE_CODE, reason: expect.stringMatching(/^stale/) })
  })

  it("leaves a publisher that never pings to its token expiry, as before (today's Macs send no ping)", async () => {
    const { owner, host } = await enroll("liveness-legacy-publisher")
    const stub = ns.get(ns.idFromName(host))
    const pub = await replicaSocket(host, owner.installToken)
    await pub.until((f) => f.t === "welcome" && f.role === "publisher")
    const clock = await onFakeClock(stub, Date.now())
    clock.now += 5 * STALE_AFTER_MS
    await runAlarm(stub)
    expect(await socketState(stub, "replica:publisher")).toEqual([OPEN])
    const reader = await replicaSocket(host, owner.session)
    await reader.until((f) => f.t === "welcome" && f.owner.status === "online")
  })
})
