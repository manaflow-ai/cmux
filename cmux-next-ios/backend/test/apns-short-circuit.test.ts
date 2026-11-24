import { exportPKCS8, generateKeyPair } from "jose"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, describe, expect, it, vi } from "vitest"
import { env } from "cloudflare:workers"
import worker from "../src/index.ts"
import { APNS_IN_FLIGHT, classifyApns, KEY_OR_TOPIC_REASONS, sendApns, sendCloudAttention } from "../src/push.ts"
import type { PushRegistration } from "../src/store.ts"
import { call, register, token } from "./helpers.ts"

// The iOS push probe (cmuxterm-hq goals/ios-push-e2e.md) measured about 26 APNs sends per finished turn, every one
// refused 400 TopicDisallowed: an answer about the key and topic, so each send after the first only cost time, and
// hostd's answer waited for all of them. A key- or topic-level refusal now stops the rest of that environment and
// topic for the event, and never drops a registration.

afterEach(() => vi.restoreAllMocks())

const event = { eventId: "e1", kind: "question" as const, agent: "Claude", place: "cmux", macId: "m1", macName: "Studio", sessionId: "s1" }
const target = (tok: string, environment: "sandbox" | "production", topic: string): PushRegistration => ({
  deviceId: tok,
  space: "",
  ownerUserId: "o",
  token: tok,
  environment,
  topic,
  kinds: ["question"],
  mutedMacs: [],
  previews: true,
  updatedAt: ""
})
const config = async () => {
  const { privateKey } = await generateKeyPair("ES256", { extractable: true })
  return { keyP8: await exportPKCS8(privateKey), keyId: "KEY123", teamId: "TEAM123" }
}
const apnsAnswer = (status: number, reason?: string) => new Response(reason ? JSON.stringify({ reason }) : null, { status })
const skipLogs = (log: ReturnType<typeof vi.spyOn>) =>
  log.mock.calls.map((c: Array<unknown>) => String(c[0])).filter((line: string) => line.includes('"apns skipped"')).map((line: string) => JSON.parse(line))

