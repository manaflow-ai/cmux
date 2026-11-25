import type { PushTarget } from "@cmux/protocol"
import { exportPKCS8, generateKeyPair } from "jose"
import { describe, expect, it } from "vitest"
import { APNS_MAX_PAYLOAD_BYTES, apnsConfig, sendApnsMessage, stampSentAt, type ApnsMessage } from "../src/push/apns.ts"

// Push-latency probe (optimum-ledger row 16): with PUSH_SENT_AT_PROBE=1 a send puts `cmuxSentAtMs`, the wall
// clock where it hands the push to APNs, beside `aps`; off, the body is as before.

const target: PushTarget = { token: "a".repeat(64), topic: "com.cmux.app", environment: "production", install: "inst_ios00000000000000000", device_name: "iPhone", registered_at: 1 }
const message = (body: unknown): ApnsMessage => ({ body: JSON.stringify(body), collapseId: "c", priority: "10", expiresAt: 2_000_000_000_000 })

describe("push-latency probe: cmuxSentAtMs", () => {
  it("is on only with PUSH_SENT_AT_PROBE=1", () => {
    const keys = { APNS_KEY_P8: "k", APNS_KEY_ID: "i", APNS_TEAM_ID: "t" }
    expect(apnsConfig(keys)?.sentAtProbe).toBeUndefined()
    expect(apnsConfig({ ...keys, PUSH_SENT_AT_PROBE: "0" })?.sentAtProbe).toBeUndefined()
    expect(apnsConfig({ ...keys, PUSH_SENT_AT_PROBE: "1" })?.sentAtProbe).toBe(true)
  })

  it("stamps beside aps and keeps the message's other fields", () => {
    const out = stampSentAt(message({ aps: { alert: { title: "t" } }, cmux: { seq: 3 } }), 1_800_000_000_123)
    expect(JSON.parse(out.body)).toEqual({ aps: { alert: { title: "t" } }, cmux: { seq: 3 }, cmuxSentAtMs: 1_800_000_000_123 })
    expect(out.collapseId).toBe("c")
  })

  it("leaves a body that the stamp would push over the APNs limit alone", () => {
    const big = message({ aps: { alert: { body: "x".repeat(APNS_MAX_PAYLOAD_BYTES - 60) } } })
    expect(new TextEncoder().encode(big.body).length).toBeLessThanOrEqual(APNS_MAX_PAYLOAD_BYTES)
    expect(stampSentAt(big, 1_800_000_000_123)).toBe(big)
  })

  it("sendApnsMessage stamps at the send, and not when the probe is off", async () => {
    const sent: Array<{ cmuxSentAtMs?: number }> = []
    const fetcher = (async (req: Request) => {
      sent.push(JSON.parse(await req.text()))
      return new Response("", { status: 200 })
    }) as typeof fetch
    const { privateKey } = await generateKeyPair("ES256", { extractable: true })
    const base = { keyP8: await exportPKCS8(privateKey), keyId: "KEYID12345", teamId: "TEAMID1234" }
    const m = message({ aps: { alert: { title: "t" } } })
    const before = Date.now()
    await sendApnsMessage(base, [target], m, before, fetcher)
    await sendApnsMessage({ ...base, sentAtProbe: true }, [target], m, before, fetcher)
    expect(sent[0]!.cmuxSentAtMs).toBeUndefined()
    expect(sent[1]!.cmuxSentAtMs).toBeGreaterThanOrEqual(before)
  })
})
