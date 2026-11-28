import { describe, expect, it } from "vitest"
import { judgeRelayedTb, TB, TIER2_RELAYED_BYTES } from "../src/relayed-tb.ts"

describe("relayed-tb", () => {
  it("is ok below 80% of the threshold", () => {
    expect(judgeRelayedTb(0)).toBe("ok")
    expect(judgeRelayedTb(39.9 * TB)).toBe("ok")
  })
  it("warns from 80% up to the threshold", () => {
    expect(judgeRelayedTb(40 * TB)).toBe("warn")
    expect(judgeRelayedTb(TIER2_RELAYED_BYTES - 1)).toBe("warn")
  })
  it("adds a box at the threshold", () => {
    expect(judgeRelayedTb(TIER2_RELAYED_BYTES)).toBe("add_box")
    expect(judgeRelayedTb(2 * TB, 1 * TB)).toBe("add_box")
  })
  it("refuses nonsense", () => {
    expect(() => judgeRelayedTb(-1)).toThrow(RangeError)
    expect(() => judgeRelayedTb(NaN)).toThrow(RangeError)
    expect(() => judgeRelayedTb(1, 0)).toThrow(RangeError)
  })
})
