import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { apnsRequest, MAILBOX_TTL_MS, parseNotify, sealedPayload, type NotifyEvent } from "../src/push.ts"
import type { PushRegistration } from "../src/store.ts"
import type { TeamHub } from "../src/team-hub.ts"
import { call, connect, register, token } from "./helpers.ts"

// PROTOCOL.md "Sealed pushes and the reply mailbox" (API 0.14.0).

const MAC = "11111111-1111-4111-8111-111111111111"
const PHONE = "33333333-3333-4333-8333-333333333333"
const SIG = "ab".repeat(64)
const BOX = "A".repeat(400)
const sealedBox = (n = 200) => "x".repeat(n)

const reg = (over: Partial<PushRegistration> = {}): PushRegistration => ({
  deviceId: PHONE,
  space: "",
  ownerUserId: "o",
  token: "aa",
  environment: "production",
  topic: "dev.cmux.mobile",
  kinds: ["question", "permission", "completed", "failed", "chief", "terminal"],
  mutedMacs: [],
  previews: true,
  updatedAt: "",
  ...over
})

describe("sealed notify", () => {
  it("accepts a per-phone box and signature and refuses malformed ones", () => {
    const ok = parseNotify({ eventId: "p-1", kind: "question", sessionId: "s1", sealed: { [PHONE]: { box: BOX, sig: SIG } } })
    if (typeof ok === "string") throw new Error(ok)
    expect(ok.sealed).toEqual({ [PHONE]: { box: BOX, sig: SIG } })
    for (const sealed of [
      "nope",
      { "not-a-uuid": { box: BOX, sig: SIG } },
      { [PHONE]: { box: "has spaces!", sig: SIG } },
      { [PHONE]: { box: "A".repeat(3073), sig: SIG } },
      { [PHONE]: { box: BOX, sig: "zz" } },
      { [PHONE]: { box: BOX, sig: "ab".repeat(63) } },
      Object.fromEntries(Array.from({ length: 21 }, () => [crypto.randomUUID(), { box: BOX, sig: SIG }]))
    ])
      expect(typeof parseNotify({ eventId: "p-1", kind: "question", sealed })).toBe("string")
  })

  it("sends a sealed phone only the box, a generic banner and a hashed thread", () => {
    const e: NotifyEvent = {
      eventId: "p-1",
      kind: "question",
      macId: MAC,
      macName: "Mac mini",
      sessionId: "secret-session",
      title: "Deploy the API key sk-123?",
      tail: ["private output"],
      sealed: { [PHONE]: { box: BOX, sig: SIG } }
    }
    const p = sealedPayload(e, { box: BOX, sig: SIG })
    expect(p.aps.alert).toEqual({ title: "cmux", body: "New notification from Mac mini" })
    expect(p.aps["mutable-content"]).toBe(1)
    expect(p.aps["interruption-level"]).toBe("time-sensitive")
    expect(p.aps["thread-id"]).toMatch(/^[0-9a-f]{16}$/)
    // The Mac's name and the phone's Show previews travel with it (PR B review 5); no buttons until opened (H1).
    expect(p.cmuxMobile).toEqual({ v: 3, mac: MAC, macName: "Mac mini", kind: "question", eventId: "p-1", previews: true, box: BOX, sig: SIG })
    expect(p.aps.category).toBe("CMUX_MOBILE_SEALED")
    expect(sealedPayload(e, { box: BOX, sig: SIG }, { previews: false }).cmuxMobile.previews).toBe(false)
    const text = JSON.stringify(p)
    for (const secret of ["sk-123", "private output", "secret-session"]) expect(text).not.toContain(secret)
  })

  it("seals per target: a phone with a box gets v3, one without gets v2", async () => {
    const e: NotifyEvent = { eventId: "t-1", kind: "completed", macId: MAC, macName: "Mac", sessionId: "s1", sealed: { [PHONE]: { box: BOX, sig: SIG } } }
    const sealedBody = JSON.parse(await apnsRequest(reg(), e, "tok", 0).text())
    expect(sealedBody.cmuxMobile.v).toBe(3)
    const hidden = JSON.parse(await apnsRequest(reg({ previews: false }), e, "tok", 0).text())
    expect(hidden.cmuxMobile.previews).toBe(false)
    const plainBody = JSON.parse(await apnsRequest(reg({ deviceId: crypto.randomUUID() }), e, "tok", 0).text())
    expect(plainBody.cmuxMobile.v).toBe(2)
    expect(plainBody.cmuxMobile.sealed).toBeUndefined()
  })
})

