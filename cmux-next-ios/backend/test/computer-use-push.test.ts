import { describe, expect, it } from "vitest"
import { apnsPayload, apnsRequest, collapseId, MAX_COMPUTER_USE_BYTES, parseNotify, pushTargets, sealedPayload, turnPushKey, wantedKinds, type NotifyEvent } from "../src/push.ts"
import type { PushRegistration } from "../src/store.ts"

// Computer Use approval questions from a Mac (docs/computer-use-approvals.md, "Phone wire (macOS)").

const MAC = "11111111-1111-4111-8111-111111111111"
const DIGEST = "ab".repeat(32)
const request = {
  v: 1,
  nonce: "6f1d2c3b4a5968778695a4b3c2d1e0f1",
  client: "com.cmuxterm.app.debug.cu1",
  machine: "Studio",
  session: "c-41",
  agent: "Claude",
  workspace: "api-server",
  target: { bundle_id: "com.apple.Safari", executable: null, name: "Safari \"β\"" },
  tool: "click",
  risk: "R1",
  created_ms: 1793400000000,
  wait_until_ms: 1793400120000,
  answerable_until_ms: 1793400600000,
  digest: DIGEST
}
const body = { eventId: `cu-${DIGEST.slice(0, 32)}`, permissionId: `cu-${DIGEST.slice(0, 32)}`, kind: "computer_use", agent: "Claude", workspace: "api-server", title: "Safari", state: "waiting", computerUse: { request, always: false } }
const reg = (over: Partial<PushRegistration> = {}): PushRegistration => ({
  deviceId: "d1",
  ownerUserId: "o",
  token: "aa",
  environment: "production",
  topic: "dev.cmux.mobile",
  kinds: ["question", "permission"],
  mutedMacs: [],
  previews: true,
  updatedAt: "",
  ...over
})

const event = (): NotifyEvent => {
  const r = parseNotify(body)
  if (typeof r === "string") throw new Error(r)
  return { ...r, macId: MAC, macName: "Mac mini" }
}

describe("computer_use notify", () => {
  it("keeps the request object exactly as the Mac sent it", () => {
    const e = event()
    expect(e.kind).toBe("computer_use")
    expect(e.computerUse).toEqual({ request, always: false })
    expect(e.permissionId).toBe(`cu-${DIGEST.slice(0, 32)}`)
  })

  it("refuses a question without a usable computerUse object", () => {
    for (const computerUse of [undefined, {}, { request, always: "yes" }, { request: { ...request, digest: "nope" }, always: true }, { request: { ...request, pad: "x".repeat(MAX_COMPUTER_USE_BYTES) }, always: false }]) {
      expect(typeof parseNotify({ ...body, computerUse })).toBe("string")
    }
  })

  it("writes the banner, category and payload the phone acts on", () => {
    const p = apnsPayload(event())
    expect(p.aps.alert).toEqual({ title: "Claude wants to use Safari", subtitle: "api-server · Mac mini", body: "Allow or deny it on this iPhone." })
    expect(p.aps.category).toBe("CMUX_MOBILE_COMPUTER_USE")
    expect(p.aps["interruption-level"]).toBe("time-sensitive")
    expect(p.cmuxMobile).toMatchObject({ v: 2, kind: "computer_use", eventId: body.eventId, permissionId: body.permissionId, computerUse: { request, always: false } })
    expect(new TextEncoder().encode(JSON.stringify(p)).length).toBeLessThan(4096)
  })

  it("keeps the request with previews off, and in the smallest fallback", () => {
    const off = apnsPayload(event(), { previews: false })
    expect(off.aps.alert.title).toBe("Claude wants to use an app")
    expect(off.cmuxMobile.computerUse).toEqual({ request, always: false })
    const huge = apnsPayload({ ...event(), title: "t".repeat(200), body: "😀".repeat(400), tail: Array.from({ length: 6 }, () => "😀".repeat(160)) })
    expect(huge.cmuxMobile.computerUse).toEqual({ request, always: false })
    expect(new TextEncoder().encode(JSON.stringify(huge)).length).toBeLessThanOrEqual(4096)
  })

  it("goes to phones that want permission requests, never coalesced, expiring with the question", async () => {
    const regs = [reg(), reg({ deviceId: "d2", kinds: ["completed"] }), reg({ deviceId: "d3", mutedMacs: [MAC] })]
    expect(pushTargets(regs, MAC, "computer_use").map((r) => r.deviceId)).toEqual(["d1"])
    expect(wantedKinds([reg({ kinds: ["completed"] })], MAC)).not.toContain("computer_use")
    expect(wantedKinds([reg()], MAC)).toContain("computer_use")
    const e = event()
    expect(turnPushKey(MAC, e)).toBeNull()
    expect(collapseId(e)).toBe(body.eventId)
    const now = 1793400000000
    const req = apnsRequest(reg(), e, "tok", now)
    expect(req.headers.get("apns-expiration")).toBe(String(Math.floor(request.answerable_until_ms / 1000)))
  })

  it("sealed: no content leaves in the clear", () => {
    const p = sealedPayload(event(), { box: "AAAA", sig: "ab".repeat(64) })
    expect(JSON.stringify(p)).not.toContain("Safari")
    expect(p.cmuxMobile.kind).toBe("computer_use")
  })
})
