import { describe, expect, it } from "vitest"
import { negotiateHello } from "../src/mobile-session.ts"
import { op, stackToken, worker } from "./host-control-support.ts"

/**
 * cmux.mobile/1 on every owner socket (b1-control-do.md section 2): optional `hello` (4002 on a
 * version mismatch), `read`/`read.result`, and the `ssh:<user>` stream of UserDO (section 8).
 */

const openWire = async (scope: string, token: string) => {
  const res = await worker.fetch(`https://api.test/v1/wire/${scope}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}` } })
  const ws = res.webSocket as WebSocket
  const frames: Array<any> = []
  const waiters: Array<{ pred: (f: any) => boolean; resolve: (f: any) => void }> = []
  let onClose: (c: number) => void = () => {}
  const closed = new Promise<number>((r) => (onClose = r))
  ws.addEventListener("message", (e) => {
    const f = JSON.parse(e.data as string)
    frames.push(f)
    for (const w of [...waiters]) if (w.pred(f)) [waiters.splice(waiters.indexOf(w), 1), w.resolve(f)]
  })
  ws.addEventListener("close", (e) => onClose(e.code))
  ws.accept()
  const next = (pred: (f: any) => boolean) => {
    const hit = frames.find(pred)
    return hit ? Promise.resolve(hit) : new Promise<any>((resolve) => waiters.push({ pred, resolve }))
  }
  return { ws, frames, closed, next, send: (f: unknown) => ws.send(JSON.stringify(f)) }
}

const signedIn = async (tag: string) => {
  const session = await stackToken(`${tag}-${crypto.randomUUID().slice(0, 8)}`)
  const user = (await op(session, "user.ensure", {})).json.value.id as string
  return { session, user }
}

const hello = (min = 1, max = 1) => ({ t: "hello", proto: "cmux.mobile/1", min, max, caps: ["read", "nope"], client: { install: "in_x1", platform: "ios", app_version: "1.0" } })

