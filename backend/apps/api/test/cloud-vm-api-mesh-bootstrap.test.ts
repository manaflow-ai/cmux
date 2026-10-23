import { expect, it } from "vitest"
import { MESH, OTHER_MESH, VM, mesh, withMeshMachine } from "./cloud-vm-api-machine-mesh-support.ts"

it("creates the first team mesh before allocating and attaching a Cloud VM", async () => {
  await withMeshMachine({ meshes: [] }, async (f) => {
    await f.create()
    expect(f.bindFile()).toBeDefined()
    expect(f.creates()).toBe(1)
    expect(f.meshKeys).toHaveLength(1)
    expect(f.calls.indexOf("POST /v1/mesh-creations")).toBeLessThan(f.calls.indexOf("POST /v1/vms"))
    expect(f.calls).toContain(`PUT /v1/meshes/${MESH}/vms/${VM}`)
    expect(await f.connect()).toMatchObject({ network: { tenant: f.tenant, mesh: MESH } })
  })
})

it("persists the original key before I/O and resumes it after losing the mesh response and restarting", async () => {
  await withMeshMachine({ meshes: [], lostMeshCreate: true }, async (f) => {
    f.setMeshCreateHook(async () => {
      expect(f.meshIntent()).toMatchObject({ version: 2, key: f.meshKeys[0], team: f.team, tenant: f.tenant, origin: "https://vm.test", body: { displayName: "Cloud network", labels: { role: "cloud" } } })
      expect(JSON.stringify(f.meshIntent())).not.toContain("test-machine-mesh-key")
    })
    await f.create()
    expect(f.bindFile()).toBeUndefined()
    expect(f.creates()).toBe(0)
    const key = f.meshKeys[0]
    // The retained creation wins over a different network discovered on a later attempt.
    f.setMeshes([mesh(OTHER_MESH)])
    await f.restart(); await f.retry()
    expect(f.meshKeys).toEqual([key, key])
    expect(f.calls.filter((c) => c === "GET /v1/meshes")).toHaveLength(1)
    expect(f.creates()).toBe(1)
    expect(await f.connect()).toMatchObject({ network: { mesh: MESH } })
    expect(JSON.stringify(await f.owner().debug(f.team))).not.toContain("test-machine-mesh-key")
  })
})

it.each([404, 403, 503, 302])("does not interpret a mesh lookup HTTP %s as an empty team", async (meshReadStatus) => {
  await withMeshMachine({ meshes: [], meshReadStatus }, async (f) => {
    await f.create()
    expect(f.meshKeys).toHaveLength(0)
    expect(f.meshIntent()).toBeUndefined()
    expect(f.creates()).toBe(0)
    expect(f.bindFile()).toBeUndefined()
  })
})

it.each([404, 403, 402, 409, 429, 503, 302])("does not allocate a VM or use the legacy route after creation HTTP %s", async (meshCreateStatus) => {
  await withMeshMachine({ meshes: [], meshCreateStatus }, async (f) => {
    const result = await f.create()
    expect(f.meshKeys).toHaveLength(1)
    expect(f.creates()).toBe(0)
    expect(f.bindFile()).toBeUndefined()
    expect(f.calls).not.toContain("POST /v1/meshes")
    expect(JSON.stringify(result)).not.toContain("test-machine-mesh-key")
  })
})

it.each([{ id: "vpc-private-id" }, { ipv4Cidr: "0.0.0.0/0" }, { displayName: "Another network" }])("refuses an unconfirmed creation receipt before VM allocation %#", async (meshReceipt) => {
  await withMeshMachine({ meshes: [], meshReceipt }, async (f) => {
    await f.create()
    expect(f.meshKeys).toHaveLength(1)
    expect(f.creates()).toBe(0)
    expect(f.bindFile()).toBeUndefined()
  })
})

it.each(["origin", "corrupt"] as const)("does not replace an uncertain mesh intent after %s changes", async (change) => {
  await withMeshMachine({ meshes: [], lostMeshCreate: true }, async (f) => {
    await f.create()
    const before = f.calls.length
    if (change === "corrupt") f.replaceMeshIntent({ ...f.meshIntent(), version: 999 })
    await f.restart(change === "origin" ? { CLOUD_VM_API_ORIGIN: "https://another.test" } : {}); await f.retry()
    expect(f.calls).toHaveLength(before)
    expect(f.creates()).toBe(0)
    expect(f.bindFile()).toBeUndefined()
  })
})

it.each(["discovery", "creation"] as const)("cancels during first-mesh %s before later allocation or binding", async (phase) => {
  await withMeshMachine({ meshes: [] }, async (f) => {
    let entered!: () => void, resume!: () => void, deleted!: () => void
    const ready = new Promise<void>((r) => { entered = r }), release = new Promise<void>((r) => { resume = r }), committed = new Promise<void>((r) => { deleted = r })
    const hook = async () => { entered(); await release }
    if (phase === "discovery") f.setNetworkHook(hook); else f.setMeshCreateHook(hook)
    const owner = f.owner(), after = Reflect.get(owner, "afterOp")
    Reflect.set(owner, "afterOp", (...args: unknown[]) => { Reflect.apply(after, owner, args); if (args[1] === "cloud.machine.delete") deleted() })
    const creating = f.create()
    await ready
    const removing = f.remove(await f.pendingMachine())
    await committed; resume()
    await Promise.all([creating, removing])
    expect(f.creates()).toBe(0)
    expect(f.bindFile()).toBeUndefined()
    expect(f.meshKeys).toHaveLength(phase === "discovery" ? 0 : 1)
  })
})
