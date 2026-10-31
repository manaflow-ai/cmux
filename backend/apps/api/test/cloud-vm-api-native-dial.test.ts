import { decodeJwt } from "jose"
import type { Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { authorizeNativeDial, recheckNativeDial, type NativeDialDeps } from "../src/cloud-native-dial.ts"
import type { TeamState } from "../src/domains/team.ts"
import { mintLinkToken, type NativeLinkAuthority, type Rows } from "../src/cloud-connect.ts"
import type { MachineRow } from "../src/domains/cloud.ts"
import { parseSigningKeys } from "../src/link-token.ts"
import vectors from "../../../../schemas/link-token/vectors.json"

const TEAM = "team_00000000000000000001", USER = "user_00000000000000000001", INSTALL = "inst_00000000000000000001"
const GRANT = "grant_00000000000000000001", HOST = "host_00000000000000000001"
const MESH = "mesh_" + "0".repeat(26), DEVICE = "dev_" + "0".repeat(26), VM = "vm_" + "1".repeat(26)
const ORIGIN = "https://vm.example.test", TENANT = "team_native"
const wg = btoa(String.fromCharCode(...new Uint8Array(32).fill(9)))
const principal: Principal = { kind: "install", identity: INSTALL, team: TEAM, user: USER, install: INSTALL, grant: GRANT, install_kind: "mac", grant_classes: ["read", "mutate-own", "execute"], install_authority: "1".padStart(64, "0") }
const target = { vm: VM, origin: ORIGIN, network: { tenant: TENANT, mesh: MESH, ipv4_cidr: "10.128.0.0/20", ipv4: "10.128.0.5" } }

/** Only the Native boundary is replaced; the fixture verifies real one-use P-256 proofs. */
const fixture = async () => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])
  if (!("privateKey" in pair)) throw new Error("missing key pair")
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey)
  const raw = await crypto.subtle.exportKey("raw", pair.publicKey)
  if (jwk instanceof ArrayBuffer || !(raw instanceof ArrayBuffer)) throw new Error("unexpected public key encoding")
  const point = btoa(String.fromCharCode(...new Uint8Array(raw)))
  let state: TeamState = { team: { id: TEAM, kind: "stack", display_name: "Team", stack_team: TENANT }, members: { [USER]: { user: USER, role: "owner", display_name: "Owner" } }, hosts: {
    [HOST]: { id: HOST, name: "Mac", platform: "macos", owner_user: USER, enrolled_by: INSTALL, enrolled_at: Date.now(), wg_public_key: wg,
      network: { state: "confirmed", tenant: TENANT, mesh: MESH, device: DEVICE, confirmed_at: Date.now(), install_grant: GRANT } }
  } }
  let currentKey: JsonWebKey | null = jwk
  let incarnation = 1, grantExpiresAt: number | null = null
  let currentClasses: ReadonlyArray<string> = principal.grant_classes ?? []
  let services: ReadonlyArray<string> = ["daemon", "ssh"]
  let policy: Record<string, unknown> = { tenantId: TENANT, meshId: MESH, deviceId: DEVICE, wgPublicKey: wg, installPublicKey: point, aclVersion: 1, policyDigest: "a".repeat(64), peers: [],
    vms: [{ kind: "vm", id: VM, address: target.network.ipv4, allow: [{ protocol: "tcp", port: 22 }, { protocol: "tcp", port: 4100 }] }] }
  let onRead: (() => void) | undefined
  let reads = 0
  const used = new Set<string>()
  const deps: NativeDialDeps = Object.assign({
    team: TEAM, project: "project", origin: ORIGIN, state: () => state, rows: undefined,
    tenant: async () => ({ team: TEAM, project: "project", tenant: TENANT }), key: async () => currentKey, allowed: () => services, now: Date.now,
    http: async (request: Request) => {
      expect(request.url).toBe(`${ORIGIN}/v1/devices/${DEVICE}/signed/overlay-policy`)
      expect(request.method).toBe("POST"); expect(request.redirect).toBe("manual")
      expect(request.headers.has("authorization")).toBe(false); expect(request.headers.has("cookie")).toBe(false)
      const proof = await request.json() as { signedAt: number; nonce: string; signature: string }
      const message = ["cmux-mesh-v1", "overlay-policy", DEVICE, "", point, "", String(proof.signedAt), proof.nonce].join("\n")
      const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, Uint8Array.from(atob(proof.signature), (c) => c.charCodeAt(0)), new TextEncoder().encode(message))
      if (!valid) return Response.json({}, { status: 403 })
      if (used.has(proof.nonce)) return Response.json({}, { status: 409 })
      used.add(proof.nonce); reads++; onRead?.()
      return Response.json(policy)
    }
  }, { identity: async () => currentKey ? { key: currentKey, kind: "mac", expires_at: grantExpiresAt, op_classes: currentClasses, authority_version: String(incarnation).padStart(64, "0") } : null })
  const proof = async () => {
    const signedAt = Date.now(), nonce = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
    const message = ["cmux-mesh-v1", "overlay-policy", DEVICE, "", point, "", String(signedAt), nonce].join("\n")
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(message))
    return { signedAt, nonce, signature: btoa(String.fromCharCode(...new Uint8Array(signature))) }
  }
  return { deps, proof, reads: () => reads, authorize: async (requested = ["daemon", "ssh"]) => authorizeNativeDial(deps, principal, target, await proof(), requested),
    policy: () => policy, setPolicy: (value: Record<string, unknown>) => { policy = value },
    dropDialClass: () => { currentClasses = ["read", "mutate-own"] },
    renewAuthority: () => { incarnation++ }, limitGrant: (expires: number) => { grantExpiresAt = expires },
    revoke: () => { currentKey = null }, leave: () => { state = { ...state, members: {} } },
    legacy: () => { const host = state.hosts![HOST]!; if (host.network?.state !== "confirmed") throw new Error("missing binding"); const { install_grant: _old, ...network } = host.network; state = { ...state, hosts: { [HOST]: { ...host, network } } } },
    retarget: () => { const host = state.hosts![HOST]!; state = { ...state, hosts: { [HOST]: { ...host, wg_public_key: btoa("0".repeat(32)) } } } },
    denyServices: () => { services = [] }, onRead: (callback: () => void) => { onRead = callback } }
}