describe("APNs short circuit", () => {
  it("drops a registration only for a token-level answer", () => {
    for (const reason of KEY_OR_TOPIC_REASONS) {
      expect(classifyApns(400, reason)).toBe("failed")
      expect(classifyApns(403, reason)).toBe("failed")
      expect(classifyApns(410, reason)).toBe("failed")
    }
    expect(classifyApns(400, "BadDeviceToken")).toBe("drop_target")
    expect(classifyApns(410, "Unregistered")).toBe("drop_target")
    expect(classifyApns(400, "DeviceTokenNotForTopic")).toBe("drop_target")
    expect(classifyApns(429, "TooManyRequests")).toBe("failed")
  })

  for (const reason of KEY_OR_TOPIC_REASONS) {
    it(`stops an environment and topic after ${reason}, and sends every other one`, async () => {
      const log = vi.spyOn(console, "log").mockImplementation(() => {})
      const refused = Array.from({ length: 26 }, (_, i) => target(`r${i}`, "sandbox", "dev.cmux.mobile.prod"))
      const prod = [target("p0", "production", "dev.cmux.mobile.prod"), target("p1", "production", "dev.cmux.mobile.prod")]
      const other = [target("gone", "sandbox", "dev.cmux.mobile"), target("ok", "sandbox", "dev.cmux.mobile")]
      // The phones that do work sit last, as a long-lived account's newest phone does.
      const targets = [...refused, ...other, ...prod]
      const seen: Array<string> = []
      const fetcher = (async (req: Request) => {
        const tok = new URL(req.url).pathname.split("/").pop()!
        seen.push(tok)
        await new Promise((r) => setTimeout(r, 1))
        if (tok.startsWith("r")) return apnsAnswer(reason === "TopicDisallowed" || reason === "BadTopic" || reason === "MissingTopic" ? 400 : 403, reason)
        if (tok === "gone") return apnsAnswer(400, "BadDeviceToken")
        return apnsAnswer(200)
      }) as unknown as typeof fetch
      const results = await sendApns(await config(), targets, event, Date.now(), fetcher)
      // Results keep the targets' order.
      expect(results.map((r) => r.token)).toEqual(targets.map((t) => t.token))
      const byToken = new Map(results.map((r) => [r.token, r]))
      // The working phones are all sent, and in the first wave, not behind the refused topic's queue.
      for (const t of ["p0", "ok"]) expect(byToken.get(t)!.outcome).toBe("sent")
      expect(byToken.get("p1")!.outcome).toBe("sent")
      expect(seen.slice(0, APNS_IN_FLIGHT)).toEqual(expect.arrayContaining(["r0", "gone", "p0"]))
      // A token-level answer stops nothing: the other phone of that environment and topic is still sent.
      expect(byToken.get("gone")!.outcome).toBe("drop_target")
      // The refused topic: at most one wave was sent; the rest were skipped, and none of them is dropped.
      const sentRefused = seen.filter((t) => t.startsWith("r")).length
      expect(sentRefused).toBeLessThanOrEqual(APNS_IN_FLIGHT)
      const refusedResults = results.filter((r) => r.token.startsWith("r"))
      expect(refusedResults.filter((r) => r.outcome === "failed")).toHaveLength(sentRefused)
      expect(refusedResults.filter((r) => r.outcome === "skipped")).toHaveLength(26 - sentRefused)
      expect(refusedResults.every((r) => r.outcome !== "drop_target" && r.reason === reason)).toBe(true)
      // One log line for the skips.
      expect(skipLogs(log)).toEqual([
        { msg: "apns skipped", what: "notify", skipped: 26 - sentRefused, groups: [{ environment: "sandbox", topic: "dev.cmux.mobile.prod", reason, skipped: 26 - sentRefused }] }
      ])
    })
  }

  it("keeps at most APNS_IN_FLIGHT sends in flight and logs nothing when none is refused", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    let inFlight = 0
    let most = 0
    const fetcher = (async () => {
      most = Math.max(most, ++inFlight)
      await new Promise((r) => setTimeout(r, 1))
      inFlight--
      return apnsAnswer(200)
    }) as unknown as typeof fetch
    const targets = Array.from({ length: 20 }, (_, i) => target(`t${i}`, "production", "dev.cmux.mobile"))
    const results = await sendApns(await config(), targets, event, Date.now(), fetcher)
    expect(results.every((r) => r.outcome === "sent")).toBe(true)
    expect(most).toBe(APNS_IN_FLIGHT)
    expect(skipLogs(log)).toEqual([])
  })

  it("skips Cloud attention sends the same way", async () => {
    vi.spyOn(console, "log").mockImplementation(() => {})
    let sends = 0
    const fetcher = (async () => {
      sends++
      await new Promise((r) => setTimeout(r, 1))
      return apnsAnswer(400, "TopicDisallowed")
    }) as unknown as typeof fetch
    const targets = Array.from({ length: 12 }, (_, i) => target(`c${i}`, "sandbox", "dev.cmux.mobile"))
    const results = await sendCloudAttention(await config(), targets, {
      recipient: "o",
      kind: "done",
      event_id: "attention-1",
      team_id: "team-1",
      machine_id: "vm_abcdefghijklmnopqrst",
      session_id: "session-1",
      deep_link: "cmux://cloud/chat/vm_abcdefghijklmnopqrst/session-1"
    }, Date.now(), fetcher)
    expect(sends).toBeLessThanOrEqual(APNS_IN_FLIGHT)
    expect(results.filter((r) => r.outcome === "skipped")).toHaveLength(12 - sends)
    expect(results.some((r) => r.outcome === "drop_target")).toBe(false)
  })

  it("answers the skips in notify and keeps every registration", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    const t = await token("rhea")
    const mac = await register(t, "mac", "personal-rhea")
    const phones: Array<string> = []
    for (let i = 0; i < 10; i++) {
      const phone = await register(t, "phone", "personal-rhea")
      const tok = (i + 1).toString(16).padStart(64, "0")
      expect((await call("PUT", `/v1/devices/${phone}/push`, t, { token: tok, environment: "sandbox", topic: "dev.cmux.mobile", kinds: ["question"] })).status).toBe(200)
      phones.push(phone)
    }
    const { privateKey } = await generateKeyPair("ES256", { extractable: true })
    const apnsEnv = { ...env, APNS_KEY_P8: await exportPKCS8(privateKey), APNS_KEY_ID: "KEY123", APNS_TEAM_ID: "TEAM123" }
    const realFetch = globalThis.fetch
    let sends = 0
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = input instanceof Request ? input.url : String(input)
      if (!url.startsWith("https://api.sandbox.push.apple.com/")) return realFetch(input, init)
      sends++
      await new Promise((r) => setTimeout(r, 1))
      return apnsAnswer(400, "TopicDisallowed")
    })
    const notify = async (eventId: string) => {
      const ctx = createExecutionContext()
      const res = await worker.fetch(
        new Request(`https://api.test/v1/devices/${mac}/notify`, {
          method: "POST",
          headers: { "content-type": "application/json", authorization: `Bearer ${t}` },
          body: JSON.stringify({ eventId, kind: "question", agent: "Claude", place: "repo" })
        }),
        apnsEnv as unknown as Parameters<typeof worker.fetch>[1],
        ctx
      )
      await waitOnExecutionContext(ctx)
      return { status: res.status, json: (await res.json()) as any }
    }
    const first = await notify("evt-skip-1")
    expect(first.status).toBe(200)
    expect(sends).toBeLessThanOrEqual(APNS_IN_FLIGHT)
    expect(first.json).toMatchObject({ configured: true, sent: 0, failed: sends, dropped: 0, skipped: 10 - sends })
    expect(first.json.failures).toHaveLength(sends)
    expect(skipLogs(log)).toHaveLength(1)
    // Every phone keeps its registration, so the next event goes to all ten again.
    const devices = (await call("GET", "/v1/me/devices", t)).json.devices
    expect(devices.filter((d: any) => phones.includes(d.deviceId)).every((d: any) => d.push === true)).toBe(true)
    sends = 0
    const second = await notify("evt-skip-2")
    expect(second.json.failed + second.json.skipped).toBe(10)
  })
})
