import { afterEach, expect, it, vi } from "vitest"
import { testEnv } from "./pairing-harness.ts"
import { policyWorld } from "./cloud-vm-api-host-policy-support.ts"
afterEach(() => vi.restoreAllMocks())

it("uses the same current identity version in the receiving peer view and the actual Cloud authorization owner", async () => {
  const f = await policyWorld(), vm = "vm_" + "1".repeat(26)
  f.policies.get(f.server.device)!.peers = [f.nativePeer(f.client, [{ protocol: "tcp", port: 22 }], [])]
  const policy = f.policies.get(f.client.device)!
  policy.vms = [{ id: vm, kind: "vm", address: "10.128.0.5", allow: [{ protocol: "tcp", port: 22 }] }]
  const read = await f.read()
  expect(read.status).toBe(200)
  const owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(f.team.team))
  const result = await owner.authorizeCloudDial(f.team.team, {
    kind: "install", identity: `install:${f.client.install}`, team: f.team.team, user: f.client.user,
    install: f.client.install, grant: f.client.grant, install_kind: "mac", grant_classes: ["read", "mutate-own", "cloud-link"]
  }, { vm, origin: "https://vm.test", network: { tenant: f.team.stackTeam, mesh: String(policy.meshId), ipv4_cidr: "10.128.0.0/20", ipv4: "10.128.0.5" } }, await f.proof(f.client), ["ssh"])
  expect(result).toMatchObject({ ok: true, permit: { authorityVersion: read.json.value.peers[0].authority_version } })
})