describe("current Native Cloud dial permission", () => {
  it("joins the live backend identity, both keys, team mesh and directed VM ports using one fresh proof", async () => {
    const f = await fixture(), proof = await f.proof()
    const result = await authorizeNativeDial(f.deps, principal, target, proof, ["daemon", "ssh"])
    expect(result).toMatchObject({ ok: true, permit: { team: TEAM, user: USER, install: INSTALL, grant: GRANT, wg, mesh: MESH, device: DEVICE, aclVersion: 1 } })
    if (!result.ok) throw new Error(result.code)
    expect(await recheckNativeDial(f.deps, principal, result.permit)).toBe(true)
    expect(f.reads()).toBe(1)
    expect(await authorizeNativeDial(f.deps, principal, target, proof, ["ssh"])).toMatchObject({ ok: false, code: "validation.invalid" })
  })

  it.each([undefined, [], [{ kind: "vm", id: VM, address: target.network.ipv4, allow: [{ protocol: "udp", port: 4101 }] }]])("never treats missing service policy or outer transport as access %#", async (vms) => {
    const f = await fixture(); f.setPolicy({ ...f.policy(), vms })
    expect(await f.authorize()).toMatchObject({ ok: false, code: "auth.forbidden" })
  })

  it("requires SSH permission as well as the daemon port and rejects ambiguous VM entries", async () => {
    const f = await fixture(), entry = { kind: "vm", id: VM, address: target.network.ipv4, allow: [{ protocol: "tcp", port: 4100 }] }
    f.setPolicy({ ...f.policy(), vms: [entry] }); expect(await f.authorize(["daemon"])).toMatchObject({ ok: false })
    f.setPolicy({ ...f.policy(), vms: [{ ...entry, allow: [{ protocol: "tcp", port: 22 }] }] })
    expect(await f.authorize(["ssh"])).toMatchObject({ ok: true })
    expect(await f.authorize(["daemon"])).toMatchObject({ ok: false })
    f.setPolicy({ ...f.policy(), vms: [entry, entry] }); expect(await f.authorize(["ssh"])).toMatchObject({ ok: false })
  })

  it("refuses a historical binding without its current grant before sending a proof", async () => {
    const f = await fixture(); f.legacy()
    expect(await f.authorize()).toMatchObject({ ok: false, code: "auth.forbidden" }); expect(f.reads()).toBe(0)
  })

  it.each(["revoke", "leave", "retarget", "denyServices"] as const)("fences %s during the Native read and after authorization", async (action) => {
    const f = await fixture(); f.onRead(f[action])
    expect(await f.authorize()).toMatchObject({ ok: false, code: "auth.forbidden" })
    const second = await fixture(), permitted = await second.authorize()
    if (!permitted.ok) throw new Error(permitted.code)
    second[action](); expect(await recheckNativeDial(second.deps, principal, permitted.permit)).toBe(false)
  })

  it.each(["tenantId", "meshId", "deviceId", "wgPublicKey", "installPublicKey"])("refuses a changed Native %s", async (field) => {
    const f = await fixture(); f.setPolicy({ ...f.policy(), [field]: "different" })
    expect(await f.authorize()).toMatchObject({ ok: false, code: "auth.forbidden" })
  })
})