describe("cmux.mobile/1 on owner sockets", { timeout: 60_000 }, () => {
  it("negotiates hello on UserDO and FeedDO, and closes 4002 on a version mismatch", async () => {
    const u = await signedIn("own-hello")
    const user = await openWire("user", u.session)
    user.send(hello())
    expect(await user.next((f) => f.t === "hello.ok")).toMatchObject({ version: 1, caps: ["read"], proto: "cmux.mobile/1" })
    const feed = await openWire("feed", u.session)
    feed.send(hello(1, 4))
    expect(await feed.next((f) => f.t === "hello.ok")).toMatchObject({ version: 1 })
    const future = await openWire("user", u.session)
    future.send(hello(2, 2))
    expect(await future.next((f) => f.t === "error")).toMatchObject({ code: "proto.version_unsupported", retryable: false })
    expect(await future.closed).toBe(4002)
  })

  it("answers read frames with read.result or a typed error carrying the id", async () => {
    const u = await signedIn("own-read")
    const user = await openWire("user", u.session)
    user.send({ t: "read", id: 4, op: "install.list", params: {} })
    const r = await user.next((f) => f.t === "read.result")
    expect(r.id).toBe(4)
    expect(Number(r.revision)).toBeGreaterThan(0)
    expect(r.value.user.id).toBe(u.user)
    user.send({ t: "read", id: 5, op: "no.such", params: {} })
    expect(await user.next((f) => f.t === "error" && f.id === 5)).toMatchObject({ code: "validation.invalid", retryable: false })
    user.send({ t: "read", op: "install.list" })
    expect(await user.next((f) => f.t === "error" && f.message === "read needs an integer id")).toBeTruthy()
    user.send({ t: "nonsense" })
    expect(await user.next((f) => f.t === "error" && f.code === "proto.unknown_frame")).toBeTruthy()
  })

  it("keeps synced SSH host records on ssh:<user> and refuses secrets", async () => {
    const u = await signedIn("own-ssh")
    const s = await openWire("user", u.session)
    const stream = `ssh:${u.user}`
    s.send({ t: "subscribe", stream })
    expect(await s.next((f) => f.t === "snapshot" && f.stream === stream)).toMatchObject({ seq: 0, state: { hosts: {}, known: {} } })
    const host = { id: "ssh_box01", name: "box", hostname: "box.example.com", port: 22, user: "me", key: `SHA256:${"A".repeat(43)}` }
    s.send({ t: "op", op: "ssh.host.upsert", params: { host }, idempotency_key: "ssh-upsert-1", stream })
    expect(await s.next((f) => f.t === "event" && f.stream === stream)).toMatchObject({ seq: 1, op: "ssh.host.upsert" })
    expect(await s.next((f) => f.t === "result" && f.idempotency_key === "ssh-upsert-1")).toMatchObject({ value: { id: "ssh_box01" } })
    s.send({ t: "op", op: "ssh.host.upsert", params: { host: { ...host, id: "ssh_box02", private_key: "-----BEGIN" } }, idempotency_key: "ssh-upsert-2" })
    expect(await s.next((f) => f.t === "reject" && f.idempotency_key === "ssh-upsert-2")).toMatchObject({ code: "validation.invalid" })
    s.send({ t: "op", op: "ssh.known_host.add", params: { id: "ssh_nobody", key_type: "ssh-ed25519", key: "A".repeat(68), fingerprint: `SHA256:${"B".repeat(43)}` }, idempotency_key: "ssh-known-1" })
    expect(await s.next((f) => f.t === "reject" && f.idempotency_key === "ssh-known-1")).toMatchObject({ code: "ssh.host_not_found" })
    s.send({ t: "op", op: "ssh.known_host.add", params: { id: "ssh_box01", key_type: "ssh-ed25519", key: "A".repeat(68), fingerprint: `SHA256:${"B".repeat(43)}` }, idempotency_key: "ssh-known-2" })
    expect(await s.next((f) => f.t === "result" && f.idempotency_key === "ssh-known-2")).toBeTruthy()
    // Idempotent replay: same key, first outcome.
    s.send({ t: "op", op: "ssh.host.upsert", params: { host }, idempotency_key: "ssh-upsert-1", stream })
    expect(await s.next((f) => f.t === "result" && f.idempotency_key === "ssh-upsert-1" && f.replayed === true)).toBeTruthy()

    // Resume after reconnect: events after the cursor, then a remove clears its known keys.
    const again = await openWire("user", u.session)
    again.send({ t: "subscribe", stream, after_seq: 1 })
    expect(await again.next((f) => f.t === "event" && f.stream === stream)).toMatchObject({ seq: 2, op: "ssh.known_host.add" })
    again.send({ t: "op", op: "ssh.host.remove", params: { id: "ssh_box01" }, idempotency_key: "ssh-remove-1" })
    await again.next((f) => f.t === "result" && f.idempotency_key === "ssh-remove-1")
    again.send({ t: "snapshot.request", stream })
    expect(await again.next((f) => f.t === "snapshot" && f.stream === stream)).toMatchObject({ seq: 3, state: { hosts: {}, known: {} } })
  })

  it("negotiates the highest common version and the common caps", () => {
    const r = negotiateHello({ proto: "cmux.mobile/1", min: 1, max: 9, caps: ["read", "Bad Cap", "x"], client: { install: "in_a", platform: "ios", app_version: "1" } }, ["read", "signal"], 5)
    expect(r).toEqual({ ok: true, session: { version: 1, caps: ["read"], client: { install: "in_a", platform: "ios", app_version: "1" } }, reply: { t: "hello.ok", proto: "cmux.mobile/1", version: 1, caps: ["read"], server_time: 5, max_frame: 131072 } })
    expect(negotiateHello({ proto: "cmux.mobile/2", min: 1, max: 1, caps: [], client: {} }, [])).toMatchObject({ ok: false, close: true })
    expect(negotiateHello({ proto: "cmux.mobile/1", min: 1, max: 1, caps: [], client: { install: "in_a" } }, [])).toMatchObject({ ok: false, close: false, error: { code: "validation.invalid" } })
  })
})
