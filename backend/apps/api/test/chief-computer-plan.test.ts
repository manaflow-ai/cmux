import { describe, expect, it } from "vitest"
import { COMPUTER_PLANS, computerPlanAllowed } from "../src/chief-brain-cc/sandbox-plan.ts"

/**
 * A Chief's own Cloud computer is for cmux NEXT Plus (plan id `go`), Pro and Max (and Founders, Pro sold early at Pro's
 * limits). Team, no plan, and an unknown answer get none (chief-brain-cc/sandbox-plan.ts COMPUTER_PLANS).
 */
describe("which plans get a Chief's computer", () => {
  it("allows Plus, Pro, Max and Founders", () => {
    for (const plan of ["go", "pro", "max", "founders"]) expect(computerPlanAllowed(plan), plan).toBe(true)
  })

  it("refuses Team, no plan, free, an unknown plan and an unanswered read", () => {
    for (const plan of ["team", "none", "free", "enterprise", ""]) expect(computerPlanAllowed(plan), plan).toBe(false)
    expect(computerPlanAllowed(null)).toBe(false)
  })

  it("keeps the stub plan of development, staging and test", () => {
    expect(COMPUTER_PLANS.has("stub_default")).toBe(true)
  })
})

describe("what a Chief is told about its computer", () => {
  it("tells an owner with a computer plan how to use it", async () => {
    const { ccAddendum } = await import("../src/chief-brain-cc/turn.ts")
    const on = ccAddendum(25, true)
    expect(on).toContain("chief-vm computer setup ID")
    expect(on).not.toContain("cmux.com/pricing")
  })

  it("keeps the computer off without a plan, with the pricing link only for a task that needs a screen", async () => {
    const { ccAddendum } = await import("../src/chief-brain-cc/turn.ts")
    const off = ccAddendum(25, false)
    expect(off).not.toContain("chief-vm computer setup")
    expect(off).toContain("Do not offer it")
    expect(off).toContain("https://cmux.com/pricing")
    // The rest of the route (sandboxes, timers, network) is the same: Chief works without a plan.
    expect(off).toContain("Sandboxes: `chief-vm list")
    expect(off).toContain("Timers: `chief-wake")
  })
})
