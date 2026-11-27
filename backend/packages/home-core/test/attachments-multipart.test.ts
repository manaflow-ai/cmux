import { describe, expect, it } from "vitest"
import { multipartPlan } from "../src/conversation/index.ts"

/**
 * The multipart plan keeps every R2 limit whatever the declared size: at most 10,000 parts, each
 * 5 MiB to 5 GiB and (all but the last) the same whole number of MiB, so each part is one request.
 */
const MiB = 1024 ** 2
const GiB = 1024 ** 3
const TiB = 1024 ** 4

describe("attachments: multipart plan", () => {
  it.each([
    ["just over the stream size", 32_000_001],
    ["104 GiB", 104 * GiB],
    ["10,000 pieces of 32 MiB", 10_000 * 32 * MiB],
    ["one byte more", 10_000 * 32 * MiB + 1],
    ["1 TiB", TiB],
    ["5 TiB", 5 * TiB]
  ])("plans %s within R2's part limits", (_, size) => {
    const plan = multipartPlan(size)
    expect(plan.parts).toBeLessThanOrEqual(10_000)
    expect(plan.partBytes % MiB).toBe(0)
    expect(plan.partBytes).toBeGreaterThanOrEqual(5 * MiB)
    expect(plan.partBytes).toBeLessThanOrEqual(5 * GiB)
    expect((plan.parts - 1) * plan.partBytes).toBeLessThan(size)
    expect(plan.parts * plan.partBytes).toBeGreaterThanOrEqual(size)
  })

  it("keeps 32 MiB pieces until the part count needs larger ones", () => {
    expect(multipartPlan(104 * GiB)).toEqual({ partBytes: 32 * MiB, parts: 3_328 })
    expect(multipartPlan(10_000 * 32 * MiB + 1)).toEqual({ partBytes: 33 * MiB, parts: 9_697 })
    expect(multipartPlan(TiB)).toEqual({ partBytes: 105 * MiB, parts: 9_987 })
  })
})
