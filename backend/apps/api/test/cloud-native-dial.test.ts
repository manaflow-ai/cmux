import type { Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { authorizeNativeDial, recheckNativeDial, type NativeDialDeps } from "../src/cloud-native-dial.ts"
import type { TeamState } from "../src/domains/team.ts"

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


/** A member_authority reader whose incarnation can move under an awaited read. */
const memberRows = () => {
  let incarnation = "generation:1:aaaaaaaaaaaaaaaaaaaaaa", generation = "1"
  return {
    rows: { get: (table: string, key: string) => table !== "member_authority" ? undefined : key === "@generation" ? { row: { generation } } : key === USER ? { row: { incarnation } } : undefined },
    // Leave and rejoin with the same role: only the incarnation tells the two memberships apart.
    rejoin: () => { generation = String(Number(generation) + 2); incarnation = `generation:${generation}:bbbbbbbbbbbbbbbbbbbbbb` }
  }
}

describe("Native dial authority incarnations", () => {
  it("refuses an install authority change during the Native read and after authorization", async () => {
    const f = await fixture(); f.onRead(f.renewAuthority)
    expect(await f.authorize()).toMatchObject({ ok: false, code: "auth.forbidden" })
    const second = await fixture(), permitted = await second.authorize()
    if (!permitted.ok) throw new Error(permitted.code)
    second.renewAuthority(); expect(await recheckNativeDial(second.deps, principal, permitted.permit)).toBe(false)
  })

  it("refuses a membership A to B to A during the Native read and after authorization", async () => {
    const f = await fixture(), m = memberRows()
    Object.assign(f.deps, { rows: m.rows }); f.onRead(m.rejoin)
    expect(await f.authorize()).toMatchObject({ ok: false, code: "auth.forbidden" })
    const second = await fixture(), n = memberRows()
    Object.assign(second.deps, { rows: n.rows })
    const permitted = await second.authorize()
    if (!permitted.ok) throw new Error(permitted.code)
    expect(await recheckNativeDial(second.deps, principal, permitted.permit)).toBe(true)
    n.rejoin(); expect(await recheckNativeDial(second.deps, principal, permitted.permit)).toBe(false)
  })

  it("refuses a caller whose socket authority is not the current one", async () => {
    const f = await fixture(); f.renewAuthority()
    expect(await f.authorize()).toMatchObject({ ok: false, code: "auth.forbidden" })
  })
})

describe("Native dial changes during the first await", () => {
  /** Runs `change` while the first tenant lookup is pending, before any identity or Native read answers. */
  const duringFirstTenant = (f: Awaited<ReturnType<typeof fixture>>, change: () => void) => {
    const tenant = f.deps.tenant
    let calls = 0
    Object.assign(f.deps, { tenant: async () => { if (calls++ === 0) change(); return tenant() } })
  }

  it("refuses a membership A to B to A during the first tenant lookup", async () => {
    const f = await fixture(), m = memberRows()
    Object.assign(f.deps, { rows: m.rows }); duringFirstTenant(f, m.rejoin)
    expect(await f.authorize()).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(f.reads()).toBe(0)
  })

  it("refuses a caller token that expires during the first tenant lookup, and at recheck", async () => {
    let now = Date.now()
    const f = await fixture(); Object.assign(f.deps, { now: () => now })
    const expiring = { ...principal, expires_at: now + 1_000 }
    duringFirstTenant(f, () => { now += 2_000 })
    expect(await authorizeNativeDial(f.deps, expiring, target, await f.proof(), ["ssh"])).toMatchObject({ ok: false, code: "auth.forbidden" })
    const second = await fixture(); let later = Date.now(); Object.assign(second.deps, { now: () => later })
    const permitted = await authorizeNativeDial(second.deps, { ...principal, expires_at: later + 1_000 }, target, await second.proof(), ["ssh"])
    if (!permitted.ok) throw new Error(permitted.code)
    later += 2_000
    expect(await recheckNativeDial(second.deps, { ...principal, expires_at: later - 1_000 }, permitted.permit)).toBe(false)
  })
})

describe("Native dial changes during the final tenant lookup", () => {
  it("refuses authorization and recheck when the install is revoked after its identity answered", async () => {
    const f = await fixture(), tenant = f.deps.tenant
    let calls = 0
    // Call 1 starts authorization; call 2 is the recheck's tenant lookup. The revoke lands late in it, after a concurrent identity read could have answered.
    Object.assign(f.deps, { tenant: async () => { if (++calls === 2) { await new Promise((r) => setTimeout(r, 5)); f.revoke() } return tenant() } })
    expect(await f.authorize(["ssh"])).toMatchObject({ ok: false, code: "auth.forbidden" })
    const second = await fixture(), permitted = await second.authorize(["ssh"])
    if (!permitted.ok) throw new Error(permitted.code)
    const again = second.deps.tenant
    Object.assign(second.deps, { tenant: async () => { await new Promise((r) => setTimeout(r, 5)); second.revoke(); return again() } })
    expect(await recheckNativeDial(second.deps, principal, permitted.permit)).toBe(false)
  })
})
