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
    expect(r).toMatchObject({ status: 200, json: { queued: true, delivered: false } })
    // The same id again is the same item (a retried request), not a second one.
    expect((await post(t, mac, { id, from: phone, sealed: sealedBox() })).json).toMatchObject({ queued: true })
    expect((await post(t, mac, { id, from: phone, sealed: sealedBox(201) })).status).toBe(409)
    expect((await call("GET", `/v1/devices/${mac}/mailbox/${id}`, t)).json).toEqual({ state: "queued" })
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
    expect(first.items).toEqual([{ id: early, from: phone, sealed: sealedBox(), at: expect.any(Number) }])
    const live = crypto.randomUUID()
    expect((await post(t, mac, { id: live, from: phone, sealed: sealedBox() })).json).toMatchObject({ delivered: true })
    await s.until((x) => x.frames.filter((f) => f.type === "mailbox").length === 2)
    // The Mac signs each outcome; the hub keeps the signature as sent so the phone can check it.
    s.send({ type: "mailbox_ack", results: [{ id: early, applied: true, sig: SIG }, { id: live, applied: false, reason: "not_pending", sig: "not hex" }] })
    const state = async (id: string) => (await call("GET", `/v1/devices/${mac}/mailbox/${id}`, t)).json
    for (let i = 0; i < 40 && (await state(live)).state === "queued"; i++) await new Promise((r) => setTimeout(r, 25))
    expect(await state(early)).toEqual({ state: "applied", sig: SIG })
    expect(await state(live)).toEqual({ state: "rejected", reason: "not_pending" })
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
    expect((await call("GET", `/v1/devices/${mac}/mailbox/${id}`, t)).json).toEqual({ state: "queued" })
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
    expect((await call("GET", `/v1/devices/${mac}/mailbox/${id}`, t)).json).toEqual({ state: "expired" })
    const s = await connect(t, "personal-sol", mac)
    await s.until((x) => x.frames.some((f) => f.type === "hello"))
    await new Promise((r) => setTimeout(r, 100))
    expect(s.frames.some((f) => f.type === "mailbox")).toBe(false)
    s.ws.close()
  })
})