const mintFixture = async () => {
  const f = await fixture()
  let machine: MachineRow = { id: "vm_" + "2".repeat(20), team: TEAM, creator: USER, name: null, size: {}, status: "running", image: { id: "fixture", daemon_version: null }, host: HOST, classic: false,
    created_at: Date.now(), last_active_at: null, idle_policy: { idle_seconds: 0 }, error: null, revision: "1", provider_name: "owned-native-name", host_id: HOST, transport: "vm-api", network: target.network, wg_public_key: wg, epoch: 1 }
  const rows: Rows = {
    get: <T>() => ({ key: machine.id, n: 1, row: machine as unknown as T }),
    range: <T>() => [{ key: machine.id, n: 1, row: machine as unknown as T }]
  }
  const audit: Array<Record<string, unknown>> = []
  let denyFinalPolicy = false, policyReads = 0
  const authority: NativeLinkAuthority = {
    receiver: async () => ({ machine: machine.id, generation: "a".repeat(64), scope: "b".repeat(64), expires_at: null,
      identity: { user: USER, install: "inst_" + "3".repeat(20), grant: "grant_" + "3".repeat(20) } }),
    recheckReceiver: async () => true,
    authorize: (_row, p, proof, services) => authorizeNativeDial(f.deps, p, target, proof, services),
    recheck: (p, permit) => recheckNativeDial(f.deps, p, permit)
  }
  const keys = parseSigningKeys(JSON.stringify({ active: "test-k1", keys: vectors.test_keys, published_at: { "test-k1": 1, "test-k2": 1 } }))
  if (!keys) throw new Error("fixture signing keys were rejected")
  const mint = async (proof?: unknown) => mintLinkToken({ entity: TEAM, rows, p: principal, params: { host: HOST, services: ["ssh"], ...(proof ? { native_proof: proof } : {}) }, request: crypto.randomUUID(), environment: "test", keys, native: authority },
    async () => ++policyReads > 1 && denyFinalPolicy ? [] : ["daemon", "ssh"], () => ({ record: (entry) => { audit.push(entry) } }))
  return { ...f, mint, audit, authority, denyAtFinalPolicy: () => { denyFinalPolicy = true }, pause: () => { machine = { ...machine, status: "paused" } } }
}

