import { exportPKCS8, generateKeyPair, jwtVerify } from "jose"
import { describe, expect, it } from "vitest"
import { sendApns, type NotifyEvent } from "../src/push.ts"
import type { PushRegistration } from "../src/store.ts"

// The real sender crosses its HTTP boundary. This endpoint models queued APNs
// delivery, not Apple's service: no credentials, network, simulator or device.
const phone = (token: string, environment: "production" | "sandbox" = "sandbox"): PushRegistration => ({
  deviceId: token, token, environment, topic: "dev.cmux.mobile", ownerUserId: "push-gate",
  space: "", kinds: ["completed", "question"], mutedMacs: [], previews: true, updatedAt: "",
})
const event = (eventId: string, sessionId = "mock-t-claude"): NotifyEvent => ({
  eventId, sessionId, kind: "completed", macId: "mac-studio", macName: "Mac Studio", agent: "Claude Code",
})

async function endpoint() {
  const keys = await generateKeyPair("ES256", { extractable: true })
  // Provider JWTs are cached by team/key ID. Each generated key needs its own ID.
  const config = { keyP8: await exportPKCS8(keys.privateKey), keyId: crypto.randomUUID(), teamId: "test-team" }
  const queued = new Map<string, { cmuxMobile: { eventId: string; sessionId: string }; aps: { alert: unknown; category: string } }>()
  const requests: Request[] = []
  const fetcher = (async (input: RequestInfo | URL) => {
    const request = input instanceof Request ? input : new Request(input)
    requests.push(request.clone())
    const url = new URL(request.url)
    expect(["api.push.apple.com", "api.sandbox.push.apple.com"]).toContain(url.hostname)
    expect(url.pathname).toMatch(/^\/3\/device\/[a-f0-9]{64}$/)
    expect(request.method).toBe("POST")
    expect(request.headers.get("apns-topic")).toBe("dev.cmux.mobile")
    expect(request.headers.get("apns-push-type")).toBe("alert")
    expect(request.headers.get("apns-priority")).toBe("10")
    const token = request.headers.get("authorization")?.replace(/^bearer /, "")
    const verified = await jwtVerify(token!, keys.publicKey, { issuer: "test-team", algorithms: ["ES256"] })
    expect(verified.protectedHeader.kid).toBe(config.keyId)
    const collapse = request.headers.get("apns-collapse-id")
    expect(collapse).toBeTruthy()
    expect(new TextEncoder().encode(collapse!).length).toBeLessThanOrEqual(64)
    const body = await request.text()
    expect(new TextEncoder().encode(body).length).toBeLessThanOrEqual(4096)
    // APNs replaces only the same device/topic/environment/collapse tuple.
    queued.set(`${url.host}${url.pathname}:${request.headers.get("apns-topic")}:${collapse}`, JSON.parse(body))
    return new Response(null, { status: 200 })
  }) as typeof fetch
  return { config, fetcher, queued, requests }
}

describe("headless APNs delivery gate", () => {
  it("signs and delivers alert payloads to both APNs environments with routing intact", async () => {
    const mock = await endpoint()
    const targets = [phone("a".repeat(64)), phone("b".repeat(64), "production")]
    const result = await sendApns(mock.config, targets, event("delivery-1"), Date.now(), mock.fetcher)
    expect(result.map((r) => [r.outcome, r.status])).toEqual([["sent", 200], ["sent", 200]])
    expect(mock.requests.map((r) => new URL(r.url).host).sort()).toEqual(["api.push.apple.com", "api.sandbox.push.apple.com"])
    expect(mock.queued.size).toBe(2)
    for (const body of mock.queued.values()) {
      expect(body.cmuxMobile).toMatchObject({ eventId: "delivery-1", sessionId: "mock-t-claude", mac: "mac-studio" })
      expect(body.aps.alert).toBeTruthy()
      expect(body.aps.category).toBe("CMUX_MOBILE_COMPLETED")
    }
  })

  it("replaces an offline turn with its latest event without losing other sessions or phones", async () => {
    const mock = await endpoint()
    const targets = [phone("a".repeat(64)), phone("b".repeat(64))]
    for (const e of [event("old"), event("independent", "other-session"), event("latest")]) {
      const results = await sendApns(mock.config, targets, e, Date.now(), mock.fetcher)
      expect(results.map((r) => ({ outcome: r.outcome, reason: r.reason }))).toEqual(targets.map(() => ({ outcome: "sent", reason: undefined })))
    }
    expect(mock.requests).toHaveLength(6)
    expect([...mock.queued.values()].map((p) => p.cmuxMobile.eventId).sort()).toEqual(["independent", "independent", "latest", "latest"])
  })

  it("does not collapse separate questions in one session", async () => {
    const mock = await endpoint()
    for (const eventId of ["question-a", "question-b"]) {
      const result = await sendApns(mock.config, [phone("c".repeat(64))], { ...event(eventId), kind: "question" }, Date.now(), mock.fetcher)
      expect(result[0]).toMatchObject({ outcome: "sent", status: 200 })
    }
    expect([...mock.queued.values()].map((p) => p.cmuxMobile.eventId).sort()).toEqual(["question-a", "question-b"])
  })

  it.each([[410, "Unregistered", "drop_target"], [429, "TooManyRequests", "failed"], [503, "ServiceUnavailable", "failed"]] as const)(
    "reports endpoint refusal %s rather than claiming delivery", async (status, reason, outcome) => {
      const mock = await endpoint()
      const fetcher = (async () => Response.json({ reason }, { status })) as typeof fetch
      const result = await sendApns(mock.config, [phone("d".repeat(64))], event("refused"), Date.now(), fetcher)
      expect(result[0]).toMatchObject({ status, reason, outcome })
    },
  )
})
