import { afterEach, expect, it, vi } from "vitest"
import { withReceiver, type Allow } from "./cloud-vm-api-receiver-support.ts"
afterEach(() => vi.restoreAllMocks())
const nativePeer = (f: Parameters<Parameters<typeof withReceiver>[0]>[0], allow: Allow[] = [{ protocol: "tcp", port: 22 }]) =>
  ({ deviceId: f.client.device, wgPublicKey: f.client.wg, installPublicKey: f.client.point, allow })

it("keeps the bound VM's existing self read working", async () => {
  await withReceiver(async (f) => { expect(await f.self()).toMatchObject({ ok: true, value: { machine: { id: f.machine } } }) })
})

it.each(["session", "client", "agent", "wrong-grant", "wrong-user", "wrong-team", "wrong-machine", "old-authority"])("refuses %s authority before Native policy HTTP", async (kind) => {
  await withReceiver(async (f) => {
    const p = { ...f.principal }
    if (kind === "session") p.kind = "session"
    if (kind === "client") p.install_kind = "mac"
    if (kind === "agent") p.agent = "agt_" + "0".repeat(20)
    if (kind === "wrong-grant") p.grant = "grant_" + "0".repeat(20)
    if (kind === "wrong-user") p.user = "user_" + "0".repeat(20)
    if (kind === "wrong-team") p.team = "team_" + "0".repeat(20)
    if (kind === "wrong-machine") p.bound_machine = "vm_" + "0".repeat(20)
    if (kind === "old-authority") p.install_authority = "0".repeat(64)
    expect(await f.read(p)).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(f.requests).toHaveLength(0)
  })
})

it.each(["revoked-vm", "revoked-client", "narrowed-client"])("uses the original grant after %s", async (kind) => {
  await withReceiver(async (f) => {
    f.native.peers = [nativePeer(f)]
    if (kind === "narrowed-client") await f.grant("client", { op_classes: ["read", "mutate-own"] })
    else expect((await f.sessionOp("install.revoke", { install: kind === "revoked-vm" ? f.principal.install : f.client.install })).json.ok).toBe(true)
    const read = await f.read()
    expect(read).toMatchObject(kind === "revoked-vm" ? { ok: false, code: "auth.forbidden" } : { ok: true, value: { peers: [] } })
    if (kind === "revoked-vm") expect(f.requests).toHaveLength(0)
  })
})

it.each(["vm", "client"] as const)("never leases past the original %s grant expiry", async (which) => {
  await withReceiver(async (f) => {
    const expiry = Date.now() + 10_000
    f.native.peers = [nativePeer(f)]
    await f.grant(which, { expires_at: expiry })
    expect(await f.read()).toMatchObject({ ok: true, value: { expires_at: expiry } })
  })
})

it("clips the lease to the calling credential and never extends Native freshness on arrival", async () => {
  await withReceiver(async (f) => {
    f.native.checkedAt = Date.now() - 20_000; f.native.expiresAt = Date.now() + 8_000
    const read = await f.read()
    expect(read).toMatchObject({ ok: true, value: { expires_at: f.native.expiresAt } })
    const expires_at = Date.now() + 4_000
    expect(await f.read({ ...f.principal, expires_at })).toMatchObject({ ok: true, value: { expires_at } })
  })
})

it("keeps the Native digest independent of a shortened usable lease", async () => {
  await withReceiver(async (f) => {
    const first = await f.read(); expect(first.ok).toBe(true)
    f.native.expiresAt = Date.now() + 8_000
    const second = await f.read(); expect(second.ok).toBe(true)
    expect(second.value.policy_digest).toBe(first.value.policy_digest)
    expect(second.value.expires_at).toBeLessThan(first.value.expires_at)
  })
})

it.each(["vm", "client", "allocation", "delete"] as const)("refuses or removes authority changed during Native HTTP: %s", async (change) => {
  await withReceiver(async (f) => {
    f.native.peers = [nativePeer(f)]
    f.onRead(async () => {
      if (change === "allocation") f.badAllocation()
      else if (change === "delete") await f.remove()
      else expect((await f.sessionOp("install.revoke", { install: change === "vm" ? f.principal.install : f.client.install })).json.ok).toBe(true)
    })
    const read = await f.read()
    expect(read).toMatchObject(change === "client" ? { ok: true, value: { peers: [] } } : { ok: false })
  })
})

it.each([
  { schemaVersion: 2 }, { tenantId: "other_tenant" }, { meshId: "mesh_" + "3".repeat(26) }, { vmId: "vm_" + "3".repeat(26) },
  { ipv4: "10.129.0.5" }, { policyDigest: "bad" }, { checkedAt: 1, expiresAt: 60_000 }
])("refuses a mismatched or unsupported Native policy %#", async (patch) => {
  await withReceiver(async (f) => {
    Object.assign(f.native, patch)
    expect(await f.read()).toMatchObject({ ok: false, code: "owner.unreachable" })
  })
})

it.each(["deviceId", "wgPublicKey", "installPublicKey"] as const)("refuses duplicate Native %s", async (field) => {
  await withReceiver(async (f) => {
    const first = nativePeer(f), other = { ...first, deviceId: "dev_" + "3".repeat(26), wgPublicKey: btoa("d".repeat(32)), installPublicKey: btoa(String.fromCharCode(4) + "e".repeat(64)), [field]: first[field] }
    f.native.peers = [first, other]
    expect(await f.read()).toMatchObject({ ok: false, code: "owner.unreachable" })
  })
})

it.each([302, 403, 404, 503])("never follows or falls back after Native HTTP %s", async (status) => {
  await withReceiver(async (f) => {
    f.nativeResponse(() => new Response(null, { status, headers: { location: "https://another.test/steal" } }))
    expect(await f.read()).toMatchObject({ ok: false, code: "owner.unreachable" })
    expect(f.requests).toHaveLength(1)
  })
})

it("bounds Native response bytes", async () => {
  await withReceiver(async (f) => {
    f.nativeResponse(() => new Response("x".repeat(1_048_577)))
    expect(await f.read()).toMatchObject({ ok: false })
  })
})

it("audits the bound VM and outcome without credentials or raw Native policy", async () => {
  await withReceiver(async (f) => {
    expect((await f.read()).ok).toBe(true)
    const audit = (await f.audit()).filter((row) => row.op === "vm_network_policy")
    expect(audit).toEqual([expect.objectContaining({ machine: f.machine, install: f.principal.install, user: f.user, outcome: "ok" })])
    for (const secret of ["test-machine-mesh-key", "policyDigest", "signature", "grant"]) expect(JSON.stringify(audit)).not.toContain(secret)
  })
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
