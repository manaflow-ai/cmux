import type { Domain, Principal, ReduceContext } from "@cmux/ownership"
import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { installAuthorityVersion, withInstallAuthority } from "../src/domains/user-authority.ts"
import type { UserState } from "../src/domains/user.ts"
import type { TeamState } from "../src/domains/team.ts"
import { hostNetworkTarget } from "../src/host-network-target.ts"
import { vmReceiverPeers } from "../src/cloud-vm-receiver-peers.ts"
import type { NetworkIdentityView } from "../src/user-do.ts"
import { post, sessionToken } from "./cloud-bind-support.ts"

/**
 * The UserDO and TeamDO reads cmux-platform's CloudDO calls for the Native backend. Each answer is
 * pinned to the caller's live grant; these are the refusals the platform relies on.
 */

const TEAM = "team_00000000000000000001", OTHER_TEAM = "team_00000000000000000002"
const MACHINE = "vm_" + "2".repeat(20), OTHER_MACHINE = "vm_" + "3".repeat(20)
type UserRpc = {
  networkIdentity(e: string, i: string, g: string, team: string): Promise<NetworkIdentityView | null>
  networkIdentities(e: string, entries: unknown, team: string): Promise<Array<NetworkIdentityView | null>>
  vmNetworkIdentity(e: string, i: string, g: string, team: string, machine: string): Promise<NetworkIdentityView | null>
  deviceKey(e: string, i: string, g: string, opClass?: string): Promise<JsonWebKey | null>
}
const inDO = runInDurableObject as unknown as (s: unknown, f: (i: any) => Promise<void> | void) => Promise<void>

/** A real user and mac install through the Worker; other install kinds are placed in memory on the same owner. */
const owner = async (sub: string) => {
  const session = await sessionToken(sub)
  const user = (await post("/v1/ops", session, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })).body.value.id as string
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const j = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const reg = await post("/v1/ops", session, { op: "install.register", params: { public_jwk: { kty: "EC", crv: "P-256", x: j.x, y: j.y }, kind: "mac", name: "cmux", device_name: "m", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "user" })
  expect(reg.body.ok, JSON.stringify(reg.body)).toBe(true)
  const install = reg.body.value.id as string, grant = reg.body.value.grant as string
  const ns = (env as unknown as { USER_DO: DurableObjectNamespace }).USER_DO
  const stub = ns.get(ns.idFromName(user))
  const edit = (f: (s: any) => void) => inDO(stub, (i) => f(i.boundEngine.currentState))
  /** Adds an install of `kind` with its own grant (in memory only), returning both ids. */
  const add = async (kind: string, classes: Array<string>, extra: Record<string, unknown> = {}) => {
    const id = `inst_${kind}${crypto.randomUUID().replace(/-/g, "").slice(0, 20 - kind.length)}`, g = `grant_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`
    await edit((s) => {
      s.installs[id] = { ...s.installs[install], id, kind, grant: g, revoked_at: null, ...extra }
      s.grants[g] = { id: g, grantee: id, op_classes: classes, approval: "none", expires_at: null, revoked_at: null, created_from: "install" }
    })
    return { install: id, grant: g }
  }
  return { user, install, grant, rpc: stub as unknown as UserRpc, edit, add }
}

