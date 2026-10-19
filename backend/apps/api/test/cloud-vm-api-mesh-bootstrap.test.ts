import { expect, it } from "vitest"
import { MESH, VM, withMeshMachine } from "./cloud-vm-api-machine-mesh-support.ts"

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
