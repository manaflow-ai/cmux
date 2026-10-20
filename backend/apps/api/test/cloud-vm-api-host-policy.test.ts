import { afterEach, expect, it, vi } from "vitest"
import { policyWorld } from "./cloud-vm-api-host-policy-support.ts"
afterEach(() => vi.restoreAllMocks())

it("joins an inbound Native device to its current backend host, owner, install and grant", async () => {
  const f = await policyWorld()
  f.policies.get(f.server.device)!.peers = [f.nativePeer(f.client, [{ protocol: "tcp", port: 22 }], [])]
  const read = await f.read()
  expect(read.json.ok).toBe(true)
  expect(read.json.value).toMatchObject({ host: f.server.host, team: f.team.team,
    peers: [{ host: f.client.host, user: f.client.user, install: f.client.install, device: f.client.device,
      wg_public_key: f.client.wg, install_public_key: f.client.point, inbound: [{ protocol: "tcp", port: 22 }], outbound: [] }] })
  expect(JSON.stringify(read.json.value)).not.toContain(f.team.creator.token)
})

it("preserves the client's directed outgoing policy without inferring reverse access", async () => {
  const f = await policyWorld()
  f.policies.get(f.client.device)!.peers = [f.nativePeer(f.server, [], [{ protocol: "tcp", port: 22 }])]
  const read = await f.read(f.client)
  expect(read.json).toMatchObject({ ok: true, value: { host: f.client.host, peers: [{ host: f.server.host, install: f.server.install, inbound: [], outbound: [{ protocol: "tcp", port: 22 }] }] } })
})

it("returns an empty current projection when Native grants no peer access", async () => {
  const f = await policyWorld(), read = await f.read()
  expect(read.json).toMatchObject({ ok: true, value: { host: f.server.host, peers: [] } })
})

it("keeps identity confirmation separate from the peer-policy read", async () => {
  const f = await policyWorld(), directory = await f.directory()
  expect(directory.hosts.find((h: { id: string }) => h.id === f.server.host).network).toMatchObject({ state: "confirmed", install_grant: f.server.grant })
  expect(directory.hosts.find((h: { id: string }) => h.id === f.client.host).network).toMatchObject({ state: "confirmed", install_grant: f.client.grant })
})

it("omits a revoked peer even while Native still lists its original keys", async () => {
  const f = await policyWorld()
  f.policies.get(f.server.device)!.peers = [f.nativePeer(f.client, [{ protocol: "tcp", port: 22 }], [])]
  expect((await f.sessionOp("install.revoke", { install: f.client.install })).json.ok).toBe(true)
  expect((await f.read()).json).toMatchObject({ ok: true, value: { peers: [] } })
})

it("joins a different member's install by its backend owner rather than a Native or caller-supplied user", async () => {
  const f = await policyWorld(), member = await f.team.join("Member", ["team_member", "$read_members", "$invite_members"])
  const peer = await f.addClient(3, member)
  f.policies.get(f.server.device)!.peers = [{ ...f.nativePeer(peer, [{ protocol: "tcp", port: 22 }], []), user: f.server.user, install: f.server.install }]
  expect((await f.read()).json).toMatchObject({ ok: true, value: { peers: [{ user: member.user, install: peer.install }] } })
})

it("does not publish a P256 key shared by two backend owners", async () => {
  const f = await policyWorld(), member = await f.team.join("Member", ["team_member", "$read_members", "$invite_members"])
  await f.addClient(3, member, f.client.pair)
  f.policies.get(f.server.device)!.peers = [f.nativePeer(f.client, [{ protocol: "tcp", port: 22 }], [])]
  expect((await f.read()).json).toMatchObject({ ok: true, value: { peers: [] } })
})

it("does not publish a WireGuard key assigned to two backend hosts", async () => {
  const f = await policyWorld()
  await f.addClient(3, undefined, undefined, f.client.wg)
  f.policies.get(f.server.device)!.peers = [f.nativePeer(f.client, [{ protocol: "tcp", port: 22 }], [])]
  expect((await f.read()).json).toMatchObject({ ok: true, value: { peers: [] } })
})

it.each(["deviceId", "wgPublicKey", "installPublicKey"] as const)("rejects an ambiguous Native %s", async (field) => {
  const f = await policyWorld(), third = await f.addClient(3)
  const first = f.nativePeer(f.client, [{ protocol: "tcp", port: 22 }], []), second = f.nativePeer(third, [{ protocol: "tcp", port: 22 }], [])
  f.policies.get(f.server.device)!.peers = [first, { ...second, [field]: first[field] }]
  expect((await f.read()).json.ok).toBe(false)
})

it("requires the calling host even when another host uses the same team and human account", async () => {
  const f = await policyWorld(), before = f.nativeCalls.length
  const read = await f.read(f.client, { host: f.server.host })
  expect(read.json.error?.code ?? read.json.code).toBe("auth.forbidden")
  expect(f.nativeCalls).toHaveLength(before)
})

it("refuses an owner whose original install is revoked during the signed Native read", async () => {
  const f = await policyWorld()
  f.onRead(async () => { expect((await f.sessionOp("install.revoke", { install: f.server.install })).json.ok).toBe(true) })
  expect((await f.read()).json.ok).toBe(false)
})

it("does not renew freshness after a slow Native read", async () => {
  const f = await policyWorld(), start = Date.now()
  f.onRead(async () => { vi.spyOn(Date, "now").mockReturnValue(start + 31_000) })
  expect((await f.read()).json.ok).toBe(false)
})

it("bounds the projection to the original grants and never persists the signed read or arbitrary Native fields", async () => {
  const f = await policyWorld()
  f.policies.get(f.server.device)!.peers = [f.nativePeer(f.client, [{ protocol: "tcp", port: 22 }], [])]
  const read = await f.read()
  expect(read.json.ok).toBe(true)
  expect(read.json.value.expires_at).toBeGreaterThan(Date.now())
  expect(read.json.value.expires_at).toBeLessThanOrEqual(Date.now() + 30_000)
  expect(read.json.value.authority_version).toMatch(/^[a-f0-9]{64}$/)
  expect(read.json.value.peers[0].authority_version).toMatch(/^[a-f0-9]{64}$/)
  expect(read.json.value.peers[0]).not.toHaveProperty("grant")
  const state = JSON.stringify(await f.debug())
  for (const value of ["accountCredential", "signature", "policyDigest", "inbound", "outbound"]) expect(state).not.toContain(value)
})
