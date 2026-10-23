import { expect, it } from "vitest"
import { MESH, OTHER_MESH, VM, mesh, withMeshMachine } from "./cloud-vm-api-machine-mesh-support.ts"

it.each([false, true])("attaches the actual Cloud VM before binding and preserves its mesh across restart (lost create reply: %s)", async (lostCreate) => {
  await withMeshMachine({ lostCreate }, async (f) => {
    const reply = await f.create()
    if (lostCreate) {
      expect(reply.frames).toContainEqual(expect.objectContaining({ t: "reject", code: "mutation.indeterminate" }))
      await f.restart(); await f.retry()
    }
    expect(f.bindFile()).toBeDefined()
    expect(f.creates()).toBe(1)
    expect(f.calls).toContain(`PUT /v1/meshes/${MESH}/vms/${VM}`)
    await f.restart()
    expect(await f.connect()).toMatchObject({ network: { tenant: f.tenant, mesh: MESH, ipv4_cidr: mesh().ipv4Cidr, ipv4: "10.128.0.5" } })
  })
})

it("recovers a lost attachment answer with the same pinned mesh and VM before writing a bind token", async () => {
  await withMeshMachine({ lostAttach: true }, async (f) => {
    expect((await f.create()).frames).toContainEqual(expect.objectContaining({ t: "reject", code: "mutation.indeterminate" }))
    expect(f.bindFile()).toBeUndefined()
    f.setMeshes([mesh(OTHER_MESH), mesh()])
    await f.restart(); await f.retry()
    expect(f.creates()).toBe(1)
    expect(f.calls.filter((c) => c === `PUT /v1/meshes/${MESH}/vms/${VM}`)).toHaveLength(2)
    expect(f.calls).toContain(`GET /v1/meshes/${MESH}`)
    expect(f.calls.filter((c) => c === "GET /v1/meshes")).toHaveLength(1)
    expect(await f.connect()).toMatchObject({ network: { mesh: MESH } })
    expect(JSON.stringify(await f.owner().debug(f.team))).not.toContain("test-machine-mesh-key")
  })
})

it.each([{ meshes: [mesh(), mesh(OTHER_MESH)] }])("refuses an ambiguous mesh before allocating a VM %#", async ({ meshes }) => {
  await withMeshMachine({ meshes }, async (f) => {
    await f.create()
    expect(f.creates()).toBe(0)
    expect(f.bindFile()).toBeUndefined()
    expect(f.calls.every((c) => c.startsWith("GET "))).toBe(true)
  })
})

it.each([
  { meshId: OTHER_MESH }, { vmId: "vm_" + "3".repeat(26) },
  { ipv4: "10.129.0.5" }, { ipv4: "10.128.0.0" }, { ipv4: "10.128.15.255" }, { ipv4: "10.128.000.5" }
])("does not bind after a mismatched attachment receipt %#", async (member) => {
  await withMeshMachine({ member }, async (f) => { await f.create(); expect(f.bindFile()).toBeUndefined() })
})

it("keeps an unknown provider address explicit instead of inventing a reachable endpoint", async () => {
  await withMeshMachine({ member: { ipv4: null } }, async (f) => {
    await f.create()
    expect(await f.connect()).toMatchObject({ network: { ipv4: null }, gateway: null, peer: { vpc_endpoint: null } })
  })
})

it("rechecks VM ownership immediately before attaching", async () => {
  await withMeshMachine({ badVmLookup: true }, async (f) => {
    await f.create()
    expect(f.bindFile()).toBeUndefined()
    expect(f.calls.some((c) => c.startsWith("PUT /v1/meshes/"))).toBe(false)
  })
})

it("does not reinterpret a persisted mesh after changing the configured service origin", async () => {
  await withMeshMachine({ lostAttach: true }, async (f) => {
    await f.create()
    const count = f.calls.length
    await f.restart({ CLOUD_VM_API_ORIGIN: "https://another.test" }); await f.retry()
    expect(f.calls).toHaveLength(count)
    expect(f.bindFile()).toBeUndefined()
  })
})

it.each(["discovery", "attachment"] as const)("cancels during %s without writing a bind token or starting more network work", async (phase) => {
  await withMeshMachine({}, async (f) => {
    let entered!: () => void, resume!: () => void, deleted!: () => void
    const ready = new Promise<void>((r) => { entered = r }), release = new Promise<void>((r) => { resume = r }), committed = new Promise<void>((r) => { deleted = r })
    const hook = async () => { entered(); await release }
    if (phase === "discovery") f.setNetworkHook(hook); else f.setAttachHook(hook)
    const owner = f.owner(), after = Reflect.get(owner, "afterOp")
    Reflect.set(owner, "afterOp", (...args: unknown[]) => { Reflect.apply(after, owner, args); if (args[1] === "cloud.machine.delete") deleted() })
    const creating = f.create()
    await ready
    const removing = f.remove(await f.pendingMachine())
    await committed; resume()
    await Promise.all([creating, removing])
    expect(f.bindFile()).toBeUndefined()
    expect(f.creates()).toBe(phase === "discovery" ? 0 : 1)
    expect(f.calls.filter((c) => c.startsWith("PUT /v1/meshes/"))).toHaveLength(phase === "discovery" ? 0 : 1)
  })
})
