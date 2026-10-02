import { idFactory, type Principal, type ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { DEFAULT_POLICY, directoryOf, net } from "../src/domains/network.ts"
import { teamDomain, type TeamState } from "../src/domains/team.ts"

const OWNER = "user_aaaaaaaaaaaaaaaaaaaa"
const MEMBER = "user_bbbbbbbbbbbbbbbbbbbb"
const TEAM = "team_aaaaaaaaaaaaaaaaaaaa"
const INST = "inst_aaaaaaaaaaaaaaaaaaaa"
const INST2 = "inst_bbbbbbbbbbbbbbbbbbbb"
const KEY = `${"k".repeat(43)}=`

const owner: Principal = { identity: `session:${OWNER}`, kind: "session", user: OWNER, team: TEAM }
const member: Principal = { identity: `session:${MEMBER}`, kind: "session", user: MEMBER, team: TEAM }
const ownerInstall: Principal = { identity: INST, kind: "install", user: OWNER, team: TEAM, install: INST, grant_classes: ["read", "mutate-own", "mutate-shared", "execute"] }
const memberInstall: Principal = { identity: INST2, kind: "install", user: MEMBER, team: TEAM, install: INST2, grant_classes: ["read", "mutate-own", "mutate-shared", "execute"] }
const system: Principal = { identity: "system:team", kind: "system" }

let txn = 0
const ctx = (principal: Principal, now = 1_000): ReduceContext => {
  const tx = `tx${txn++}`
  return { principal, now, tx, newId: idFactory(tx) }
}

const apply = (s: TeamState, p: Principal, op: string, params: unknown) => {
  const denied = teamDomain.authorize!(s, op, params, p)
  if (denied) return { ok: false as const, code: denied.code, message: denied.message, state: s }
  const r = teamDomain.reduce(s, op, params, ctx(p))
  return r.ok ? { ...r, state: r.state } : { ...r, state: s }
}

const base = (): TeamState => ({
  team: { id: TEAM, kind: "stack", display_name: "acme" },
  members: {
    [OWNER]: { user: OWNER, role: "owner", display_name: "Owner" },
    [MEMBER]: { user: MEMBER, role: "member", display_name: "Member" }
  },
  hosts: {}
})

const policy = (extraAcl = "") => `{
  "tagOwners": { "tag:team-vm": ["autogroup:admin"], "tag:sandbox": ["autogroup:admin"] },
  "acls": [
    { "action": "accept", "src": ["autogroup:admin"], "dst": ["*:*"] },
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:team-vm:22"] }${extraAcl}
  ],
  "ssh": [{ "action": "accept", "src": ["autogroup:member"], "dst": ["tag:team-vm"], "users": ["autogroup:nonroot"] }],
  "tests": [{ "src": "user:${MEMBER}", "accept": ["tag:team-vm:22"], "deny": ["tag:sandbox:22"] }]
}`

describe("TeamDO network reducer", () => {
  it("wakes old state without a network section and reads the default policy", () => {
    expect(net(base()).versions).toEqual([])
    expect(directoryOf(base()).members).toHaveLength(2)
    expect(DEFAULT_POLICY).toContain("autogroup:admin")
  })

  it("applies a policy (owners only), enforces expected_version, and rolls back as a new version", () => {
    let s = base()
    expect(apply(s, member, "network.policy.apply", { document: policy(), expected_version: null })).toMatchObject({ ok: false, code: "auth.forbidden" })
    const a = apply(s, owner, "network.policy.apply", { document: policy(), expected_version: null })
    expect(a).toMatchObject({ ok: true, value: { version: 1, tests_passed: 1, rollback_of: null } })
    s = a.state
    expect(net(s).reconcile.desired_seq).toBe(1)
    expect(apply(s, owner, "network.policy.apply", { document: policy(), expected_version: null })).toMatchObject({ ok: false, code: "version.conflict" })
    // Same document again is a no-op.
    expect(apply(s, owner, "network.policy.apply", { document: policy(), expected_version: 1 })).toMatchObject({ ok: true, changed: false })
    const b = apply(s, owner, "network.policy.apply", { document: policy(`,\n { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:team-vm:443"] }`), expected_version: 1 })
    expect(b).toMatchObject({ ok: true, value: { version: 2 } })
    s = b.state
    const r = apply(s, owner, "network.policy.rollback", { version: 1 })
    expect(r).toMatchObject({ ok: true, value: { version: 3, rollback_of: 1 } })
    expect(net(r.state).versions.map((v) => v.version)).toEqual([1, 2, 3])
  })

  it("refuses policies that fail tests or lock the owner out, with JSON-path issues", () => {
    const failing = policy().replace(`"deny": ["tag:sandbox:22"]`, `"deny": ["tag:team-vm:22"]`)
    const r = apply(base(), owner, "network.policy.apply", { document: failing, expected_version: null })
    expect(r).toMatchObject({ ok: false, code: "policy.invalid" })
    const locked = `{"tagOwners":{"tag:team-vm":["autogroup:admin"]},"acls":[{"action":"accept","src":["autogroup:member"],"dst":["tag:team-vm:443"]}]}`
    const l = apply(base(), owner, "network.policy.apply", { document: locked, expected_version: null }) as { ok: false; details?: { issues: Array<{ message: string }> } }
    expect(l.ok).toBe(false)
    expect(l.details?.issues.map((i) => i.message)).toEqual(expect.arrayContaining(["lockout guard: admin user_aaaaaaaaaaaaaaaaaaaa would lose tcp/22 to tag:team-vm"]))
  })

  it("joins devices, refuses joins the policy gives no access, and lets only the user or an admin revoke", () => {
    let s = apply(base(), owner, "network.policy.apply", { document: policy(), expected_version: null }).state
    const j = apply(s, memberInstall, "network.device.join", { wg_public_key: KEY })
    expect(j).toMatchObject({ ok: true, value: { install: INST2, user: MEMBER, status: "pending", tunnel: null } })
    s = j.state
    // Same key again: no change.
    expect(apply(s, memberInstall, "network.device.join", { wg_public_key: KEY })).toMatchObject({ ok: true, changed: false })
    // Sessions cannot join (no install).
    expect(apply(s, member, "network.device.join", { wg_public_key: KEY })).toMatchObject({ ok: false, code: "auth.forbidden" })
    // A policy that gives members nothing refuses their join.
    const adminsOnly = `{"tagOwners":{"tag:team-vm":["autogroup:admin"]},"acls":[{"action":"accept","src":["autogroup:admin"],"dst":["*:*"]}],"ssh":[{"action":"accept","src":["autogroup:admin"],"dst":["tag:team-vm"],"users":["autogroup:nonroot"]}]}`
    const t = apply(s, owner, "network.policy.apply", { document: adminsOnly, expected_version: 1 }).state
    const other: Principal = { ...memberInstall, identity: "inst_cccccccccccccccccccc", install: "inst_cccccccccccccccccccc" }
    expect(apply(t, other, "network.device.join", { wg_public_key: KEY })).toMatchObject({ ok: false, code: "network.no_access" })
    // Revoke: not by another member's install, yes by the owner.
    const strangerSession: Principal = { identity: "session:x", kind: "session", user: "user_cccccccccccccccccccc", team: TEAM }
    expect(apply(s, strangerSession, "network.device.revoke", { install: INST2 })).toMatchObject({ ok: false, code: "auth.forbidden" })
    const rv = apply(s, owner, "network.device.revoke", { install: INST2 })
    expect(rv).toMatchObject({ ok: true, value: { status: "revoked" } })
    expect(net(rv.state).reconcile.desired_seq).toBeGreaterThan(net(s).reconcile.desired_seq)
  })

  it("checks tag ownership on machines", () => {
    let s = apply(base(), owner, "network.policy.apply", { document: policy(), expected_version: null }).state
    expect(apply(s, member, "network.machine.register", { machine: "mach_vm1", provider_id: "vm-1", owner_user: null, tags: ["team-vm"] })).toMatchObject({ ok: false, code: "auth.forbidden" })
    const m = apply(s, owner, "network.machine.register", { machine: "mach_vm1", provider_id: "vm-1", owner_user: null, tags: ["team-vm"] })
    expect(m).toMatchObject({ ok: true, value: { tags: ["team-vm"] } })
    s = m.state
    expect(apply(s, member, "network.machine.tag", { machine: "mach_vm1", tags: ["team-vm", "sandbox"] })).toMatchObject({ ok: false, code: "tag.forbidden" })
    expect(apply(s, owner, "network.machine.tag", { machine: "mach_vm1", tags: ["team-vm", "nope"] })).toMatchObject({ ok: false, code: "tag.forbidden" })
    expect(apply(s, owner, "network.machine.tag", { machine: "mach_vm1", tags: ["team-vm", "sandbox"] })).toMatchObject({ ok: true, value: { tags: ["sandbox", "team-vm"] } })
  })

  it("records reconcile results only from the system principal; a failed run stays pending", () => {
    let s = apply(base(), ownerInstall, "network.device.join", { wg_public_key: KEY }).state
    const rec = {
      desired_seq: 1,
      started_at: 2_000,
      ms: 500,
      converged: true,
      configured: true,
      actions: [{ op: "tunnel.create", ok: true, ms: 100 }],
      drift: [],
      deferred: 0,
      vpc_id: "vpc-1",
      tunnels: [{ install: INST, client_public_key: KEY, tunnel: { tunnel_id: "tun-1", client_config: "[Interface]\nPrivateKey = \n", endpoint: "e:51820", address_v4: "10.0.0.2", address_v6: null, server_public_key: "S", ready_at: 2_500 } }]
    }
    // Public principals cannot submit internal ops.
    expect(apply(s, owner, "network.reconcile.record", rec)).toMatchObject({ ok: false, code: "auth.forbidden" })
    const failed = apply(s, system, "network.reconcile.record", { ...rec, converged: false, actions: [{ op: "tunnel.create", ok: false, ms: 9, error: "503 x" }], tunnels: [] })
    expect(net(failed.state).reconcile).toMatchObject({ desired_seq: 1, applied_seq: 0, last: { failures: ["tunnel.create: 503 x"] } })
    const ok = apply(failed.state, system, "network.reconcile.record", rec)
    s = ok.state
    expect(net(s).reconcile).toMatchObject({ desired_seq: 1, applied_seq: 1, vpc_id: "vpc-1" })
    expect(net(s).devices[INST]).toMatchObject({ status: "ready", tunnel: { tunnel_id: "tun-1" } })
    // A report for an older key does not make a re-keyed device ready.
    const rekeyed = apply(s, ownerInstall, "network.device.join", { wg_public_key: `${"r".repeat(43)}=` }).state
    expect(net(rekeyed).devices[INST]).toMatchObject({ status: "pending" })
    const staleKey = apply(rekeyed, system, "network.reconcile.record", { ...rec, desired_seq: net(rekeyed).reconcile.desired_seq })
    expect(net(staleKey.state).devices[INST]).toMatchObject({ status: "pending", tunnel: null })
    // A revoked install never becomes ready again from a stale report.
    s = apply(s, system, "network.install.revoked", { install: INST }).state
    s = apply(s, system, "network.reconcile.record", { ...rec, desired_seq: 2 }).state
    expect(net(s).devices[INST]).toMatchObject({ status: "revoked", tunnel: null })
  })
})
