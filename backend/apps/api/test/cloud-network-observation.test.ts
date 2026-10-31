import { describe, expect, it } from "vitest"
import { CloudNetworkObservation, networkBinding } from "../src/cloud-network-observation.ts"
import type { MachineRow } from "../src/domains/cloud.ts"

const row = (network: Record<string, unknown> | null): MachineRow => ({
  id: "vm_" + "1".repeat(20), team: "team_test", creator: "user_test", name: null, size: {},
  status: "running", image: { id: "native", daemon_version: null }, host: "host_test", host_id: "host_test",
  classic: false, created_at: 1, last_active_at: null, idle_policy: { idle_seconds: 0 }, error: null,
  revision: "1", provider_name: "native", transport: "vm-api", epoch: 1, wg_public_key: "wg",
  ...(network ? { network } : {})
} as MachineRow)

describe("CloudNetworkObservation", () => {
  it("coalesces concurrent reads and publishes a changed network only for the same binding", async () => {
    let current = row({ tenant: "t", mesh: "m", device: "d" }), reads = 0, now = 1000
    const obs = new CloudNetworkObservation(
      () => now,
      (_entity, id) => current.id === id ? current : undefined,
      async () => { reads++; await Promise.resolve(); return { tenant: "t", mesh: "m", device: "d", address: "10.0.0.2" } as never },
      (_r, _binding, network) => { current = { ...current, network }; return true }
    )
    const [a, b] = await Promise.all([obs.check("team_test", current), obs.check("team_test", current)])
    expect(a).toBe(true); expect(b).toBe(true); expect(reads).toBe(1)
    expect(current.network).toMatchObject({ address: "10.0.0.2" })
    expect(networkBinding(current)).toContain("10.0.0.2")
    now += 31_000
    current = { ...current, epoch: 2 }
    expect(await obs.check("team_test", current)).toBe(true)
  })

  it("fails closed when the provider read or publication loses the binding", async () => {
    const initial = row({ tenant: "t", mesh: "m", device: "d" })
    let current = initial, reads = 0
    const obs = new CloudNetworkObservation(
      () => 1000,
      (_entity, id) => current.id === id ? current : undefined,
      async () => { reads++; current = { ...current, epoch: 2 }; return { tenant: "t", mesh: "m", device: "d" } as never },
      () => true
    )
    expect(await obs.check("team_test", initial)).toBe(false)
    expect(reads).toBe(1)
  })
})
