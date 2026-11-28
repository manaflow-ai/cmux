import { Schema } from "effect"
import { describe, expect, it } from "vitest"
import { feedKinds } from "../src/feed-kinds.ts"

/** Review P3 (2026-10-04): a feed approve item's risk is an op risk; the cloud-link grant class is never one. */
describe("feed approve risk", () => {
  it("accepts op risks and refuses the cloud-link grant class", () => {
    const prompt = feedKinds.approve!.prompt as Schema.Codec<unknown, unknown>
    const item = (risk: string) => ({ action: { type: "command", summary: "run it", risk } })
    expect(Schema.is(prompt)(item("execute"))).toBe(true)
    expect(Schema.is(prompt)(item("cloud-link"))).toBe(false)
  })
})
