import { exports } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { post, signedInWithInstall } from "./cloud-bind-support.ts"

/**
 * A host's read replica (plans/cmux-next/object-sync/DESIGN.md phase 3, host-replica/wire.ts),
 * driven over the real Worker sockets: the enrolling install publishes its host-homed streams,
 * the owner reads them live and with the host offline, ops reach only an online host, and nobody
 * else gets a socket.
 */
const worker = (exports as unknown as { default: Fetcher }).default

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type F = any

const socket = async (host: string, token: string) => {
  const res = await worker.fetch(`https://api.test/v1/wire/host/${host}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": "cmux.wire.v1", authorization: `Bearer ${token}` } })
  if (res.status !== 101) return { status: res.status } as const
  const ws = res.webSocket!
  const frames: Array<F> = []
  let closed: number | undefined
  let wake: (() => void) | undefined
  ws.addEventListener("message", (e) => {
    frames.push(JSON.parse(e.data as string))
    wake?.()
  })
  ws.addEventListener("close", (e) => {
    closed = e.code
    wake?.()
  })
  ws.accept()
  /** The index of the first frame at or after `from` that matches. */
  const until = async (match: (f: F) => boolean, from = 0): Promise<number> => {
    for (;;) {
      const i = frames.findIndex((f, n) => n >= from && match(f))
      if (i >= 0) return i
      if (closed !== undefined) throw new Error(`closed ${closed} before a match: ${JSON.stringify(frames)}`)
      await new Promise<void>((r) => (wake = r))
    }
  }
  return { status: 101, ws, frames, until, send: (f: unknown) => ws.send(JSON.stringify(f)), closed: () => closed } as const
}

const opened = <T extends { status: number }>(s: T): Extract<T, { status: 101 }> => {
  expect(s.status).toBe(101)
  return s as Extract<T, { status: 101 }>
}

const event = (stream: string, seq: number, title: string) => ({ t: "event", stream, seq, tx: `tx-${seq}`, op: "workspace.rename", params: { title }, actor: { user: "u" }, origin: "user", at: seq, effects: { state: { title }, writes: [] } })

describe("host read replica (object-sync phase 3)", () => {
  it("serves the host's streams live and offline, forwards ops only to the online host, and admits only the owner", async () => {
    const owner = await signedInWithInstall("host-replica-owner")
    const enrolled = await post("/v1/ops", owner.installToken, { op: "host.enroll", params: { name: "studio", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(enrolled.body.ok).toBe(true)
    const host = enrolled.body.value.id as string
    const stream = `host:${host}/session`

    // A stranger gets no socket, as publisher or as reader.
    const stranger = await signedInWithInstall("host-replica-stranger")
    expect((await socket(host, stranger.installToken)).status).toBe(403)
    expect((await socket(host, stranger.session)).status).toBe(403)

    // The enrolling install is the publisher: it learns where to resume, then publishes.
    const pub = opened(await socket(host, owner.installToken))
    await pub.until((f) => f.t === "welcome" && f.role === "publisher")
    expect(pub.frames[0].heads).toEqual({})
    pub.send({ t: "publish", stream, snapshot: { t: "snapshot", stream, seq: 2, state: { title: "one" }, decided: [{ idempotency_key: "k", ok: true, sequence: 2 }] } })
    pub.send({ t: "publish", stream, event: event(stream, 3, "two") })
    // A stream that is not this host's is refused.
    pub.send({ t: "publish", stream: "host:host_00000000000000000000/session", event: event("host:host_00000000000000000000/session", 1, "x") })
    await pub.until((f) => f.t === "error" && f.code === "validation.invalid")

    // The owner's session reads: online status, the snapshot (no decided keys of another client), the event.
    const reader = opened(await socket(host, owner.session))
    await reader.until((f) => f.t === "welcome" && f.role === "reader" && f.owner.status === "online")
    reader.send({ t: "subscribe", stream })
    const s = await reader.until((f) => f.t === "snapshot")
    expect(reader.frames[s - 1]).toMatchObject({ t: "owner.status", stream, status: "online", cached_seq: 3 })
    expect(reader.frames[s]).toMatchObject({ stream, seq: 2, state: { title: "one" }, decided: [] })
    await reader.until((f) => f.t === "event" && f.seq === 3, s)

    // Live: the next event reaches the subscribed reader.
    pub.send({ t: "publish", stream, event: event(stream, 4, "three") })
    await reader.until((f) => f.t === "event" && f.seq === 4)

    // A gap in what the host publishes is not stored; the replica asks the host for a snapshot once.
    pub.send({ t: "publish", stream, event: event(stream, 9, "gap") })
    await pub.until((f) => f.t === "snapshot.request" && f.stream === stream)

    // An op goes to the online host with the reader's principal; the host's answer comes back.
    reader.send({ t: "op", stream, op: "workspace.rename", params: { title: "four" }, idempotency_key: "op-1", origin: "user" })
    const fwd = await pub.until((f) => f.t === "op" && f.idempotency_key === "op-1")
    expect(pub.frames[fwd].principal).toMatchObject({ user: owner.user, kind: "session" })
    pub.send({ t: "request-settled", to: pub.frames[fwd].to, tx: "tx-5", idempotency_key: "op-1", stream, sequence: 5, ok: true })
    const settled = await reader.until((f) => f.t === "request-settled" && f.idempotency_key === "op-1")
    expect(reader.frames[settled]).not.toHaveProperty("to")

    // An op still at the host when it goes away is refused, not left waiting.
    reader.send({ t: "op", stream, op: "workspace.rename", params: { title: "lost" }, idempotency_key: "op-3", origin: "user" })
    await pub.until((f) => f.t === "op" && f.idempotency_key === "op-3")

    // The host goes away: readers see offline; a new reader resumes from the replica alone.
    pub.ws.close(1000, "bye")
    await reader.until((f) => f.t === "reject" && f.idempotency_key === "op-3" && f.code === "owner_unreachable" && f.retryable === true)
    await reader.until((f) => f.t === "request-settled" && f.idempotency_key === "op-3" && f.ok === false)
    await reader.until((f) => f.t === "owner.status" && f.status === "offline")
    const late = opened(await socket(host, owner.session))
    await late.until((f) => f.t === "welcome" && f.owner.status === "offline")
    late.send({ t: "subscribe", stream, after_seq: 3 })
    const resumed = await late.until((f) => f.t === "event" && f.seq === 4)
    expect(late.frames.slice(0, resumed).some((f) => f.t === "snapshot")).toBe(false)
    expect(late.frames.find((f) => f.t === "owner.status")).toMatchObject({ status: "offline", cached_seq: 4 })

    // Offline, an op is refused at once and settled not ok: nothing queues.
    late.send({ t: "op", stream, op: "workspace.rename", params: { title: "five" }, idempotency_key: "op-2", origin: "user" })
    await late.until((f) => f.t === "reject" && f.idempotency_key === "op-2" && f.code === "owner_unreachable" && f.retryable === true)
    await late.until((f) => f.t === "request-settled" && f.idempotency_key === "op-2" && f.ok === false)

    // A reader ahead of the replica (it read the live host further) is told so and gets nothing older.
    const ahead = opened(await socket(host, owner.session))
    ahead.send({ t: "subscribe", stream, after_seq: 7 })
    ahead.send({ t: "subscribe", stream: "host:host_00000000000000000000/session" })
    const told = await ahead.until((f) => f.t === "owner.status" && f.stream === stream)
    expect(ahead.frames[told]).toMatchObject({ status: "offline", cached_seq: 4 })
    await ahead.until((f) => f.t === "error" && f.code === "validation.invalid")
    expect(ahead.frames.some((f) => f.t === "snapshot" || f.t === "event")).toBe(false)

    // The host returns: it learns its heads, and readers see it online again.
    const back = opened(await socket(host, owner.installToken))
    const welcome = await back.until((f) => f.t === "welcome")
    expect(back.frames[welcome].heads).toEqual({ [stream]: 4 })
    await late.until((f) => f.t === "owner.status" && f.status === "online")

    // The host's off switch: the replica forgets every stream; readers see no cached copy.
    const before = late.frames.length
    back.send({ t: "replica.purge" })
    await back.until((f) => f.t === "replica.purged")
    const cleared = await late.until((f) => f.t === "owner.status" && f.cached_seq === undefined, before)
    expect(late.frames[cleared]).toMatchObject({ stream, status: "online" })
    const fresh = opened(await socket(host, owner.session))
    fresh.send({ t: "subscribe", stream })
    // A frame the reader does not know answers an error after everything the subscribe sent.
    fresh.send({ t: "nothing" })
    const end = await fresh.until((f) => f.t === "error")
    expect(fresh.frames.slice(0, end).find((f) => f.t === "owner.status").cached_seq).toBeUndefined()
    expect(fresh.frames.slice(0, end).some((f) => f.t === "snapshot" || f.t === "event")).toBe(false)
  })

  it("drops the replica when the host is removed: open sockets close and no new socket opens", async () => {
    const owner = await signedInWithInstall("host-replica-removed")
    const enrolled = await post("/v1/ops", owner.installToken, { op: "host.enroll", params: { name: "old", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const host = enrolled.body.value.id as string
    const stream = `host:${host}/session`
    const pub = opened(await socket(host, owner.installToken))
    await pub.until((f) => f.t === "welcome")
    pub.send({ t: "publish", stream, snapshot: { t: "snapshot", stream, seq: 1, state: { title: "secret" }, decided: [] } })
    const reader = opened(await socket(host, owner.session))
    reader.send({ t: "subscribe", stream })
    await reader.until((f) => f.t === "snapshot")

    const removed = await post("/v1/ops", owner.session, { op: "host.remove", params: { host }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(removed.body.ok).toBe(true)
    await expect(reader.until(() => false)).rejects.toThrow(/closed 4403/)
    await expect(pub.until(() => false)).rejects.toThrow(/closed 4403/)
    expect((await socket(host, owner.session)).status).toBe(403)
    expect((await socket(host, owner.installToken)).status).toBe(403)
  })
  it("lets the owner delete the replica while the host is off; the host may publish again later", async () => {
    const owner = await signedInWithInstall("host-replica-owner-purge")
    const enrolled = await post("/v1/ops", owner.installToken, { op: "host.enroll", params: { name: "away", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const host = enrolled.body.value.id as string
    const stream = `host:${host}/session`
    const pub = opened(await socket(host, owner.installToken))
    await pub.until((f) => f.t === "welcome")
    pub.send({ t: "publish", stream, snapshot: { t: "snapshot", stream, seq: 1, state: { title: "secret" }, decided: [] } })
    const reader = opened(await socket(host, owner.session))
    reader.send({ t: "subscribe", stream })
    await reader.until((f) => f.t === "snapshot")
    pub.ws.close(1000, "bye")
    await reader.until((f) => f.t === "owner.status" && f.status === "offline")

    // Only the host's owner: another account does not even see the host.
    const stranger = await signedInWithInstall("host-replica-purge-stranger")
    const refused = await post("/v1/ops", stranger.session, { op: "host.replica.purge", params: { host }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(refused.body.ok).toBe(false)

    const purged = await post("/v1/ops", owner.session, { op: "host.replica.purge", params: { host }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(purged.body).toMatchObject({ ok: true, value: { host } })
    // The open reader is closed; a new one finds no cached copy.
    await expect(reader.until(() => false)).rejects.toThrow(/closed 4403/)
    const fresh = opened(await socket(host, owner.session))
    fresh.send({ t: "subscribe", stream })
    fresh.send({ t: "nothing" })
    const end = await fresh.until((f) => f.t === "error")
    expect(fresh.frames.slice(0, end).find((f) => f.t === "owner.status").cached_seq).toBeUndefined()
    expect(fresh.frames.slice(0, end).some((f) => f.t === "snapshot" || f.t === "event")).toBe(false)

    // The host is not removed: its install publishes again (the Mac's own switch decides).
    const again = opened(await socket(host, owner.installToken))
    await again.until((f) => f.t === "welcome")
  })
})
