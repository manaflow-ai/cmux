import { afterEach, expect, it, vi } from "vitest"
import { withReceiver, type Allow } from "./cloud-vm-api-receiver-support.ts"
afterEach(() => vi.restoreAllMocks())

it("keeps the bound VM's existing self read working", async () => {
  await withReceiver(async (f) => { expect(await f.self()).toMatchObject({ ok: true, value: { machine: { id: f.machine } } }) })
})

it("returns an empty current policy when Native grants no client services", async () => {
  await withReceiver(async (f) => {
    expect(await f.read()).toMatchObject({ ok: true, value: { schema_version: 1, machine: f.machine, host: f.host, install: f.principal.install,
      team: f.team, tenant: f.tenant, mesh: f.native.meshId, vm: f.native.vmId, peers: [] } })
  })
})

it.each([
  { allow: [{ protocol: "tcp", port: 22 }], services: ["ssh"] },
  { allow: [{ protocol: "tcp", port: 22 }, { protocol: "tcp", port: 4100 }], services: ["daemon", "ssh"] },
  { allow: [{ protocol: "udp", port: 22 }], services: [] }
])("joins the original client grant and directed service permission %#", async ({ allow, services }) => {
  await withReceiver(async (f) => {
    f.native.peers = [{ deviceId: f.client.device, wgPublicKey: f.client.wg, installPublicKey: f.client.point, allow: allow as Allow[] }]
    const read = await f.read()
    expect(read.ok).toBe(true)
    expect(read.value.peers).toEqual(services.length ? [expect.objectContaining({ host: f.client.host, user: f.client.user, install: f.client.install,
      device: f.client.device, wg_public_key: f.client.wg, install_public_key: f.client.point, authority_version: expect.stringMatching(/^[0-9a-f]{64}$/), services })] : [])
  })
})
