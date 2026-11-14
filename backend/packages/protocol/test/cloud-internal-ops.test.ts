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
    { observed_provider_name: "" },
    { observed_transport: "unknown-provider" }
  ])("rejects an invalid observation field %j", (invalid) => {
    expect(() => decode({ machine, state: "paused", ...invalid }, { onExcessProperty: "error" })).toThrow()
  })
})

const bind = cloudInternalOps.find((op) => op.name === "cloud.machine.bind")!
const decodeBind = Schema.decodeUnknownSync(bind.params as Schema.Codec<unknown, unknown>)
const bindInput = {
  machine,
  token_sha256: "0".repeat(64),
  wg_public_key: `${"A".repeat(43)}=`,
  daemon: { version: "0.40.0", capabilities: ["terminal"] },
  keyset_version: "0123456789abcdef",
  vm_install: `inst_${"v".repeat(20)}`,
  now: 1
}
const noiseKey = Buffer.from(Uint8Array.from({ length: 32 }, (_, i) => i * 7)).toString("base64url")

describe("bind schema", () => {
  it("keeps the daemon's Noise key, and binds without one", () => {
    expect(decodeBind({ ...bindInput, daemon_noise_key: noiseKey }, { onExcessProperty: "error" })).toEqual({ ...bindInput, daemon_noise_key: noiseKey })
    expect(decodeBind(bindInput, { onExcessProperty: "error" })).toEqual(bindInput)
  })

  it.each([
    noiseKey.slice(0, 42),
    `${noiseKey}A`,
    `${noiseKey}=`,
    `${noiseKey.slice(0, 42)}B`,
    Buffer.from(Uint8Array.from({ length: 32 }, (_, i) => i * 7)).toString("base64").replace(/=$/, "")
  ])("refuses a Noise key that is not 32 bytes of canonical base64url: %s", (key) => {
    expect(() => decodeBind({ ...bindInput, daemon_noise_key: key }, { onExcessProperty: "error" })).toThrow()
  })
})
