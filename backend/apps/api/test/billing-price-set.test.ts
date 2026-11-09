import { describe, expect, it } from "vitest"
import { defaultIncludedMode, defaultTeamMode, USAGE_INCLUDED_USD, USAGE_PRICE_SET_NAMES, usageIncludedUsd, usagePriceLookupKey } from "../src/billing-catalog.ts"
import { usagePriceSet } from "../src/billing-usage-sync.ts"
import { includedModeFor } from "../src/inference/included-stop.ts"

/**
 * Price set v2 (Leo 2026-11-09): Team 25 USD per seat, pooled across the team; the other plans as v1.
 * Development and staging only, with BILLING_USAGE_PRICE_SET=v2; production stays v1 until Leo's go.
 */
describe("usage price set v2 (Team 25 USD per seat)", () => {
  it("has Team 25 USD and the v1 amounts for the other plans, with its own lookup keys", () => {
    expect(USAGE_PRICE_SET_NAMES).toContain("v2")
    expect(usageIncludedUsd("team", "v2")).toBe(25)
    for (const plan of ["go", "pro", "max"] as const) expect(usageIncludedUsd(plan, "v2")).toBe(usageIncludedUsd(plan, "v1"))
    expect(usagePriceLookupKey("team", "v2", "per_seat")).toBe("cmux-ai-usage-team-seat25-v2")
    expect(usagePriceLookupKey("team", "v2", "per_team")).toBe("cmux-ai-usage-team-incl25-v2")
    expect(usagePriceLookupKey("pro", "v2")).toBe("cmux-ai-usage-pro-incl20-v2")
    // v1 is never edited.
    expect(usagePriceLookupKey("team", "v1", "per_seat")).toBe("cmux-ai-usage-team-seat20-v1")
    expect(USAGE_INCLUDED_USD).toEqual({ go: 5, pro: 20, max: 100, team: 20 })
  })

  it("is in force only on development or staging that ask for it; production stays v1", () => {
    const at = (ENVIRONMENT: string, BILLING_USAGE_PRICE_SET?: string) => usagePriceSet({ ENVIRONMENT, BILLING_USAGE_PRICE_SET })
    expect(at("development", "v2")).toBe("v2")
    expect(at("staging", "v2")).toBe("v2")
    expect(at("production", "v2")).toBe("v1")
    expect(at("production", "e2e")).toBe("v1")
    expect(at("production")).toBe("v1")
    expect(at("test", "v2")).toBe("v1")
    expect(at("local", "v2")).toBe("v1")
    expect(at("staging")).toBe("v1")
    expect(at("staging", "e2e")).toBe("v1")
    expect(at("development", "e2e")).toBe("e2e")
    expect(at("development")).toBe("v1")
  })

  it("makes a Team team with no operator setting per seat under v2 and per team under v1 and e2e; other plans per team", () => {
    expect(defaultTeamMode("v2")).toBe("per_seat")
    expect(defaultTeamMode("v1")).toBe("per_team")
    expect(defaultTeamMode("e2e")).toBe("per_team")
    expect(defaultIncludedMode("team", "v2")).toBe("per_seat")
    for (const plan of ["go", "pro", "max", null] as const) expect(defaultIncludedMode(plan, "v2")).toBe("per_team")
    const staging = { ENVIRONMENT: "staging", BILLING_USAGE_PRICE_SET: "v2" } as any
    expect(includedModeFor(staging, { plan: "team" })).toBe("per_seat")
    expect(includedModeFor(staging, { plan: "founders" })).toBe("per_team")
    expect(includedModeFor({ ENVIRONMENT: "production", BILLING_USAGE_PRICE_SET: "v2" } as any, { plan: "team" })).toBe("per_team")
  })
})
