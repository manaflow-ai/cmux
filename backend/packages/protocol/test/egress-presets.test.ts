// RFD 0211: the org policy's `cloud.egress` presets are validated against
// EGRESS_PRESET_IDS here and expanded to hostnames by cmux-vm. A preset one
// side lacks is either refused at save or silently allows nothing, so the two
// lists must match.
import { describe, expect, it } from "vitest"
import { EGRESS_PRESETS } from "../../../../workers/cmux-vm/src/egress-allowlist.ts"
import { EGRESS_PRESET_IDS } from "../src/policy.ts"

describe("egress presets", () => {
  it("the policy's preset ids match cmux-vm's EGRESS_PRESETS", () => {
    expect([...EGRESS_PRESET_IDS].sort()).toEqual(Object.keys(EGRESS_PRESETS).sort())
  })
})
