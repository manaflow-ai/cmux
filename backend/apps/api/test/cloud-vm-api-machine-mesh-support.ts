import { env } from "cloudflare:workers"
import type { Principal } from "@cmux/ownership"
import { expect, vi } from "vitest"
import { CloudDO } from "../src/cloud-do.ts"
import type { Env } from "../src/env.ts"
import { mirroredTeam } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"
import { DAEMON, vmKey, WG_KEY } from "./cloud-bind-support.ts"

export const MESH = "mesh_" + "0".repeat(26), OTHER_MESH = "mesh_" + "2".repeat(26), VM = "vm_" + "1".repeat(26)
export const mesh = (id = MESH) => ({ id, ipv4Cidr: "10.128.0.0/20", displayName: "Cloud", createdAt: "2026-10-19T00:00:00Z" })
export interface MeshOptions { lostCreate?: boolean; lostAttach?: boolean; lostMeshCreate?: boolean; meshCreateStatus?: number; meshReadStatus?: number; meshReceipt?: Record<string, unknown>; badVmLookup?: boolean; member?: Record<string, unknown>; meshes?: Array<ReturnType<typeof mesh>> }

/** Real owner, ledger, guard, Native client and bind. Only external Native HTTP is replaced. */
export const withMeshMachine = async (options: MeshOptions, run: (world: {
  team: string; tenant: string; user: string; session: string; calls: string[]; creates: () => number; bindFile: () => Record<string, any> | undefined;
  create: () => ReturnType<CloudDO["submit"]>; retry: () => Promise<void>; restart: (change?: Partial<Env>) => Promise<void>;
  power: (machine: string, phase: "pause" | "start") => ReturnType<CloudDO["submit"]>;
  vmSelf: (principal: Principal, machine: string) => ReturnType<CloudDO["readOp"]>;
  connect: () => Promise<unknown>; owner: () => CloudDO; pendingMachine: () => Promise<string>; remove: (id: string) => ReturnType<CloudDO["submit"]>;
  readyReceiver: () => Promise<void>;
  setMeshes: (values: Array<ReturnType<typeof mesh>>) => void; setNetworkHook: (hook: () => Promise<void>) => void; setAttachHook: (hook: () => Promise<void>) => void;
  meshKeys: string[];
  meshIntent: () => Record<string, unknown> | undefined; replaceMeshIntent: (value: unknown) => void;
  setMeshCreateHook: (hook: () => Promise<void>) => void;
  setNativeRead: (read: (request: Request) => Promise<Response | undefined>) => void;
}) => Promise<void>) => {
  const t = await mirroredTeam("Cloud machine mesh")
  const e = { ...(env as Env), CLOUD_ALLOWED_TEAMS: t.team, CLOUD_VM_TRANSPORT: "vm-api", CLOUD_VM_API_ORIGIN: "https://vm.test", CLOUD_VM_API_SERVICE_KEY: "test-machine-mesh-key", CLOUD_VM_API_IMAGE: "cloud-agent", CLOUD_VM_API_IMAGE_REVISION: "v1" }
  const calls: string[] = []
  let vm: Record<string, any> | undefined, bind: Record<string, any> | undefined, creates = 0, attaches = 0
  let meshes = options.meshes ?? [mesh()]
  const meshKeys: string[] = [], meshCreations = new Map<string, ReturnType<typeof mesh>>()
  let meshCreateHook: (() => Promise<void>) | undefined
  let networkHook: (() => Promise<void>) | undefined, attachHook: (() => Promise<void>) | undefined
  let nativeRead: ((request: Request) => Promise<Response | undefined>) | undefined
  const fallback = globalThis.fetch
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const r = new Request(input, init), url = new URL(r.url)
    if (url.origin !== e.CLOUD_VM_API_ORIGIN) return fallback(input, init)
    const custom = await nativeRead?.(r)
    if (custom) return custom
    expect(url.origin).toBe(e.CLOUD_VM_API_ORIGIN)
    expect(r.headers.get("x-cmux-team-id")).toBe(t.stackTeam)
    expect(r.headers.get("authorization")).toBe(`Bearer ${e.CLOUD_VM_API_SERVICE_KEY}`)
    expect(r.redirect).toBe("manual")
    calls.push(`${r.method} ${url.pathname}`)
    if (url.pathname === "/v1/mesh-creations" && r.method === "POST") {
      const key = r.headers.get("idempotency-key")
      expect(key).toBeTruthy()
      meshKeys.push(key!)
      if (options.meshCreateStatus) return new Response(null, { status: options.meshCreateStatus })
      const body = await r.json() as { displayName: string; labels: Record<string, string> }
      expect(body.labels).toEqual({ role: "cloud" })
      const created = meshCreations.get(key!) ?? { ...mesh(), displayName: body.displayName }
      meshCreations.set(key!, created)
      if (!meshes.some((m) => m.id === created.id)) meshes.push(created)
      const hook = meshCreateHook; meshCreateHook = undefined; await hook?.()
      if (options.lostMeshCreate && meshKeys.length === 1) throw new Error("lost mesh creation reply")
      return Response.json({ ...created, ...options.meshReceipt }, { status: 201 })
    }
    if (url.pathname === `/v1/meshes/${MESH}/vms/${VM}` && r.method === "GET") return Response.json({ meshId: MESH, vmId: VM, ipv4: "10.128.0.5", attachedAt: mesh().createdAt, ...options.member })
    if (url.pathname === "/v1/meshes" || (r.method === "GET" && url.pathname.startsWith("/v1/meshes/"))) {
      const hook = networkHook; networkHook = undefined; await hook?.()
      if (url.pathname === "/v1/meshes") return options.meshReadStatus ? new Response(null, { status: options.meshReadStatus }) : Response.json({ items: meshes })
      const found = meshes.find((m) => url.pathname === `/v1/meshes/${m.id}`)
      return found ? Response.json(found) : new Response(null, { status: 404 })
    }
    if (url.pathname === `/v1/meshes/${MESH}/vms/${VM}`) {
      expect(r.method).toBe("PUT")
      attaches++
      const hook = attachHook; attachHook = undefined; await hook?.()
      if (options.lostAttach && attaches === 1) throw new Error("test lost attachment answer test-machine-mesh-key")
      return Response.json({ meshId: MESH, vmId: VM, ipv4: "10.128.0.5", attachedAt: mesh().createdAt, ...options.member })
    }
    const lookup = () => vm && options.badVmLookup ? { ...vm, labels: { ...vm.labels, cmux_next_machine: "other-machine" } } : vm
    if (url.pathname === "/v1/vms" && r.method === "GET") return Response.json({ items: vm ? [lookup()] : [], nextCursor: null })
    if (url.pathname === "/v1/vms" && r.method === "POST") {
      const body = await r.json() as { displayName: string; labels: Record<string, string> }
      creates++
      vm = { id: VM, displayName: body.displayName, labels: body.labels, state: "running", resources: { vcpus: 2, memoryMib: 4096, diskMib: 16384 }, idleTimeoutSeconds: -1, maxRunSeconds: null, autoDeleteSeconds: null, createdAt: mesh().createdAt, updatedAt: mesh().createdAt }
      if (options.lostCreate && creates === 1) throw new Error("test lost create reply")
      return Response.json({ ...vm, bootImage: { id: "cloud-agent", revision: "v1", displayName: "Cloud" }, initialNetwork: { publicEgress: true, httpsProxyHosts: [] } }, { status: 201 })
    }
    if (r.method === "DELETE") { vm = undefined; return new Response(null, { status: 204 }) }
    if (r.method === "PUT") { bind = JSON.parse(await r.text()); return new Response(null, { status: 204 }) }
    return vm ? Response.json(lookup()) : new Response(null, { status: 404 })
  })
  try {
    const key = await vmKey()
    await inDO(e.CLOUD_DO.get(e.CLOUD_DO.idFromName(t.team)), async (_instance, state) => {
      let owner = new CloudDO(state, e)
      const p = { identity: `user:${t.user}`, kind: "session" as const, user: t.user, team: t.team }
      let vmPrincipal: Principal | undefined
      const initialize = async () => { expect((await owner.readOp(t.team, p, "cloud.machine.list", {})).ok).toBe(true) }
      await initialize()
      const submit = (op: string, params: unknown) => owner.submit(t.team, p, { t: "op", op, params, idempotency_key: crypto.randomUUID(), origin: "user" })
      await run({ team: t.team, tenant: t.stackTeam, user: t.user, session: t.token, calls, meshKeys, creates: () => creates, bindFile: () => bind,
        setNativeRead: (read) => { nativeRead = read },
        meshIntent: () => {
          if (!state.storage.sql.exec("SELECT 1 FROM sqlite_master WHERE type='table' AND name='cloud_mesh_creation'").toArray().length) return undefined
          const row = state.storage.sql.exec<{ data: string }>("SELECT data FROM cloud_mesh_creation WHERE id=1").toArray()[0]
          return row ? JSON.parse(row.data) : undefined
        },
        replaceMeshIntent: (value) => { state.storage.sql.exec("UPDATE cloud_mesh_creation SET data=? WHERE id=1", JSON.stringify(value)) },
        setMeshCreateHook: (hook) => { meshCreateHook = hook },
        create: () => submit("cloud.machine.create", { size: { memory_mb: 4096 } }),
        retry: async () => { await owner.fakeControl({ advance_ms: 60_000 }); await owner.alarm() },
        restart: async (change = {}) => { owner = new CloudDO(state, { ...e, ...change }); await initialize() },
        owner: () => owner,
        pendingMachine: async () => {
          const read = await owner.readOp(t.team, p, "cloud.machine.list", {})
          if (!read.ok) throw new Error(read.code)
          return (read.value as { machines: Array<{ id: string }> }).machines[0]!.id
        },
        remove: (id) => submit("cloud.machine.delete", { machine: id }),
        connect: async () => {
          if (!bind) throw new Error("no bind file")
          const bound = await owner.bindMachine(t.team, { ...bind, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk } as any)
          expect(bound).toMatchObject({ ok: true })
          if (!bound.ok) throw new Error(bound.code)
          const identity = (bound.value as { install: { id: string; user: string; grant: string } }).install
          vmPrincipal = { identity: identity.id, kind: "install", user: identity.user, team: t.team, install: identity.id,
            grant: identity.grant, install_kind: "vm", bound_machine: bind.machine, grant_classes: ["vm-self"] }
          await initialize()
          const read = await owner.readOp(t.team, p, "cloud.machine.connect_info", { machine: bind.machine })
          if (!read.ok) throw new Error(read.code)
          return read.value
        },
        readyReceiver: async () => {
          if (!vmPrincipal || !bind) throw new Error("connect the original VM first")
          const lifecycle = (params: object) => owner.vmOp(t.team, vmPrincipal!, "cloud.vm.receiver.lifecycle", { machine: bind!.machine, ...params })
          const initial = await lifecycle({ phase: "read" })
          if (!initial.ok) throw new Error(initial.code)
          const first = await lifecycle({ phase: "begin", expected: (initial.value as { generation: string }).generation, attempt: crypto.randomUUID().replaceAll("-", "") })
          if (!first.ok) throw new Error(first.code)
          const ready = await lifecycle({ phase: "ready", expected: (first.value as { generation: string }).generation })
          expect(ready.ok).toBe(true)
        },
        power: (machine, phase) => inDO(e.CLOUD_DO.get(e.CLOUD_DO.idFromName(t.team)), async (_instance, state) =>
          new CloudDO(state, e).submit(t.team, p, { t: "op", op: `cloud.machine.${phase}`, params: { machine }, idempotency_key: crypto.randomUUID(), origin: "cli" })),
        vmSelf: (principal, machine) => inDO(e.CLOUD_DO.get(e.CLOUD_DO.idFromName(t.team)), async (_instance, state) =>
          new CloudDO(state, e).readOp(t.team, principal, "cloud.vm.self.get", { machine })),
        setMeshes: (values) => { meshes = values }, setNetworkHook: (hook) => { networkHook = hook }, setAttachHook: (hook) => { attachHook = hook }
      })
    })
  } finally { spy.mockRestore() }
}