describe("UserDO network identity RPCs", () => {
  it("answers a live client grant and refuses the wrong stream, grant, op class, expiry and revocation", { timeout: 60_000 }, async () => {
    const o = await owner("owner-rpcs-client")
    const live = await o.rpc.networkIdentity(o.user, o.install, o.grant, TEAM)
    expect(live).toMatchObject({ kind: "mac", authority_version: expect.stringMatching(/^[0-9a-f]{64}$/) })
    expect(await o.rpc.networkIdentity("user_99999999999999999999", o.install, o.grant, TEAM)).toBeNull()
    expect(await o.rpc.networkIdentity(o.user, o.install, `grant_${"9".repeat(20)}`, TEAM)).toBeNull()
    const readOnly = await o.add("cli", ["read"])
    expect(await o.rpc.networkIdentity(o.user, readOnly.install, readOnly.grant, TEAM)).toBeNull()
    expect(await o.rpc.deviceKey(o.user, readOnly.install, readOnly.grant)).toBeNull()
    expect(await o.rpc.deviceKey(o.user, readOnly.install, readOnly.grant, "read")).toMatchObject({ kty: "EC" })
    expect(await o.rpc.deviceKey(o.user, readOnly.install, readOnly.grant, "execute")).toBeNull()
    await o.edit((s) => { s.grants[o.grant] = { ...s.grants[o.grant], expires_at: Date.now() - 1 } })
    expect(await o.rpc.networkIdentity(o.user, o.install, o.grant, TEAM)).toBeNull()
    await o.edit((s) => { s.grants[o.grant] = { ...s.grants[o.grant], expires_at: null }; s.installs[o.install] = { ...s.installs[o.install], revoked_at: 1 } })
    expect(await o.rpc.networkIdentity(o.user, o.install, o.grant, TEAM)).toBeNull()
    await o.edit((s) => { s.installs[o.install] = { ...s.installs[o.install], revoked_at: null }; s.grants[o.grant] = { ...s.grants[o.grant], revoked_at: 1 } })
    expect(await o.rpc.networkIdentity(o.user, o.install, o.grant, TEAM)).toBeNull()
  })

  it("answers a daemon only for its own team and never a VM install", { timeout: 60_000 }, async () => {
    const o = await owner("owner-rpcs-daemon")
    const daemon = await o.add("daemon", ["read", "mutate-own"], { bound_team: TEAM })
    expect(await o.rpc.networkIdentity(o.user, daemon.install, daemon.grant, TEAM)).toMatchObject({ kind: "daemon" })
    expect(await o.rpc.networkIdentity(o.user, daemon.install, daemon.grant, OTHER_TEAM)).toBeNull()
    const vm = await o.add("vm", ["read", "mutate-own", "vm-self"], { bound_team: TEAM, bound_machine: MACHINE })
    expect(await o.rpc.networkIdentity(o.user, vm.install, vm.grant, TEAM)).toBeNull()
  })

  it("answers a VM install only for its bound team and machine under vm-self", { timeout: 60_000 }, async () => {
    const o = await owner("owner-rpcs-vm")
    const vm = await o.add("vm", ["vm-self"], { bound_team: TEAM, bound_machine: MACHINE })
    expect(await o.rpc.vmNetworkIdentity(o.user, vm.install, vm.grant, TEAM, MACHINE)).toMatchObject({ kind: "vm", op_classes: ["vm-self"] })
    expect(await o.rpc.vmNetworkIdentity(o.user, vm.install, vm.grant, OTHER_TEAM, MACHINE)).toBeNull()
    expect(await o.rpc.vmNetworkIdentity(o.user, vm.install, vm.grant, TEAM, OTHER_MACHINE)).toBeNull()
    expect(await o.rpc.vmNetworkIdentity("user_99999999999999999999", vm.install, vm.grant, TEAM, MACHINE)).toBeNull()
    expect(await o.rpc.vmNetworkIdentity(o.user, o.install, o.grant, TEAM, MACHINE)).toBeNull()
    const noSelf = await o.add("vm", ["read"], { bound_team: TEAM, bound_machine: MACHINE })
    expect(await o.rpc.vmNetworkIdentity(o.user, noSelf.install, noSelf.grant, TEAM, MACHINE)).toBeNull()
    await o.edit((s) => { s.grants[vm.grant] = { ...s.grants[vm.grant], expires_at: Date.now() - 1 } })
    expect(await o.rpc.vmNetworkIdentity(o.user, vm.install, vm.grant, TEAM, MACHINE)).toBeNull()
  })

  it("answers a bounded batch in order and nothing for a malformed one", { timeout: 60_000 }, async () => {
    const o = await owner("owner-rpcs-batch")
    const answers = await o.rpc.networkIdentities(o.user, [{ install: o.install, grant: o.grant }, { install: o.install, grant: `grant_${"9".repeat(20)}` }], TEAM)
    expect(answers).toHaveLength(2)
    expect(answers[0]).toMatchObject({ kind: "mac" })
    expect(answers[1]).toBeNull()
    expect(await o.rpc.networkIdentities(o.user, Array.from({ length: 129 }, () => ({ install: o.install, grant: o.grant })), TEAM)).toEqual([])
    expect(await o.rpc.networkIdentities(o.user, [{ install: o.install }], TEAM)).toEqual([])
  })
})

describe("install authority version", () => {
  const ctx = (tx: string) => ({ principal: { kind: "system", identity: "system:user" }, now: 1, tx, newId: (p: string) => `${p}_x` }) as unknown as ReduceContext
  const base = {
    user: { id: "user_00000000000000000001", stack_user_id: "s", email: null, display_name: "o", personal_team: TEAM },
    installs: { inst_a: { id: "inst_a", kind: "mac", grant: "grant_a", revoked_at: null, public_jwk: { kty: "EC", crv: "P-256", x: "x", y: "y" } } },
    grants: { grant_a: { id: "grant_a", grantee: "inst_a", op_classes: ["read", "mutate-own"], approval: "none", expires_at: null, revoked_at: null, created_from: "install" } }
  } as unknown as UserState
  // A stand-in user domain whose one op replaces the grant's classes.
  const domain = withInstallAuthority({
    initial: () => base, authorize: () => undefined,
    reduce: (state: UserState, _op: string, params: unknown) => ({ ok: true, state: { ...state, grants: { ...state.grants, grant_a: { ...state.grants.grant_a!, op_classes: params as Array<string> } } }, value: null })
  } as unknown as Domain<UserState>)
  const step = (state: UserState, classes: Array<string>, tx: string) => {
    const r = domain.reduce(state, "grant.set", classes, ctx(tx))
    if (!r.ok) throw new Error("refused")
    return r.state
  }

  it("changes on any admission change and never returns to an old value (A to B to A)", () => {
    const a = installAuthorityVersion(base, "inst_a")
    const b = step(base, ["read"], "B".repeat(22))
    const again = step(b, ["read", "mutate-own"], "C".repeat(22))
    expect(installAuthorityVersion(b, "inst_a")).not.toBe(a)
    expect(installAuthorityVersion(again, "inst_a")).not.toBe(a)
    expect(again.install_authority?.generation).toBe("2")
  })

  it("refuses a forged incarnation ahead of the generation", () => {
    const forged = { ...base, install_authority: { generation: "1", incarnations: { inst_a: `5:${"A".repeat(22)}` } } } as UserState
    expect(() => installAuthorityVersion(forged, "inst_a")).toThrow("invalid install authority incarnation")
  })
})

