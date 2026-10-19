import { env } from "cloudflare:workers"
import { expect, it, vi } from "vitest"
import { CloudDO } from "../src/cloud-do.ts"
import type { Env } from "../src/env.ts"
import { mirroredTeam } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"
import { DAEMON, vmKey, WG_KEY } from "./cloud-bind-support.ts"

const MESH = "mesh_" + "0".repeat(26), VM = "vm_" + "1".repeat(26)
const mesh = { id: MESH, ipv4Cidr: "10.128.0.0/20", displayName: "Cloud", createdAt: "2026-10-19T00:00:00Z" }

it.each([false, true])("attaches the actual Cloud VM before binding and preserves its mesh across restart (lost create reply: %s)", async (lostReply) => {
  const t = await mirroredTeam("Cloud machine mesh")
  const e = { ...(env as Env), CLOUD_ALLOWED_TEAMS: t.team, CLOUD_VM_TRANSPORT: "vm-api", CLOUD_VM_API_ORIGIN: "https://vm.test", CLOUD_VM_API_SERVICE_KEY: "test-machine-mesh-key", CLOUD_VM_API_IMAGE: "cloud-agent", CLOUD_VM_API_IMAGE_REVISION: "v1" }
  const calls: string[] = []
  let vm: Record<string, any> | undefined, bind: Record<string, any> | undefined, creates = 0
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const r = new Request(input, init), url = new URL(r.url)
    expect(url.origin).toBe(e.CLOUD_VM_API_ORIGIN)
    expect(r.headers.get("x-cmux-team-id")).toBe(t.stackTeam)
    expect(r.headers.get("authorization")).toBe(`Bearer ${e.CLOUD_VM_API_SERVICE_KEY}`)
    expect(r.redirect).toBe("manual")
    calls.push(`${r.method} ${url.pathname}`)
    if (url.pathname === "/v1/meshes") return Response.json({ items: [mesh] })
    if (url.pathname === `/v1/meshes/${MESH}`) return Response.json(mesh)
    if (url.pathname === `/v1/meshes/${MESH}/vms/${VM}`) return Response.json({ meshId: MESH, vmId: VM, ipv4: "10.128.0.5", attachedAt: mesh.createdAt })
    if (url.pathname === "/v1/vms" && r.method === "GET") return Response.json({ items: vm ? [vm] : [], nextCursor: null })
    if (url.pathname === "/v1/vms" && r.method === "POST") {
      const body = await r.json() as { displayName: string; labels: Record<string, string> }
      creates++
      vm = { id: VM, displayName: body.displayName, labels: body.labels, state: "running", resources: { vcpus: 2, memoryMib: 4096, diskMib: 16384 }, idleTimeoutSeconds: -1, maxRunSeconds: null, autoDeleteSeconds: null, createdAt: mesh.createdAt, updatedAt: mesh.createdAt }
      if (lostReply && creates === 1) throw new Error("test lost create reply")
      return Response.json({ ...vm, bootImage: { id: "cloud-agent", revision: "v1", displayName: "Cloud" }, initialNetwork: { publicEgress: true, httpsProxyHosts: [] } }, { status: 201 })
    }
    if (r.method === "PUT") { bind = JSON.parse(await r.text()); return new Response(null, { status: 204 }) }
    return vm ? Response.json(vm) : new Response(null, { status: 404 })
  })
  try {
    const key = await vmKey()
    await inDO(e.CLOUD_DO.get(e.CLOUD_DO.idFromName(t.team)), async (_instance, state) => {
      let owner = new CloudDO(state, e)
      const p = { identity: `user:${t.user}`, kind: "session" as const, user: t.user, team: t.team }
      const request = { t: "op" as const, op: "cloud.machine.create", params: { size: { memory_mb: 4096 } }, idempotency_key: crypto.randomUUID(), origin: "user" as const }
      const reply = await owner.submit(t.team, p, request)
      if (lostReply) {
        expect(reply.frames).toContainEqual(expect.objectContaining({ t: "reject", code: "mutation.indeterminate" }))
        owner = new CloudDO(state, e)
        await owner.fakeControl({ advance_ms: 60_000 })
        await owner.alarm()
      }
      expect(bind).toBeDefined()
      expect(creates).toBe(1)
      expect(calls).toContain(`PUT /v1/meshes/${MESH}/vms/${VM}`)
      const bound = bind!
      expect(await owner.bindMachine(t.team, { ...bound, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk } as any)).toMatchObject({ ok: true })
      owner = new CloudDO(state, e)
      const read = await owner.readOp(t.team, p, "cloud.machine.connect_info", { machine: bound.machine })
      expect(read).toMatchObject({ ok: true, value: { network: { tenant: t.stackTeam, mesh: MESH, ipv4_cidr: mesh.ipv4Cidr, ipv4: "10.128.0.5" } } })
    })
  } finally { spy.mockRestore() }
})
