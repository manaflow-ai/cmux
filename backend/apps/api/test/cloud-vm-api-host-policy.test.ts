import { afterEach, expect, it, vi } from "vitest"
import { policyWorld } from "./cloud-vm-api-host-policy-support.ts"
afterEach(() => vi.restoreAllMocks())

it("joins an inbound Native device to its current backend host, owner, install and grant", async () => {
  const f = await policyWorld()
  f.policies.get(f.server.device)!.peers = [f.nativePeer(f.client, [{ protocol: "tcp", port: 22 }], [])]
  const read = await f.read()
  expect(read.status).toBe(200)
  expect(read.json.value).toMatchObject({ host: f.server.host, team: f.team.team,
    peers: [{ host: f.client.host, user: f.client.user, install: f.client.install, device: f.client.device,
      wg_public_key: f.client.wg, install_public_key: f.client.point, inbound: [{ protocol: "tcp", port: 22 }], outbound: [] }] })
  expect(JSON.stringify(read.json.value)).not.toContain(f.team.creator.token)
})

it("preserves the client's directed outgoing policy without inferring reverse access", async () => {
  const f = await policyWorld()
  f.policies.get(f.client.device)!.peers = [f.nativePeer(f.server, [], [{ protocol: "tcp", port: 22 }])]
  const read = await f.read(f.client)
  expect(read.json).toMatchObject({ op: "host.network.policy", value: { host: f.client.host, peers: [{ host: f.server.host, install: f.server.install, inbound: [], outbound: [{ protocol: "tcp", port: 22 }] }] } })
})

it("returns an empty current projection when Native grants no peer access", async () => {
  const f = await policyWorld(), read = await f.read()
  expect(read.json).toMatchObject({ op: "host.network.policy", value: { host: f.server.host, peers: [] } })
})

it("keeps identity confirmation separate from the peer-policy read", async () => {
  const f = await policyWorld(), directory = await f.directory()
  expect(directory.hosts.find((h: { id: string }) => h.id === f.server.host).network).toMatchObject({ state: "confirmed", install_grant: f.server.grant })
  expect(directory.hosts.find((h: { id: string }) => h.id === f.client.host).network).toMatchObject({ state: "confirmed", install_grant: f.client.grant })
})
