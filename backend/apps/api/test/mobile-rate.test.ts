import { describe, expect, it } from "vitest"
import { MOBILE_RATE_LIMITED, MOBILE_RATE_RETRY_SECONDS, mobileRateKey, takeMobileRate } from "../src/mobile-rate.ts"

describe("mobile control-plane rate limits", () => {
  it("names buckets by operation and authenticated identity", () => {
    expect(mobileRateKey("turn", "inst_phone")).toBe("turn:inst_phone")
    expect(mobileRateKey("pending", "session:user_1")).toBe("pending:session:user_1")
    expect(MOBILE_RATE_LIMITED).toBe("signal.rate_limited")
    expect(MOBILE_RATE_RETRY_SECONDS).toBe(60)
  })

  it("allows deployments without an optional local binding", async () => {
    expect(await takeMobileRate(undefined, "turn:inst_phone")).toBe(true)
    expect(await takeMobileRate(undefined, "turn:inst_phone", true)).toBe(false)
  })

  it("uses the binding result and fails closed when it cannot answer", async () => {
    const seen: string[] = []
    const allow = { limit: async ({ key }: { key: string }) => (seen.push(key), { success: true }) }
    const deny = { limit: async () => ({ success: false }) }
    const broken = { limit: async () => { throw new Error("limiter unavailable") } }
    expect(await takeMobileRate(allow, "turn:inst_phone")).toBe(true)
    expect(await takeMobileRate(deny, "turn:inst_phone")).toBe(false)
    expect(await takeMobileRate(broken, "turn:inst_phone")).toBe(false)
    expect(seen).toEqual(["turn:inst_phone"])
  })
})
