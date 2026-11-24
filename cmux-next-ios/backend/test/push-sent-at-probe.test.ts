import { exportPKCS8, generateKeyPair } from "jose"
import { describe, expect, it } from "vitest"
import { apnsConfig, MAX_PAYLOAD_BYTES, sendApns, stampSentAt, type PushRegistration } from "../src/push.ts"

// Push-latency probe (optimum-ledger row 16): with PUSH_SENT_AT_PROBE=1 the Mac-notify send puts
// `cmuxSentAtMs`, the wall clock where it hands the push to APNs, beside `aps`; off, the body is as before.

const event = { eventId: "e1", kind: "permission" as const, agent: "Claude", place: "cmux", macId: "m1", macName: "Studio", sessionId: "s1", tabId: "t1" }
const target: PushRegistration = { deviceId: "d", space: "", ownerUserId: "o", token: "aa", environment: "production", topic: "dev.cmux.mobile", kinds: ["permission"], mutedMacs: [], previews: true, updatedAt: "" }

describe("push-latency probe: cmuxSentAtMs", () => {
  it("is on only with PUSH_SENT_AT_PROBE=1", async () => {
    const { privateKey } = await generateKeyPair("ES256", { extractable: true })
    const keys = { APNS_KEY_P8: await exportPKCS8(privateKey), APNS_KEY_ID: "K", APNS_TEAM_ID: "T" } as never
    expect(apnsConfig(keys)?.sentAtProbe).toBeUndefined()
    expect(apnsConfig({ ...(keys as object), PUSH_SENT_AT_PROBE: "0" } as never)?.sentAtProbe).toBeUndefined()
    expect(apnsConfig({ ...(keys as object), PUSH_SENT_AT_PROBE: "1" } as never)?.sentAtProbe).toBe(true)
  })

  it("stamps at the send, and not when the probe is off", async () => {
    const { privateKey } = await generateKeyPair("ES256", { extractable: true })
    const config = { keyP8: await exportPKCS8(privateKey), keyId: "KEY123", teamId: "TEAM123" }
    const bodies: Array<{ aps: unknown; cmuxSentAtMs?: number }> = []
    const fetcher = (async (req: Request) => {
      bodies.push(JSON.parse(await req.text()))
      return new Response(null, { status: 200 })
    }) as unknown as typeof fetch
    const before = Date.now()
    await sendApns(config, [target], event, before, fetcher)
    await sendApns({ ...config, sentAtProbe: true }, [target], event, before, fetcher)
    expect(bodies[0]!.cmuxSentAtMs).toBeUndefined()
    expect(bodies[1]!.cmuxSentAtMs).toBeGreaterThanOrEqual(before)
    expect(bodies[1]!.aps).toEqual(bodies[0]!.aps)
  })

  it("leaves a body that the stamp would push over the APNs limit alone", () => {
    const full = { aps: { alert: { body: "x".repeat(MAX_PAYLOAD_BYTES - 40) } } }
    expect(stampSentAt(full, 1_800_000_000_000)).toBe(full)
    expect(stampSentAt({ aps: {} }, 1_800_000_000_000)).toEqual({ aps: {}, cmuxSentAtMs: 1_800_000_000_000 })
  })
})
