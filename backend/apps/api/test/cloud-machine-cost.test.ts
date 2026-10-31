import { describe, expect, it } from "vitest"
import { hourlyRateUsd } from "../src/domains/cloud-cost.ts"
import { publicMachine, type MachineRow } from "../src/domains/cloud.ts"

/** The cost fields the Cloud page and the sidebar show: the rate of the machine's size, and its start while running. */
const row = (patch: Partial<MachineRow>): MachineRow => ({
  id: "vm_aaaaaaaaaaaaaaaaaaaa",
  team: "team_a",
  creator: "user_a",
  name: null,
  size: { cpu: 4, memory_mb: 8192, disk_mb: 32768 },
  status: "running",
  image: { id: "img", daemon_version: null },
  host: null,
  classic: false,
  created_at: 1_000,
  last_active_at: null,
  idle_policy: { idle_seconds: 1800 },
  error: null,
  revision: "3",
  provider_name: "cmux-vm-aaaaaaaaaaaaaaaaaaaa",
  last_power_at: 5_000,
  ...patch
}) as MachineRow

describe("Cloud machine cost fields", () => {
  it("prices a size at Freestyle's vCPU and memory list price, as classic /api/vm does", () => {
    expect(hourlyRateUsd({ cpu: 4, memory_mb: 8192 })).toBe(0.2645)
    expect(hourlyRateUsd({ cpu: 2, memory_mb: 4096 })).toBe(0.1322)
    expect(hourlyRateUsd({ memory_mb: 4096 })).toBeNull()
    expect(hourlyRateUsd(undefined)).toBeNull()
  })

  it("a running machine carries its rate and when it last started; the private power time stays private", () => {
    const m = publicMachine(row({}))
    expect(m.hourly_rate_usd).toBe(0.2645)
    expect(m.running_since).toBe(5_000)
    expect("last_power_at" in m).toBe(false)
  })

  it("running_since is the confirmed start (running_at), not the start request (last_power_at)", () => {
    const m = publicMachine(row({ last_power_at: 5_000, running_at: 9_000 }))
    expect(m.running_since).toBe(9_000)
    expect("running_at" in m).toBe(false)
  })

  it("a paused machine carries its rate and no running start", () => {
    const m = publicMachine(row({ status: "paused" }))
    expect(m.hourly_rate_usd).toBe(0.2645)
    expect(m.running_since).toBeNull()
  })
})
