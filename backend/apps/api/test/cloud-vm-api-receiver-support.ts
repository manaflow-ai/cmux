import type { Principal } from "@cmux/ownership"
import { env } from "cloudflare:workers"
import { expect } from "vitest"
import type { Env } from "../src/env.ts"
import type { PublicKeyset } from "../src/link-token.ts"
import { b64u, call, inDO, testEnv } from "./pairing-harness.ts"
import { installPublicPoint } from "../src/install-public-point.ts"
import { DAEMON, vmKey, WG_KEY } from "./cloud-bind-support.ts"
import { MESH, VM, withMeshMachine } from "./cloud-vm-api-machine-mesh-support.ts"

export type Allow = { protocol: "tcp" | "udp" | "icmp" | "any"; port?: number }

/** Real Cloud bind, original UserDO grant, client enrollment and confirmed TeamDO identity. */
export const withReceiver = async (run: (f: {
  team: string; user: string; tenant: string; machine: string; host: string; principal: Principal;
  client: { host: string; user: string; install: string; grant: string; device: string; wg: string; point: string };
  native: Record<string, unknown>; requests: Request[]; read: (p?: Principal, params?: unknown) => Promise<any>;
  self: () => Promise<any>; sessionOp: (op: string, params: unknown) => Promise<any>;
  onRead: (hook: () => Promise<void>) => void; remove: () => Promise<unknown>;
  onDial: (hook: () => Promise<void>) => void;
  grant: (which: "vm" | "client", patch: Record<string, unknown>) => Promise<void>;
  audit: () => Promise<Array<Record<string, unknown>>>;
  nativeResponse: (make: () => Response) => void;
  badAllocation: () => void;
  mint: () => Promise<any>; readHttp: () => Promise<any>; keyset: PublicKeyset["keys"];
  lifecycleHttp: (params: Record<string, unknown>, options?: { caller?: "vm" | "client" | "session"; idempotency_key?: string }) => Promise<any>;
}) => Promise<void>) => withMeshMachine({}, async (w) => {
  await w.create()
  const bind = w.bindFile()
  if (!bind) throw new Error("no VM bind file")
  const machine = String(bind.machine), key = await vmKey()
  const bound = await w.owner().bindMachine(w.team, { ...bind, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk })
  expect(bound.ok).toBe(true)
  if (!bound.ok) throw new Error(bound.code)
  const value = bound.value as { host: string; keyset: PublicKeyset; install: { id: string; user: string; grant: string } }
  const principal: Principal = { identity: value.install.id, kind: "install", user: w.user, team: w.team,
    install: value.install.id, grant: value.install.grant, install_kind: "vm", bound_machine: machine, grant_classes: ["vm-self"] }
  await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(w.team)), async (owner) => {
    owner.env = { ...owner.env, CLOUD_VM_API_ORIGIN: "https://vm.test", CLOUD_VM_API_SERVICE_KEY: "test-machine-mesh-key" }
  })
  const sessionOp = (op: string, params: unknown) => call("/v1/ops", w.session,
    { op, params, idempotency_key: crypto.randomUUID(), origin: "cli" }, { "x-cmux-team": w.team })
  const pair = await vmKey(), registered = await sessionOp("install.register", {
    public_jwk: pair.jwk, kind: "mac", name: "Receiver client", device_name: "Laptop", platform: "macos"
  })
  expect(registered.json.ok).toBe(true)
  const install = registered.json.value.id as string
  const challenge = await call("/v1/auth/challenge", undefined, { user: w.user, install, team: w.team })
  expect(challenge.status).toBe(200)
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.pair.privateKey,
    new TextEncoder().encode(`${challenge.json.message_prefix}${challenge.json.nonce}`))
  const issued = await call("/v1/auth/token", undefined, { user: w.user, install, nonce: challenge.json.nonce, signature: b64u(signature) })
  expect(issued.status).toBe(200)
  const token = issued.json.access_token as string
  const op = (op: string, params: unknown) => call("/v1/ops", token,
    { op, params, idempotency_key: crypto.randomUUID(), origin: "cli" }, { "x-cmux-team": w.team })
  const enrolled = await op("host.enroll", { name: "Receiver client", platform: "macos" })
  expect(enrolled.json.ok).toBe(true)
  const point = installPublicPoint(pair.jwk)
  const client = { host: enrolled.json.value.id as string, user: w.user, install, grant: issued.json.grant as string,
    device: "dev_" + "2".repeat(26), wg: btoa("c".repeat(32)), point }
  const requests: Request[] = []
  const checkedAt = Date.now()
  const native: Record<string, unknown> = { schemaVersion: 1, tenantId: w.tenant, meshId: MESH, vmId: VM, ipv4: "10.128.0.5",
    aclVersion: 1, checkedAt, expiresAt: checkedAt + 30_000, policyDigest: "a".repeat(64), peers: [] }
  let hook: (() => Promise<void>) | undefined
  let dialHook: (() => Promise<void>) | undefined
  let response: (() => Response) | undefined
  let badAllocation = false
  const used = new Set<string>()
  w.setNativeRead(async (r) => {
    const path = new URL(r.url).pathname
    if (badAllocation && path === "/v1/vms" && r.method === "GET") return Response.json({ items: [], nextCursor: null })
    if (path === `/v1/devices/${client.device}/signed/overlay-policy`) {
      const before = dialHook; dialHook = undefined; await before?.()
      expect(r.headers.has("authorization")).toBe(false)
      const proof = await r.json() as { signedAt: number; nonce: string; signature: string }
      const message = ["cmux-mesh-v1", "overlay-policy", client.device, "", point, "", String(proof.signedAt), proof.nonce].join("\n")
      if (!await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.pair.publicKey,
        Uint8Array.from(atob(proof.signature), (c) => c.charCodeAt(0)), new TextEncoder().encode(message))) return new Response(null, { status: 403 })
      if (used.has(proof.nonce)) return new Response(null, { status: 409 })
      used.add(proof.nonce)
      const entry = (native.peers as Array<{ deviceId: string; allow: Allow[] }>).find((p) => p.deviceId === client.device)
      return Response.json({ tenantId: w.tenant, meshId: MESH, deviceId: client.device, wgPublicKey: client.wg, installPublicKey: point,
        aclVersion: native.aclVersion, policyDigest: "b".repeat(64), vms: [{ kind: "vm", id: VM, address: native.ipv4, allow: entry?.allow ?? [] }] })
    }
    if (path !== `/v1/meshes/${MESH}/vms/${VM}/receiver-policy`) return undefined
    requests.push(r)
    expect(r.method).toBe("GET"); expect(r.redirect).toBe("manual")
    expect(r.headers.get("authorization")).toBe("Bearer test-machine-mesh-key")
    expect(r.headers.get("x-cmux-team-id")).toBe(w.tenant)
    expect(r.headers.has("cookie")).toBe(false)
    const before = hook; hook = undefined; await before?.()
    return response ? response() : Response.json(native)
  })
  const proof = async () => {
    const signedAt = Date.now(), nonce = b64u(crypto.getRandomValues(new Uint8Array(16)).buffer)
    const message = ["cmux-mesh-v1", "overlay-policy", client.device, "", point, "", String(signedAt), nonce].join("\n")
    return { signedAt, nonce, signature: btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" }, pair.pair.privateKey, new TextEncoder().encode(message))))) }
  }
  expect((await op("host.network.bind", { host: client.host, mesh: MESH, device: client.device, wg_public_key: client.wg, proof: await proof() })).json.ok).toBe(true)
  let vmAccessToken: string | undefined
  const vmToken = async () => {
    if (vmAccessToken) return vmAccessToken
    const ns = (env as Env).CLOUD_DO
    await inDO(ns.get(ns.idFromName(w.team)), async (owner) => {
      owner.env = { ...owner.env, CLOUD_VM_API_ORIGIN: "https://vm.test", CLOUD_VM_API_SERVICE_KEY: "test-machine-mesh-key",
        CLOUD_VM_API_IMAGE: "cloud-agent", CLOUD_VM_API_IMAGE_REVISION: "v1" }
    })
    const ch = await call("/v1/auth/challenge", undefined, { user: w.user, install: value.install.id })
    expect(ch.status).toBe(200)
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key.pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
    const issued = await call("/v1/auth/token", undefined, { user: w.user, install: value.install.id, nonce: ch.json.nonce, signature: b64u(sig) })
    expect(issued.status).toBe(200)
    vmAccessToken = issued.json.access_token as string
    return vmAccessToken
  }
  await run({ team: w.team, user: w.user, tenant: w.tenant, machine, host: value.host, principal, client, native, requests,
    read: (p = principal, params = { machine }) => w.owner().readOp(w.team, p, "cloud.vm.network_policy", params),
    self: () => w.owner().readOp(w.team, principal, "cloud.vm.self.get", { machine }), sessionOp,
    onRead: (value) => { hook = value }, remove: () => w.remove(machine),
    onDial: (value) => { dialHook = value },
    nativeResponse: (make) => { response = make }, badAllocation: () => { badAllocation = true },
    keyset: value.keyset.keys,
    mint: async () => w.owner().mintLinkToken(w.team, { identity: client.install, kind: "install", user: w.user, team: w.team,
      install: client.install, grant: client.grant, install_kind: "mac", grant_classes: ["read", "mutate-own", "cloud-link"] },
      { host: value.host, services: ["ssh"], native_proof: await proof() }),
    readHttp: async () => call("/v1/read", await vmToken(), { op: "cloud.vm.network_policy", params: { machine } }),
    lifecycleHttp: async (params, options = {}) => call("/v1/ops", options.caller === "client" ? token : options.caller === "session" ? w.session : await vmToken(),
      { op: "cloud.vm.receiver.lifecycle", params: { machine, ...params }, ...(options.idempotency_key ? { idempotency_key: options.idempotency_key } : {}) },
      { "x-cmux-team": w.team }),
    audit: async () => (await w.owner().fakeControl({})).audit,
    grant: async (which, patch) => inDO(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(w.user)), async (owner) => {
      const state = owner.bind(w.user).currentState, id = which === "vm" ? value.install.grant : client.grant
      state.grants[id] = { ...state.grants[id], ...patch }
    }) })
})
