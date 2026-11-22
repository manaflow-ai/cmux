import { exportPKCS8, generateKeyPair } from "jose"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, describe, expect, it, vi } from "vitest"
import { env } from "cloudflare:workers"
import worker from "../src/index.ts"
import { call, register, token } from "./helpers.ts"

// No cap on how many phones get a push (PROTOCOL.md "Sealed notify"): the Worker used to send to the first
// 20 push registrations only, and refused a notify with more than 20 boxes, so a person's 21st phone never
// got a push and with 21 phones paired to a sealing Mac no phone did.

const SIG = "ab".repeat(64)
const box = (i: number) => `B${i}`.padEnd(400, "A")
const pushToken = (i: number) => (i + 1).toString(16).padStart(64, "0")

afterEach(() => vi.restoreAllMocks())

/** A Mac and `count` phones of one person, each phone registered for pushes of every kind. */
const person = async (name: string, count: number) => {
  const t = await token(name)
  const mac = await register(t, "mac", `personal-${name}`)
  const phones: Array<string> = []
  for (let i = 0; i < count; i++) {
    const phone = await register(t, "phone", `personal-${name}`)
    const r = await call("PUT", `/v1/devices/${phone}/push`, t, { token: pushToken(i), environment: "production", topic: "dev.cmux.mobile", kinds: ["question", "completed"] })
    expect(r.status).toBe(200)
    phones.push(phone)
  }
  return { t, mac, phones }
}

/** APNs answering 200, with what each device token was sent. */
const apns = async () => {
  const { privateKey } = await generateKeyPair("ES256", { extractable: true })
  const apnsEnv = { ...env, APNS_KEY_P8: await exportPKCS8(privateKey), APNS_KEY_ID: "KEY123", APNS_TEAM_ID: "TEAM123" }
  const sent: Array<{ token: string; body: any }> = []
  const realFetch = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const req = input instanceof Request ? input : new Request(String(input), init)
    if (req.url.startsWith("https://api.push.apple.com/3/device/")) {
      sent.push({ token: req.url.slice("https://api.push.apple.com/3/device/".length), body: await req.json() })
      return new Response(null, { status: 200 })
    }
    return realFetch(input, init)
  })
  const notify = async (t: string, mac: string, body: unknown) => {
    const ctx = createExecutionContext()
    const res = await worker.fetch(
      new Request(`https://api.test/v1/devices/${mac}/notify`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) }),
      apnsEnv as unknown as Parameters<typeof worker.fetch>[1],
      ctx
    )
    await waitOnExecutionContext(ctx)
    return { status: res.status, json: (await res.json()) as any }
  }
  return { sent, notify }
}

describe("notify reaches every phone", () => {
  it("sends a plain notify to all 25 phones, not the first 20", async () => {
    const { t, mac, phones } = await person("pax", 25)
    const { sent, notify } = await apns()
    const r = await notify(t, mac, { eventId: "evt-25", kind: "question", agent: "Claude", place: "repo" })
    expect(r.status).toBe(200)
    expect(r.json).toMatchObject({ configured: true, sent: 25, failed: 0 })
    expect(new Set(sent.map((s) => s.token))).toEqual(new Set(phones.map((_, i) => pushToken(i))))
  })

  it("delivers a sealed push to 25 phones in a lead and a batch, each phone once with its own box", async () => {
    const { t, mac, phones } = await person("quin", 25)
    const { sent, notify } = await apns()
    const boxes = (ids: ReadonlyArray<string>) => Object.fromEntries(ids.map((id) => [id, { box: box(phones.indexOf(id)), sig: SIG }]))
    const [first, rest] = [phones.slice(0, 20), phones.slice(20)]
    const routing = { eventId: "evt-sealed", kind: "completed", sessionId: "s1" }
    // One request with all 25 boxes is still refused: the body bound per request stays.
    expect((await notify(t, mac, { ...routing, sealed: boxes(phones) })).status).toBe(400)
    const lead = await notify(t, mac, { ...routing, sealed: boxes(first), batchedPhones: rest })
    expect(lead.json).toMatchObject({ configured: true, sent: 20, batches: true })
    const batch = await notify(t, mac, { ...routing, sealed: boxes(rest), batch: 1 })
    expect(batch.json).toMatchObject({ configured: true, sent: 5 })
    expect(sent).toHaveLength(25)
    expect(new Set(sent.map((s) => s.token)).size).toBe(25)
    for (const s of sent) {
      const i = Number.parseInt(s.token, 16) - 1
      expect(s.body.cmuxMobile).toMatchObject({ v: 3, box: box(i), sig: SIG })
    }
  })

  it("keeps a coalesced turn end to one window, and a batch never re-opens it", async () => {
    const { t, mac, phones } = await person("rue", 21)
    const { sent, notify } = await apns()
    const boxes = (ids: ReadonlyArray<string>) => Object.fromEntries(ids.map((id) => [id, { box: box(phones.indexOf(id)), sig: SIG }]))
    const routing = { kind: "completed", sessionId: "turns" }
    const lead = await notify(t, mac, { ...routing, eventId: "t-1", sealed: boxes(phones.slice(0, 20)), batchedPhones: phones.slice(20) })
    expect(lead.json.sent).toBe(20)
    // The next turn end inside the window is coalesced; the Mac then sends no batch for it.
    expect((await notify(t, mac, { ...routing, eventId: "t-2", sealed: boxes(phones.slice(0, 20)), batchedPhones: phones.slice(20) })).json).toMatchObject({ coalesced: true, sent: 0 })
    // The first event's batch still goes out (it followed a lead that passed).
    expect((await notify(t, mac, { ...routing, eventId: "t-1", sealed: boxes(phones.slice(20)), batch: 1 })).json.sent).toBe(1)
    expect(sent).toHaveLength(21)
  })
})

