import { exports } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { post, signedInWithInstall } from "./cloud-bind-support.ts"

/**
 * The Chief mailbox of a host's read replica (cmux-prompts logs/iphone-chief-DESIGN.md, a450):
 * a Chief message the phone sends while the Mac is offline is kept by HostDO and handed to the
 * Mac when it publishes again, once, in order, with no duplicate for a resend of the same key.
 * Every other op on every other stream is still refused offline (U5).
 */
const worker = (exports as unknown as { default: Fetcher }).default

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type F = any

const socket = async (host: string, token: string) => {
  const res = await worker.fetch(`https://api.test/v1/wire/host/${host}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": "cmux.wire.v1", authorization: `Bearer ${token}` } })
  if (res.status !== 101) throw new Error(`socket ${res.status}`)
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
  const until = async (match: (f: F) => boolean, from = 0): Promise<number> => {
    for (;;) {
      const i = frames.findIndex((f, n) => n >= from && match(f))
      if (i >= 0) return i
      if (closed !== undefined) throw new Error(`closed ${closed} before a match: ${JSON.stringify(frames)}`)
      await new Promise<void>((r) => (wake = r))
    }
  }
  return { ws, frames, until, send: (f: unknown) => ws.send(JSON.stringify(f)) } as const
}

const send = (stream: string, key: string, text: string) => ({ t: "op", stream, op: "conversation.message.send", params: { text }, idempotency_key: key, origin: "user" })

const enroll = async (name: string) => {
  const owner = await signedInWithInstall(name)
  const enrolled = await post("/v1/ops", owner.installToken, { op: "host.enroll", params: { name, platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "user" })
  expect(enrolled.body.ok).toBe(true)
  return { owner, host: enrolled.body.value.id as string }
}

describe("host replica Chief mailbox", () => {
  it("queues Chief messages while the Mac is offline and delivers them once, in order, when it is back", async () => {
    const { owner, host } = await enroll("mailbox-owner")
    const chief = `host:${host}/chief`
    const session = `host:${host}/session`

    const pub = await socket(host, owner.installToken)
    await pub.until((f) => f.t === "welcome")
    pub.send({ t: "publish", stream: chief, snapshot: { t: "snapshot", stream: chief, seq: 1, state: { messages: [] }, decided: [] } })
    pub.ws.close(1000, "asleep")

    const phone = await socket(host, owner.session)
    await phone.until((f) => f.t === "welcome" && f.owner.status === "offline")
    phone.send({ t: "subscribe", stream: chief })
    await phone.until((f) => f.t === "snapshot" && f.stream === chief)

    // Offline: Chief messages are queued, in order; a resend of the same key is the same entry.
    phone.send(send(chief, "m-1", "first"))
    phone.send(send(chief, "m-2", "second"))
    phone.send(send(chief, "m-1", "first"))
    const q1 = await phone.until((f) => f.t === "op.queued" && f.idempotency_key === "m-1")
    expect(phone.frames[q1]).toMatchObject({ stream: chief, position: 1 })
    await phone.until((f) => f.t === "op.queued" && f.idempotency_key === "m-2" && f.position === 2)
    const again = await phone.until((f) => f.t === "op.queued" && f.idempotency_key === "m-1", q1 + 1)
    expect(phone.frames[again].position).toBe(1)
    expect(phone.frames.some((f) => f.t === "reject")).toBe(false)

    // Only message.send on the chief stream queues: other ops and streams are still refused (U5).
    phone.send({ t: "op", stream: chief, op: "conversation.message.edit", params: { text: "x" }, idempotency_key: "e-1", origin: "user" })
    phone.send({ t: "op", stream: session, op: "workspace.rename", params: { name: "x" }, idempotency_key: "r-1", origin: "user" })
    await phone.until((f) => f.t === "reject" && f.idempotency_key === "e-1" && f.code === "owner_unreachable")
    await phone.until((f) => f.t === "reject" && f.idempotency_key === "r-1" && f.code === "owner_unreachable")

    // The phone may go away: the mailbox does not depend on its socket.
    phone.ws.close(1000, "pocket")

    // The Mac is back: it gets the queued messages in order, each once, with the owner's principal.
    const back = await socket(host, owner.installToken)
    await back.until((f) => f.t === "welcome")
    const a = await back.until((f) => f.t === "op" && f.to === "mailbox")
    const b = await back.until((f) => f.t === "op" && f.to === "mailbox", a + 1)
    expect([back.frames[a].idempotency_key, back.frames[b].idempotency_key]).toEqual(["m-1", "m-2"])
    expect(back.frames[a]).toMatchObject({ op: "conversation.message.send", params: { text: "first" }, principal: { user: owner.user } })
    expect(back.frames.filter((f) => f.t === "op").length).toBe(2)

    // A reader sees each delivery settle.
    const watcher = await socket(host, owner.session)
    watcher.send({ t: "subscribe", stream: chief })
    await watcher.until((f) => f.t === "owner.status" && f.status === "online")
    back.send({ t: "request-settled", to: "mailbox", tx: "tx-2", idempotency_key: "m-1", stream: chief, sequence: 2, ok: true })
    back.send({ t: "request-settled", to: "mailbox", tx: "tx-3", idempotency_key: "m-2", stream: chief, sequence: 3, ok: true })
    await watcher.until((f) => f.t === "mailbox.settled" && f.idempotency_key === "m-1" && f.ok === true)
    await watcher.until((f) => f.t === "mailbox.settled" && f.idempotency_key === "m-2" && f.ok === true)

    // Settled entries are gone: the next reconnect delivers nothing again.
    back.ws.close(1000, "restart")
    const third = await socket(host, owner.installToken)
    third.send({ t: "nothing" })
    await third.until((f) => f.t === "welcome")
    await new Promise((r) => setTimeout(r, 50))
    expect(third.frames.some((f) => f.t === "op")).toBe(false)
  })

  it("re-sends an unanswered mailbox entry after a reconnect and drops it on a final refusal", async () => {
    const { owner, host } = await enroll("mailbox-retry")
    const chief = `host:${host}/chief`
    const phone = await socket(host, owner.session)
    await phone.until((f) => f.t === "welcome")
    phone.send(send(chief, "m-1", "hello"))
    await phone.until((f) => f.t === "op.queued")

    // Delivered but unanswered (the Mac dropped): it comes again on the next connect.
    const one = await socket(host, owner.installToken)
    await one.until((f) => f.t === "op" && f.to === "mailbox")
    one.ws.close(1000, "crash")
    const two = await socket(host, owner.installToken)
    const again = await two.until((f) => f.t === "op" && f.to === "mailbox")
    expect(two.frames[again].idempotency_key).toBe("m-1")

    // A final refusal from the host removes it and tells readers.
    phone.send({ t: "subscribe", stream: chief })
    await phone.until((f) => f.t === "owner.status" && f.status === "online")
    two.send({ t: "reject", to: "mailbox", stream: chief, idempotency_key: "m-1", code: "validation.invalid", message: "no", retryable: false })
    two.send({ t: "request-settled", to: "mailbox", tx: "", idempotency_key: "m-1", stream: chief, sequence: 0, ok: false })
    await phone.until((f) => f.t === "mailbox.settled" && f.idempotency_key === "m-1" && f.ok === false)
    two.ws.close(1000, "restart")
    const three = await socket(host, owner.installToken)
    await three.until((f) => f.t === "welcome")
    await new Promise((r) => setTimeout(r, 50))
    expect(three.frames.some((f) => f.t === "op")).toBe(false)
  })

  it("forgets the mailbox on the host's off switch", async () => {
    const { owner, host } = await enroll("mailbox-purge")
    const chief = `host:${host}/chief`
    const phone = await socket(host, owner.session)
    await phone.until((f) => f.t === "welcome")
    phone.send(send(chief, "m-1", "secret"))
    await phone.until((f) => f.t === "op.queued")
    const pub = await socket(host, owner.installToken)
    await pub.until((f) => f.t === "op" && f.to === "mailbox")
    pub.send({ t: "replica.purge" })
    await pub.until((f) => f.t === "replica.purged")
    pub.ws.close(1000, "off")
    const back = await socket(host, owner.installToken)
    await back.until((f) => f.t === "welcome")
    await new Promise((r) => setTimeout(r, 50))
    expect(back.frames.some((f) => f.t === "op")).toBe(false)
  })
})
