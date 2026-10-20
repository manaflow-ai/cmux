import { expect, it } from "vitest"
import { MESH, VM, mesh, withMeshMachine } from "./cloud-vm-api-machine-mesh-support.ts"

it.each([null, "10.128.0.5"])("refreshes a bound machine's missing or stale address before connecting (was %s)", async (ipv4) => {
  await withMeshMachine({ member: { ipv4 } }, async (f) => {
    await f.create()
    f.setNativeRead(async (r) => new URL(r.url).pathname === `/v1/meshes/${MESH}/vms/${VM}` && r.method === "GET"
      ? Response.json({ meshId: MESH, vmId: VM, ipv4: "10.128.0.8", attachedAt: mesh().createdAt }) : undefined)
    expect(await f.connect()).toMatchObject({ network: { tenant: f.tenant, mesh: MESH, ipv4: "10.128.0.8" } })
    await f.restart()
    const read = await f.owner().readOp(f.team, { identity: `user:${f.user}`, kind: "session", user: f.user, team: f.team },
      "cloud.machine.connect_info", { machine: await f.pendingMachine() })
    expect(read).toMatchObject({ ok: true, value: { network: { ipv4: "10.128.0.8" } } })
    expect(f.creates()).toBe(1)
    expect(f.calls.filter((c) => c.startsWith("PUT /v1/meshes/"))).toHaveLength(1)
  })
})

it("keeps the original address when it is still current", async () => {
  await withMeshMachine({}, async (f) => {
    await f.create()
    f.setNativeRead(async (r) => new URL(r.url).pathname === `/v1/meshes/${MESH}/vms/${VM}` && r.method === "GET"
      ? Response.json({ meshId: MESH, vmId: VM, ipv4: "10.128.0.5", attachedAt: mesh().createdAt }) : undefined)
    expect(await f.connect()).toMatchObject({ network: { mesh: MESH, ipv4: "10.128.0.5" } })
  })
})
