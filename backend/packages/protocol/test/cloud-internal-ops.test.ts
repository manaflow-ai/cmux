import { Schema } from "effect"
import { describe, expect, it } from "vitest"
import { cloudInternalOps } from "../src/cloud-internal-ops.ts"

const providerState = cloudInternalOps.find((op) => op.name === "cloud.machine.provider_state")!
const decode = Schema.decodeUnknownSync(providerState.params as Schema.Codec<unknown, unknown>)
const machine = `vm_${"a".repeat(20)}`

describe("provider-state observation schema", () => {
  it.each(["paused", "stopped", null])("preserves the observation fence for provider state %s", (state) => {
    for (const transport of ["direct", "vm-api"]) {
      const input = {
        machine,
        state,
        observed_revision: "42",
        observed_provider_name: "cmux-vm-observed",
        observed_transport: transport
      }
      expect(decode(input)).toEqual(input)
      expect(decode(input, { onExcessProperty: "error" })).toEqual(input)
    }
  })

  it("accepts legacy observations without a fence", () => {
    const input = { machine, state: "paused" }
    expect(decode(input, { onExcessProperty: "error" })).toEqual(input)
  })

  it.each([
    { observed_revision: 42 },
    { observed_revision: "not-a-revision" },
    { observed_provider_name: 42 },
    { observed_transport: "unknown-provider" }
  ])("rejects an invalid observation field %j", (invalid) => {
    expect(() => decode({ machine, state: "paused", ...invalid }, { onExcessProperty: "error" })).toThrow()
  })
})