const post = (t: string, mac: string, body: Record<string, unknown>) => call("POST", `/v1/devices/${mac}/mailbox`, t, body)

describe("reply mailbox limits", () => {
  it("takes a sealed reply up to 16384 characters: a 4096-byte text that escapes long still fits", async () => {
    const t = await token("sizer")
    const mac = await register(t, "mac", "personal-sizer")
    const phone = await register(t, "phone", "personal-sizer")
    expect((await post(t, mac, { id: crypto.randomUUID(), from: phone, sealed: "A".repeat(16_384) })).status).toBe(200)
    expect((await post(t, mac, { id: crypto.randomUUID(), from: phone, sealed: "A".repeat(16_385) })).status).toBe(400)
  })
})

describe("reply mailbox (HTTP)", () => {
  it("queues a sealed reply from the owner's phone to the owner's Mac and reports its state", async () => {
    const t = await token("mia")
    const mac = await register(t, "mac", "personal-mia")
    const phone = await register(t, "phone", "personal-mia")
    const id = crypto.randomUUID()
    const r = await post(t, mac, { id, from: phone, sealed: sealedBox() })
    expect(r).toMatchObject({ status: 200, json: { queued: true, delivered: false, seq: 1, expiresAt: expect.any(Number) } })
    // The same id again is the same item (a retried request), not a second one.
    expect((await post(t, mac, { id, from: phone, sealed: sealedBox() })).json).toMatchObject({ queued: true })
    expect((await post(t, mac, { id, from: phone, sealed: sealedBox(201) })).status).toBe(409)
    expect((await call("GET", `/v1/devices/${mac}/mailbox/${id}`, t)).json).toEqual({ state: "queued", seq: 1, expiresAt: expect.any(Number) })
    expect((await call("GET", `/v1/devices/${mac}/mailbox/${crypto.randomUUID()}`, t)).status).toBe(404)
  })

  it("refuses another user's devices, a Mac as the sender, a phone as the target and bad bodies", async () => {
    const t = await token("ned")
    const mac = await register(t, "mac", "personal-ned")
    const phone = await register(t, "phone", "personal-ned")
    const other = await token("ola")
    const otherMac = await register(other, "mac", "personal-ola")
    const otherPhone = await register(other, "phone", "personal-ola")
    expect((await post(t, otherMac, { id: crypto.randomUUID(), from: phone, sealed: sealedBox() })).status).toBe(403)
    expect((await post(t, mac, { id: crypto.randomUUID(), from: otherPhone, sealed: sealedBox() })).status).toBe(403)
    expect((await post(t, mac, { id: crypto.randomUUID(), from: mac, sealed: sealedBox() })).status).toBe(403)
    expect((await post(t, phone, { id: crypto.randomUUID(), from: phone, sealed: sealedBox() })).status).toBe(403)
    expect((await post(t, mac, { id: "nope", from: phone, sealed: sealedBox() })).status).toBe(400)
    expect((await post(t, mac, { id: crypto.randomUUID(), from: phone, sealed: "not base64url!" })).status).toBe(400)
    expect((await post(t, mac, { id: crypto.randomUUID(), from: phone, sealed: "x".repeat(16_385) })).status).toBe(400)
    // Another user cannot read an item's state either.
    const id = crypto.randomUUID()
    await post(t, mac, { id, from: phone, sealed: sealedBox() })
    expect((await call("GET", `/v1/devices/${mac}/mailbox/${id}`, other)).status).toBe(403)
  })

  it("holds at most 32 pending items per Mac", async () => {
    const t = await token("pia")
    const mac = await register(t, "mac", "personal-pia")
    const phone = await register(t, "phone", "personal-pia")
    for (let i = 0; i < 32; i++) expect((await post(t, mac, { id: crypto.randomUUID(), from: phone, sealed: sealedBox() })).status).toBe(200)
    expect((await post(t, mac, { id: crypto.randomUUID(), from: phone, sealed: sealedBox() })).status).toBe(429)
  })

  it("delivers to the Mac's socket after hello, and at once while it is open; the Mac's ack settles the state", async () => {
    const t = await token("quin")
    const mac = await register(t, "mac", "personal-quin")
    const phone = await register(t, "phone", "personal-quin")
    const early = crypto.randomUUID()
    await post(t, mac, { id: early, from: phone, sealed: sealedBox() })
    const s = await connect(t, "personal-quin", mac)
    await s.until((x) => x.frames.some((f) => f.type === "mailbox"))
    expect(s.frames[0].type).toBe("hello")
    const first = s.frames.find((f) => f.type === "mailbox")
    expect(first.items).toEqual([{ id: early, from: phone, sealed: sealedBox(), at: expect.any(Number), seq: 1 }])
    const live = crypto.randomUUID()
    expect((await post(t, mac, { id: live, from: phone, sealed: sealedBox() })).json).toMatchObject({ delivered: true })
    await s.until((x) => x.frames.filter((f) => f.type === "mailbox").length === 2)
    // The Mac signs each outcome; the hub keeps the signature as sent so the phone can check it.
    s.send({ type: "mailbox_ack", results: [{ id: early, applied: true, sig: SIG }, { id: live, applied: false, reason: "not_pending", sig: "not hex" }] })
    const state = async (id: string) => (await call("GET", `/v1/devices/${mac}/mailbox/${id}`, t)).json
    for (let i = 0; i < 40 && (await state(live)).state === "queued"; i++) await new Promise((r) => setTimeout(r, 25))
    expect(await state(early)).toEqual({ state: "applied", sig: SIG, seq: 1, expiresAt: expect.any(Number) })
    expect(await state(live)).toEqual({ state: "rejected", reason: "not_pending", seq: 2, expiresAt: expect.any(Number) })
    // A settled item is not delivered again on the next connection.
    s.ws.close()
    const again = await connect(t, "personal-quin", mac)
    await again.until((x) => x.frames.some((f) => f.type === "hello"))
    await new Promise((r) => setTimeout(r, 100))
    expect(again.frames.some((f) => f.type === "mailbox")).toBe(false)
    again.ws.close()
  })

  it("takes mailbox_ack only from a Mac, and only for that Mac's items", async () => {
    const t = await token("rex")
    const mac = await register(t, "mac", "personal-rex")
    const mac2 = await register(t, "mac", "personal-rex")
    const phone = await register(t, "phone", "personal-rex")
    const id = crypto.randomUUID()
    await post(t, mac, { id, from: phone, sealed: sealedBox() })
    const p = await connect(t, "personal-rex", phone)
    p.send({ type: "mailbox_ack", results: [{ id, applied: true }] })
    await p.until((x) => x.frames.some((f) => f.type === "error"))
    const other = await connect(t, "personal-rex", mac2)
    other.send({ type: "mailbox_ack", results: [{ id, applied: true }] })
    other.send({ type: "mailbox_ack", results: "bad" })
    await other.until((x) => x.frames.some((f) => f.type === "error"))
    expect((await call("GET", `/v1/devices/${mac}/mailbox/${id}`, t)).json).toMatchObject({ state: "queued" })
    p.ws.close()
    other.ws.close()
  })

  it("expires an item after its time to live, and never delivers it then", async () => {
    expect(MAILBOX_TTL_MS).toBe(600_000)
    const t = await token("sol")
    const mac = await register(t, "mac", "personal-sol")
    const phone = await register(t, "phone", "personal-sol")
    const ns = (env as unknown as { TEAM_HUB: DurableObjectNamespace<TeamHub> }).TEAM_HUB
    const hub = ns.get(ns.idFromName("user:sol"))
    const id = crypto.randomUUID()
    expect(await hub.mailboxPost("sol", { id, mac, from: phone, sealed: sealedBox() }, 1)).toMatchObject({ queued: true })
    await new Promise((r) => setTimeout(r, 10))
    expect((await call("GET", `/v1/devices/${mac}/mailbox/${id}`, t)).json).toMatchObject({ state: "expired" })
    const s = await connect(t, "personal-sol", mac)
    await s.until((x) => x.frames.some((f) => f.type === "hello"))
    await new Promise((r) => setTimeout(r, 100))
    expect(s.frames.some((f) => f.type === "mailbox")).toBe(false)
    s.ws.close()
  })
})

