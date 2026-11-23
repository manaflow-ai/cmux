import { exportPKCS8, generateKeyPair } from "jose"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, describe, expect, it, vi } from "vitest"
import { env } from "cloudflare:workers"
import worker from "../src/index.ts"
import { collapseId, MAX_RETRACT, parseRetract, retractPayload, retractRequest, retractTargets } from "../src/push.ts"
import type { PushRegistration } from "../src/store.ts"
import { call, register, token } from "./helpers.ts"

// PROTOCOL.md "Retracting a resolved push": an ask answered on the Mac (or anywhere), or a finished turn whose
// chat started a new turn, leaves the phone. The Mac names the pushes; the Worker sends each phone that got one a
// background push naming the collapse ids those pushes were sent with.

const MAC = "11111111-1111-4111-8111-111111111111"
const OTHER = "22222222-2222-4222-8222-222222222222"
const reg = (over: Partial<PushRegistration> = {}): PushRegistration => ({
  deviceId: "d1",
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

afterEach(() => vi.restoreAllMocks())

describe("retract body", () => {
  it("takes 1 to MAX_RETRACT pushes with valid ids and kinds, and refuses the rest", () => {
    expect(parseRetract({ clear: [{ eventId: "p-1", kind: "question", sessionId: "s1" }, { eventId: "t-s1-2", kind: "completed" }] })).toEqual([
      { eventId: "p-1", kind: "question", sessionId: "s1" },
      { eventId: "t-s1-2", kind: "completed" }
    ])
    for (const bad of [
      {},
      { clear: [] },
      { clear: Array.from({ length: MAX_RETRACT + 1 }, (_, i) => ({ eventId: `p-${i}`, kind: "question" })) },
      { clear: [{ eventId: "p 1", kind: "question" }] },
      { clear: [{ eventId: "p-1", kind: "resolved" }] },
      { clear: [{ eventId: "p-1", kind: "question", sessionId: "a/b" }] },
      { clear: ["p-1"] }
    ])
      expect(typeof parseRetract(bad as Record<string, unknown>)).toBe("string")
  })
})

describe("retract push", () => {
  it("is a silent background push naming each push's collapse id and event id", async () => {
    const items = [
      { eventId: "p-perm1", kind: "question" as const, sessionId: "s1" },
      { eventId: "t-s1-9", kind: "completed" as const, sessionId: "s1" },
      { eventId: "t-s1-10", kind: "failed" as const, sessionId: "s1" }
    ]
    const p = retractPayload(MAC, items)
    // The same collapse ids the alerts went out with: an ask its own, a turn end one per session.
    expect(p.cmuxRetract.ids).toEqual([collapseId({ ...items[0]!, macId: MAC }), collapseId({ ...items[1]!, macId: MAC })])
    expect(p.cmuxRetract.ids).toEqual(["p-perm1", "turn-s1"])
    expect(p.cmuxRetract.events).toEqual(["p-perm1", "t-s1-9", "t-s1-10"])
    expect(p.aps).toEqual({ "content-available": 1 })
    expect(p.cmuxRetract.mac).toBe(MAC)
    // No alert, sound or content: a phone on an older app shows nothing.
    expect(JSON.stringify(p)).not.toMatch(/alert|sound|title|body/)

    const req = retractRequest(reg({ token: "ab" }), MAC, items, "jwt", 1_000_000)
    expect(req.url).toBe("https://api.push.apple.com/3/device/ab")
    expect(req.headers.get("apns-push-type")).toBe("background")
    expect(req.headers.get("apns-priority")).toBe("5")
    expect(req.headers.get("apns-collapse-id")).toBeNull()
    expect(req.headers.get("apns-topic")).toBe("dev.cmux.mobile")
    expect(await req.json()).toEqual(p)
  })

  it("goes only to phones that got the push: the kind wanted, the Mac not muted", async () => {
    const items = [{ eventId: "p-1", kind: "question" as const, sessionId: "s1" }, { eventId: "t-1", kind: "completed" as const, sessionId: "s2" }]
    const regs = [
      reg({ deviceId: "all" }),
      reg({ deviceId: "asks", kinds: ["question"] }),
      reg({ deviceId: "terminal-only", kinds: ["terminal"] }),
      reg({ deviceId: "muted", mutedMacs: [MAC] }),
      reg({ deviceId: "muted-other", mutedMacs: [OTHER] })
    ]
    expect(retractTargets(regs, MAC, items).map((r) => r.deviceId)).toEqual(["all", "asks", "muted-other"])
    // A phone that wants only asks is told only of the ask.
    const body = (await retractRequest(reg({ kinds: ["question"] }), MAC, items, "jwt", 0).json()) as ReturnType<typeof retractPayload>
    expect(body.cmuxRetract.ids).toEqual(["p-1"])
  })
})

describe("POST /v1/devices/:macId/retract", () => {
  const apns = async () => {
    const { privateKey } = await generateKeyPair("ES256", { extractable: true })
    const apnsEnv = { ...env, APNS_KEY_P8: await exportPKCS8(privateKey), APNS_KEY_ID: "KEY123", APNS_TEAM_ID: "TEAM123" }
    const sent: Array<{ token: string; type: string | null; body: any }> = []
    const realFetch = globalThis.fetch
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const req = input instanceof Request ? input : new Request(String(input), init)
      if (req.url.startsWith("https://api.push.apple.com/3/device/")) {
        sent.push({ token: req.url.slice("https://api.push.apple.com/3/device/".length), type: req.headers.get("apns-push-type"), body: await req.json() })
        return new Response(null, { status: 200 })
      }
      return realFetch(input, init)
    })
    const post = async (t: string, mac: string, path: string, body: unknown) => {
      const ctx = createExecutionContext()
      const res = await worker.fetch(
        new Request(`https://api.test/v1/devices/${mac}/${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) }),
        apnsEnv as unknown as Parameters<typeof worker.fetch>[1],
        ctx
      )
      await waitOnExecutionContext(ctx)
      return { status: res.status, json: (await res.json()) as any }
    }
    return { sent, post }
  }

  it("clears an answered ask on the phone that got it, from the owner's Mac only", async () => {
    const t = await token("retra")
    const mac = await register(t, "mac", "personal-retra")
    const phone = await register(t, "phone", "personal-retra")
    const tok = "ef".repeat(32)
    expect((await call("PUT", `/v1/devices/${phone}/push`, t, { token: tok, environment: "production", topic: "dev.cmux.mobile", kinds: ["question", "completed"] })).status).toBe(200)
    const { sent, post } = await apns()
    const ask = { eventId: "p-perm9", kind: "question", sessionId: "s1", agent: "Claude" }
    expect((await post(t, mac, "notify", ask)).json).toMatchObject({ sent: 1 })
    const r = await post(t, mac, "retract", { clear: [{ eventId: "p-perm9", kind: "question", sessionId: "s1" }] })
    expect(r.status).toBe(200)
    expect(r.json).toMatchObject({ configured: true, sent: 1, failed: 0 })
    const retract = sent[1]!
    expect(retract.token).toBe(tok)
    expect(retract.type).toBe("background")
    // The alert went out with this collapse id, so the phone's notification has it as its identifier.
    expect(retract.body.cmuxRetract.ids).toEqual(["p-perm9"])

    // A kind no phone wants reaches none; a bad body is refused; another person's Mac is refused.
    expect((await post(t, mac, "retract", { clear: [{ eventId: "x-1", kind: "terminal" }] })).json).toMatchObject({ sent: 0 })
    expect((await post(t, mac, "retract", { clear: [] })).status).toBe(400)
    const stranger = await token("retrb")
    expect((await post(stranger, mac, "retract", { clear: [{ eventId: "p-perm9", kind: "question" }] })).status).toBe(403)
    expect(sent).toHaveLength(2)
  })
})