describe("TeamDO Native RPCs", () => {
  const p: Principal = { kind: "install", identity: "inst_00000000000000000001", user: "user_00000000000000000001", team: TEAM, install: "inst_00000000000000000001", grant: "grant_00000000000000000001", install_kind: "mac", grant_classes: ["read", "mutate-own", "execute"] }
  type TeamRpc = {
    authorizeCloudDial(e: string, p: Principal, target: unknown, proof: unknown, services: Array<string>): Promise<{ ok: boolean; code?: string }>
    recheckCloudDial(e: string, p: Principal, permit: unknown): Promise<boolean>
    vmReceiverPeers(e: string, target: unknown): Promise<unknown>
    hostNetworkTarget(e: string, p: Principal, params: unknown): Promise<{ ok: boolean; code?: string }>
  }

  it("answers nothing for a team this owner does not hold", async () => {
    const ns = (env as unknown as { TEAM_DO: DurableObjectNamespace }).TEAM_DO
    const team = ns.get(ns.idFromName("team_00000000000000000077")) as unknown as TeamRpc
    expect(await team.authorizeCloudDial("team_00000000000000000077", p, {}, {}, ["ssh"])).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await team.recheckCloudDial("team_00000000000000000077", p, {})).toBe(false)
    expect(await team.vmReceiverPeers("team_00000000000000000077", {})).toBeNull()
    expect(await team.hostNetworkTarget("team_00000000000000000077", p, {})).toMatchObject({ ok: false, code: "auth.forbidden" })
  })

  const state = { team: { id: TEAM, kind: "stack", display_name: "Team" }, members: { [p.user!]: { user: p.user!, role: "owner", display_name: "O" } }, hosts: {} } as unknown as TeamState

  it("refuses a host.network.target caller without a current read grant, or with a bad selector, before any read", async () => {
    let reads = 0
    const deps = { team: TEAM, project: "project", state: () => state, rows: undefined, now: Date.now, revision: () => "1",
      connection: () => { reads++; return { origin: "https://vm.example.test", key: "k" } },
      tenant: async () => { reads++; return { team: TEAM, project: "project", tenant: "t" } }, key: async () => { reads++; return null },
      http: async () => { reads++; return new Response(null, { status: 500 }) } }
    expect(await hostNetworkTarget(deps as never, { ...p, grant_classes: ["mutate-own"] }, {})).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await hostNetworkTarget(deps as never, { ...p, expires_at: Date.now() - 1 }, {})).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await hostNetworkTarget(deps as never, p, { mesh: "mesh_bad" })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await hostNetworkTarget(deps as never, p, { mesh: "mesh_" + "0".repeat(26), extra: 1 })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await hostNetworkTarget(deps as never, { ...p, install_kind: "daemon" }, {})).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await hostNetworkTarget(deps as never, { ...p, team: OTHER_TEAM }, {})).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(reads).toBe(0)
  })

  it("answers no receiver peers past or beyond the deadline window, or for a creator who is not a member", async () => {
    const policy = { schemaVersion: 1, tenantId: "t", vmId: "vm_" + "1".repeat(26), meshId: "mesh_" + "0".repeat(26), ipv4: null, aclVersion: 1, checkedAt: 1, expiresAt: 2, policyDigest: "a".repeat(64), peers: [] }
    const deps = { team: TEAM, project: "project", state: () => state, rows: undefined, now: Date.now, origin: () => "https://vm.example.test",
      tenant: async () => ({ team: TEAM, project: "project", tenant: "t" }), allowed: () => ["daemon", "ssh"],
      identity: async () => null, identities: async () => [] }
    const target = (over: Record<string, unknown>) => ({ creator: p.user!, origin: "https://vm.example.test", deadline: Date.now() + 5_000, policy, ...over }) as never
    expect(await vmReceiverPeers(deps, target({ deadline: Date.now() - 1 }))).toBeNull()
    expect(await vmReceiverPeers(deps, target({ deadline: Date.now() + 60_000 }))).toBeNull()
    expect(await vmReceiverPeers(deps, target({ creator: "user_00000000000000000009" }))).toBeNull()
    expect(await vmReceiverPeers(deps, target({ origin: "https://other.example.test" }))).toBeNull()
    expect(await vmReceiverPeers({ ...deps, tenant: async () => ({ team: OTHER_TEAM, project: "project", tenant: "t" }) }, target({}))).toBeNull()
    expect(await vmReceiverPeers(deps, target({}))).toMatchObject({ peers: [], authority_version: expect.stringMatching(/^[0-9a-f]{64}$/) })
  })
})