// PROTOCOL.md "Store and forward" (API 0.18.0): seq per (Mac, phone), long holds, paged delivery.
describe("store and forward", () => {
  const hubOf = (user: string) => {
    const ns = (env as unknown as { TEAM_HUB: DurableObjectNamespace<TeamHub> }).TEAM_HUB
    return ns.get(ns.idFromName(`user:${user}`))
  }
  const wait = (ms: number) => new Promise((r) => setTimeout(r, ms))

  it("numbers each (Mac, phone) pair's items 1, 2, 3, never reuses one, and answers a retry its first seq", async () => {
    const t = await token("sf-seq")
    const mac = await register(t, "mac", "personal-sf-seq")
    const phone = await register(t, "phone", "personal-sf-seq")
    const phone2 = await register(t, "phone", "personal-sf-seq")
    const a = crypto.randomUUID()
    expect((await post(t, mac, { id: a, from: phone, sealed: sealedBox() })).json).toMatchObject({ seq: 1 })
    expect((await post(t, mac, { id: crypto.randomUUID(), from: phone, sealed: sealedBox() })).json).toMatchObject({ seq: 2 })
    expect((await post(t, mac, { id: crypto.randomUUID(), from: phone2, sealed: sealedBox() })).json).toMatchObject({ seq: 1 })
    expect((await post(t, mac, { id: a, from: phone, sealed: sealedBox() })).json).toMatchObject({ queued: true, delivered: false, seq: 1 })
    // Settled and gone: the pair's next item still takes the next number.
    const s = await connect(t, "personal-sf-seq", mac)
    const first = await s.until((x) => x.frames.some((f) => f.type === "mailbox"))
    void first
    const items = s.frames.find((f) => f.type === "mailbox").items as Array<{ id: string; seq: number }>
    s.send({ type: "mailbox_ack", results: items.map((i) => ({ id: i.id, applied: true, sig: SIG })) })
    await wait(50)
    expect((await post(t, mac, { id: crypto.randomUUID(), from: phone, sealed: sealedBox() })).json).toMatchObject({ seq: 3 })
    s.ws.close()
  })

  it("takes a hold of 1 to 86400 s and refuses anything else", async () => {
    const t = await token("sf-hold")
    const mac = await register(t, "mac", "personal-sf-hold")
    const phone = await register(t, "phone", "personal-sf-hold")
    const before = Date.now()
    const r = await post(t, mac, { id: crypto.randomUUID(), from: phone, sealed: sealedBox(), hold: 86_400 })
    expect(r.status).toBe(200)
    expect(r.json.expiresAt).toBeGreaterThanOrEqual(before + 86_400_000)
    for (const hold of [0, -1, 86_401, 1.5, "600", null])
      expect((await post(t, mac, { id: crypto.randomUUID(), from: phone, sealed: sealedBox(), hold })).status).toBe(400)
    // No hold: 10 minutes, as an older phone gets.
    const plain = await post(t, mac, { id: crypto.randomUUID(), from: phone, sealed: sealedBox() })
    expect(plain.json.expiresAt - Date.now()).toBeLessThanOrEqual(600_000)
  })

  it("bounds long holds per (Mac, phone) by count and bytes, apart from the 32 short ones per Mac", async () => {
    const t = await token("sf-bound")
    const mac = await register(t, "mac", "personal-sf-bound")
    const phone = await register(t, "phone", "personal-sf-bound")
    const phone2 = await register(t, "phone", "personal-sf-bound")
    for (let i = 0; i < 32; i++) expect((await post(t, mac, { id: crypto.randomUUID(), from: phone, sealed: sealedBox() })).status).toBe(200)
    expect((await post(t, mac, { id: crypto.randomUUID(), from: phone, sealed: sealedBox() })).status).toBe(429)
    // Long holds still fit: they count per pair.
    const hub = hubOf("sf-bound")
    for (let i = 0; i < 64; i++) expect(await hub.mailboxPost("sf-bound", { id: crypto.randomUUID(), mac, from: phone, sealed: sealedBox() }, 3_600_000)).toMatchObject({ queued: true })
    expect(await hub.mailboxPost("sf-bound", { id: crypto.randomUUID(), mac, from: phone, sealed: sealedBox() }, 3_600_000)).toEqual({ error: "full" })
    // Another phone has its own bound; 32 boxes of 16384 characters fill its 524288.
    for (let i = 0; i < 32; i++)
      expect(await hub.mailboxPost("sf-bound", { id: crypto.randomUUID(), mac, from: phone2, sealed: "A".repeat(16_384) }, 3_600_000)).toMatchObject({ queued: true })
    expect(await hub.mailboxPost("sf-bound", { id: crypto.randomUUID(), mac, from: phone2, sealed: "A" }, 3_600_000)).toEqual({ error: "full" })
  }, 30_000)

  it("holds an item for its own hold and reports expired once it passed", async () => {
    const t = await token("sf-exp")
    const mac = await register(t, "mac", "personal-sf-exp")
    const phone = await register(t, "phone", "personal-sf-exp")
    const hub = hubOf("sf-exp")
    const id = crypto.randomUUID()
    expect(await hub.mailboxPost("sf-exp", { id, mac, from: phone, sealed: sealedBox() }, 1_000)).toMatchObject({ seq: 1 })
    expect((await call("GET", `/v1/devices/${mac}/mailbox/${id}`, t)).json).toMatchObject({ state: "queued", seq: 1 })
    await wait(1_050)
    expect((await call("GET", `/v1/devices/${mac}/mailbox/${id}`, t)).json).toMatchObject({ state: "expired", seq: 1 })
  })

  it("delivers in pages of 32 ordered by phone then seq, the next page after each ack, and unacked items again on the next socket", async () => {
    const t = await token("sf-page")
    const mac = await register(t, "mac", "personal-sf-page")
    const phone = await register(t, "phone", "personal-sf-page")
    const hub = hubOf("sf-page")
    const ids: string[] = []
    for (let i = 0; i < 64; i++) {
      const id = crypto.randomUUID()
      ids.push(id)
      await hub.mailboxPost("sf-page", { id, mac, from: phone, sealed: sealedBox() }, 3_600_000)
    }
    const s = await connect(t, "personal-sf-page", mac)
    await s.until((x) => x.frames.some((f) => f.type === "mailbox"))
    await wait(50)
    const pages = () => s.frames.filter((f) => f.type === "mailbox").map((f) => f.items as Array<{ id: string; seq: number }>)
    expect(pages().length).toBe(1)
    expect(pages()[0]!.map((i) => i.seq)).toEqual(Array.from({ length: 32 }, (_, i) => i + 1))
    // A live post while 32 wait for their ack is not sent yet.
    expect((await post(t, mac, { id: crypto.randomUUID(), from: phone, sealed: sealedBox() })).json).toMatchObject({ delivered: false, seq: 65 })
    // Ack half the page: half a page more goes.
    s.send({ type: "mailbox_ack", results: pages()[0]!.slice(0, 16).map((i) => ({ id: i.id, applied: true, sig: SIG })) })
    await s.until((x) => x.frames.filter((f) => f.type === "mailbox").length === 2)
    expect(pages()[1]!.map((i) => i.seq)).toEqual(Array.from({ length: 16 }, (_, i) => i + 33))
    s.ws.close()
    // The next socket gets everything still queued again, from the lowest seq.
    const again = await connect(t, "personal-sf-page", mac)
    await again.until((x) => x.frames.some((f) => f.type === "mailbox"))
    const next = again.frames.find((f) => f.type === "mailbox").items as Array<{ seq: number }>
    expect(next.map((i) => i.seq)).toEqual(Array.from({ length: 32 }, (_, i) => i + 17))
    again.ws.close()
  }, 30_000)

  it("counts unacked items per phone: one phone's held page never starves another phone", async () => {
    const t = await token("sf-fair")
    const mac = await register(t, "mac", "personal-sf-fair")
    const phoneA = await register(t, "phone", "personal-sf-fair")
    const phoneB = await register(t, "phone", "personal-sf-fair")
    const hub = hubOf("sf-fair")
    for (let i = 0; i < 40; i++) await hub.mailboxPost("sf-fair", { id: crypto.randomUUID(), mac, from: phoneA, sealed: sealedBox() }, 3_600_000)
    const b1 = crypto.randomUUID()
    await hub.mailboxPost("sf-fair", { id: b1, mac, from: phoneB, sealed: sealedBox() }, 3_600_000)
    const s = await connect(t, "personal-sf-fair", mac)
    // Phone A's 32 and phone B's item all go out on the same hello (two frames), not after an ack.
    await s.until((x) => x.frames.filter((f) => f.type === "mailbox").reduce((n, f) => n + (f.items as unknown[]).length, 0) >= 33)
    const frames = () => s.frames.filter((f) => f.type === "mailbox").map((f) => f.items as Array<{ id: string; from: string; seq: number }>)
    expect(frames().every((f) => f.length <= 32)).toBe(true)
    const all = frames().flat()
    expect(all.filter((i) => i.from === phoneA).length).toBe(32)
    expect(all.filter((i) => i.from === phoneB).map((i) => i.id)).toEqual([b1])
    // With A's 32 still held (never acked), a new item from B is sent at once; one more from A is not.
    expect((await post(t, mac, { id: crypto.randomUUID(), from: phoneB, sealed: sealedBox() })).json).toMatchObject({ delivered: true, seq: 2 })
    expect((await post(t, mac, { id: crypto.randomUUID(), from: phoneA, sealed: sealedBox() })).json).toMatchObject({ delivered: false })
    s.ws.close()
  }, 30_000)

  it("keeps the older Mac's contract: every item still carries id, from, sealed and at", async () => {
    const t = await token("sf-old")
    const mac = await register(t, "mac", "personal-sf-old")
    const phone = await register(t, "phone", "personal-sf-old")
    const id = crypto.randomUUID()
    await post(t, mac, { id, from: phone, sealed: sealedBox() })
    const s = await connect(t, "personal-sf-old", mac)
    await s.until((x) => x.frames.some((f) => f.type === "mailbox"))
    const item = s.frames.find((f) => f.type === "mailbox").items[0]
    expect(item).toMatchObject({ id, from: phone, sealed: sealedBox(), at: expect.any(Number) })
    // An older Mac acks without knowing seq; the hub settles by id as before.
    s.send({ type: "mailbox_ack", results: [{ id, applied: true, sig: SIG }] })
    for (let i = 0; i < 40 && (await call("GET", `/v1/devices/${mac}/mailbox/${id}`, t)).json.state === "queued"; i++) await wait(25)
    expect((await call("GET", `/v1/devices/${mac}/mailbox/${id}`, t)).json).toMatchObject({ state: "applied", sig: SIG })
    s.ws.close()
  })
})