describe("Native policy in the actual link-token minter", () => {
  it("requires a fresh proof for every mint and audits no proof or token", async () => {
    const f = await mintFixture()
    expect(await f.mint()).toMatchObject({ ok: false, code: "auth.forbidden" })
    const proof = await f.proof(), first = await f.mint(proof)
    expect(first).toMatchObject({ ok: true, value: { host: HOST, epoch: 1, services: ["ssh"] } })
    expect(await f.mint(proof)).toMatchObject({ ok: false, code: "validation.invalid" })
    const second = await f.mint(await f.proof())
    expect(second.ok).toBe(true); expect(second).not.toEqual(first)
    expect(f.audit).toHaveLength(2)
    expect(JSON.stringify(f.audit)).not.toContain(proof.signature)
    for (const entry of f.audit) expect(entry).not.toHaveProperty("token")
  })

  it("drops the signed token when the current grant is revoked at the final check", async () => {
    const f = await mintFixture(), check = f.authority.recheck
    f.authority.recheck = async (p, permit) => { f.revoke(); return check(p, permit) }
    expect(await f.mint(await f.proof())).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(f.audit).toHaveLength(0)
  })

  it("refuses a machine generation that changes during the Native read", async () => {
    const f = await mintFixture(); f.onRead(f.pause)
    expect(await f.mint(await f.proof())).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(f.audit).toHaveLength(0)
  })
})


it("refuses a new authority incarnation with the same key and grant during the signed policy read", async () => {
  const f = await fixture()
  f.onRead(f.renewAuthority)
  expect(await f.authorize()).toMatchObject({ ok: false, code: "auth.forbidden" })
})

it("invalidates an earlier permit when unchanged admission values have a new incarnation", async () => {
  const f = await fixture(), read = await f.authorize()
  expect(read.ok).toBe(true)
  if (!read.ok) throw new Error(read.code)
  f.renewAuthority()
  expect(await recheckNativeDial(f.deps, principal, read.permit)).toBe(false)
})

it("signs the checked Native identity and its opaque incarnation into the actual Cloud token", async () => {
  const f = await mintFixture(), answer = await f.mint(await f.proof())
  expect(answer.ok).toBe(true)
  if (!answer.ok) throw new Error(answer.code)
  const claims = decodeJwt((answer.value as { token: string }).token)
  expect(claims.network).toMatchObject({ version: 1, tenant: TENANT, mesh: MESH, device: DEVICE, host: HOST, user: USER, wg_public_key: wg, acl_version: 1, authority_version: expect.stringMatching(/^[0-9a-f]{64}$/) })
  expect(JSON.stringify(claims)).not.toContain(GRANT)
})

it("never mints a Native credential beyond its original grant expiry", async () => {
  const f = await mintFixture(), expires = Date.now() + 10_000
  f.limitGrant(expires)
  const answer = await f.mint(await f.proof())
  expect(answer.ok).toBe(true)
  if (!answer.ok) throw new Error(answer.code)
  const claims = decodeJwt((answer.value as { token: string }).token)
  expect(Number(claims.exp) * 1000).toBeLessThanOrEqual(expires)
})


it("drops a signed credential when the service policy is removed before final admission", async () => {
  const f = await mintFixture()
  f.denyAtFinalPolicy()
  expect(await f.mint(await f.proof())).toMatchObject({ ok: false, code: "auth.forbidden" })
  expect(f.audit).toHaveLength(0)
})


it("does not substitute the key for the current grant's dial class", async () => {
  const f = await fixture()
  f.dropDialClass()
  expect(await f.authorize()).toMatchObject({ ok: false, code: "auth.forbidden" })
  expect(f.reads()).toBe(0)
})

it("refuses a request whose authenticated install incarnation changed before the Native lookup", async () => {
  const f = await fixture()
  f.renewAuthority()
  expect(await f.authorize()).toMatchObject({ ok: false, code: "auth.forbidden" })
  expect(f.reads()).toBe(0)
})
