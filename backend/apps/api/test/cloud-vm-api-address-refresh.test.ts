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

it.each([{ meshId: "mesh_" + "2".repeat(26) }, { vmId: "vm_" + "2".repeat(26) }, { ipv4: "10.129.0.9" }, { ipv4: "10.128.000.9" }])("refuses a mismatched refresh without returning the old route %#", async (patch) => {
  await withMeshMachine({}, async (f) => {
    await f.create()
    f.setNativeRead(async (r) => new URL(r.url).pathname === `/v1/meshes/${MESH}/vms/${VM}` && r.method === "GET"
      ? Response.json({ meshId: MESH, vmId: VM, ipv4: "10.128.0.5", ...patch }) : undefined)
    await expect(f.connect()).rejects.toThrow("owner.unreachable")
    expect(f.creates()).toBe(1)
  })
})

it("coalesces waiting connects and discards a reply after the machine is deleted", async () => {
  await withMeshMachine({}, async (f) => {
    await f.create(); await f.connect()
    const machine = await f.pendingMachine()
    await f.owner().fakeControl({ advance_ms: 60_000 })
    let entered!: () => void, resume!: () => void, reads = 0
    const ready = new Promise<void>((r) => { entered = r }), release = new Promise<void>((r) => { resume = r })
    f.setNativeRead(async (r) => {
      if (new URL(r.url).pathname !== `/v1/meshes/${MESH}/vms/${VM}` || r.method !== "GET") return undefined
      reads++; entered(); await release
      return Response.json({ meshId: MESH, vmId: VM, ipv4: "10.128.0.8" })
    })
    const read = () => f.owner().readOp(f.team, { identity: `user:${f.user}`, kind: "session", user: f.user, team: f.team }, "cloud.machine.connect_info", { machine })
    const first = read(); await ready
    const second = read()
    try { await f.remove(machine) } finally { resume() }
    const replies = await Promise.all([first, second])
    expect(reads).toBe(1)
    for (const reply of replies) expect(reply.ok).toBe(false)
  })
})
