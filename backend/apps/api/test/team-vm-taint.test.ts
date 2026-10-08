import { env } from "cloudflare:workers"
import type { Principal, ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { teamVmDomain } from "../src/domains/team-vm.ts"
import { ensureSshTables } from "../src/team-ssh-ca.ts"
import { api, inDO, mutate, setup, sshLine } from "./team-ssh-support.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * cx-q4f3: team members are root on the team VM (sudo, docker), so a removed member may have left
 * something running that no revocation ends. Removing a member who held a team SSH certificate
 * that was valid while the current VM existed taints that VM: only owners and admins get new
 * certificates (each audited with the taint), the VM's install cannot bind again, and an owner
 * either accepts the risk or rebuilds (a new VM at the next epoch; the old one is paused and kept
 * until the owner deletes it).
 */
const ns = (env as unknown as { TEAM_VM_DO: DurableObjectNamespace }).TEAM_VM_DO
const vmStub = (team: string) => ns.get(ns.idFromName(team)) as any

let n = 0
const fresh = async () => {
  const t = await setup(`stack-taint-${String(++n).padStart(4, "0")}${Date.now() % 1_000_000}`)
  const admin = (p: Principal, op: string, params: unknown, key: string = crypto.randomUUID()) => (t.stub as any).vmAdminOp(t.team, p, { op, params, idempotency_key: key })
  const status = async () => (await api(t.token, "/v1/read", { op: "team_vm.status", params: {} })).value
  const wake = async () => {
    const r = await mutate(t.token, "team_vm.ensure_awake", { reason: "ssh" })
    expect(r.ok, JSON.stringify(r)).toBe(true)
    return r.value as { vm: string; epoch: number }
  }
  const remove = async (user: string) => {
    const r = await inDO(t.stub, async (instance) => instance.submitSystem("team.member.remove", { user }, `remove:${user}:${crypto.randomUUID()}`))
    expect(r.frames.find((f: any) => f.t === "reject")).toBeUndefined()
    // The cleanup runs after the op; its outbox (TeamVmDO) drains with the alarm.
    await fireAlarm(t.stub)
    await fireAlarm(t.stub)
  }
  const auditSummaries = () =>
    inDO(t.stub, async (_i, st) =>
      st.storage.sql
        .exec<{ payload: string }>(`SELECT payload FROM own_outbox WHERE kind = 'audit.append' ORDER BY id`)
        .toArray()
        .map((r) => JSON.parse(r.payload) as { op: string; summary: string; detail: any })
    )
  return { ...t, admin, status, wake, remove, auditSummaries }
}

describe("team VM taint after a member removal (cx-q4f3)", { timeout: 60_000 }, () => {
  it("removing a member who held a certificate while the VM existed taints the VM; status shows who and when", async () => {
    const t = await fresh()
    const first = await t.wake()
    const cert = await t.op(t.memberP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })
    expect(cert.ok, JSON.stringify(cert)).toBe(true)
    expect((await t.status()).taint ?? null).toBeNull()
    await t.remove(t.member)
    const s = await t.status()
    expect(s.taint).toMatchObject({ epoch: first.epoch, users: [t.member], accepted_by: null })
    expect(s.taint.at).toBeGreaterThan(0)
  })

  it("a member whose last certificate expired before the VM was created, or who never had one, taints nothing", async () => {
    const t = await fresh()
    // A certificate that ended an hour before the VM existed (the record outlives the 24 h issued-log retention).
    await inDO(t.stub, async (_i, st) => {
      ensureSshTables(st.storage.sql)
      const now = Date.now()
      st.storage.sql.exec(`INSERT INTO ssh_certs (serial, identity, user, install, key_id, class, generation, issued_at, valid_before) VALUES (77001, 'id-x', ?, NULL, 'k', 'agent', 1, ?, ?)`, t.member, now - 7_200_000, now - 3_600_000)
    })
    await t.wake()
    await t.remove(t.member)
    expect((await t.status()).taint ?? null).toBeNull()
  })

  it("while tainted, members get no certificate (team_vm.tainted); owners still do, and each such certificate is audited with the taint", async () => {
    const t = await fresh()
    await t.wake()
    // A second member who stays.
    const stays = "user_00000000000000077002"
    await inDO(t.stub, async (instance) => {
      const engine = instance.boundEngine
      engine.state = { ...engine.currentState, members: { ...engine.currentState.members, [stays]: { user: stays, role: "member", display_name: "Stays" } } }
    })
    expect((await t.op(t.memberP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })).ok).toBe(true)
    await t.remove(t.member)
    const staysP: Principal = { identity: `session:${stays}`, kind: "session", user: stays, team: t.team }
    const refused = await t.op(staysP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })
    expect(refused.error?.code).toBe("team_vm.tainted")
    const owner = await t.op(t.ownerP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })
    expect(owner.ok, JSON.stringify(owner)).toBe(true)
    const audit = await t.auditSummaries()
    const row = audit.find((a) => a.op === "team_vm.taint_audit" && a.detail?.action === "cert_issued_while_tainted")
    expect(row, JSON.stringify(audit.map((a) => a.op))).toBeDefined()
    expect(row!.detail).toMatchObject({ by: t.owner, serial: owner.value.serial, tainted_by: [t.member] })
  })

  it("accept: owners and admins only, for the tainted epoch; afterwards members get certificates again", async () => {
    const t = await fresh()
    const { epoch } = await t.wake()
    const stays = "user_00000000000000077003"
    await inDO(t.stub, async (instance) => {
      const engine = instance.boundEngine
      engine.state = { ...engine.currentState, members: { ...engine.currentState.members, [stays]: { user: stays, role: "member", display_name: "Stays" } } }
    })
    expect((await t.op(t.memberP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })).ok).toBe(true)
    await t.remove(t.member)
    const staysP: Principal = { identity: `session:${stays}`, kind: "session", user: stays, team: t.team }
    expect((await t.admin(staysP, "team_vm.taint.accept", { epoch })).error?.code).toBe("auth.forbidden")
    expect((await t.admin(t.install(t.owner, ["read", "mutate-own", "mutate-shared", "execute", "destructive"]), "team_vm.taint.accept", { epoch })).error?.code).toBe("auth.forbidden")
    expect((await t.admin(t.ownerP, "team_vm.taint.accept", { epoch: epoch + 1 })).error?.code).toBe("team_vm.not_tainted")
    // The public route reaches the same path.
    const r = await mutate(t.token, "team_vm.taint.accept", { epoch })
    expect(r.ok, JSON.stringify(r)).toBe(true)
    expect((await t.status()).taint).toMatchObject({ epoch, users: [t.member], accepted_by: t.owner })
    expect((await t.op(staysP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })).ok).toBe(true)
    expect((await t.auditSummaries()).some((a) => a.op === "team_vm.taint_audit" && a.detail?.action === "taint_accepted")).toBe(true)
  })

  it("rebuild: owners only; a new VM at the next epoch, the old one paused and kept until the owner deletes it", async () => {
    const t = await fresh()
    const first = await t.wake()
    expect((await t.op(t.memberP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })).ok).toBe(true)
    await t.remove(t.member)
    const r = await t.admin(t.ownerP, "team_vm.rebuild", { epoch: first.epoch })
    expect(r.ok, JSON.stringify(r)).toBe(true)
    await fireAlarm(vmStub(t.team))
    const s = await t.status()
    expect(s.epoch).toBe(first.epoch + 1)
    expect(s.vm).not.toBe(first.vm)
    expect(s.taint ?? null).toBeNull()
    expect(s.retired).toEqual([expect.objectContaining({ vm: first.vm, epoch: first.epoch, state: "paused", by: t.owner, tainted_by: [t.member] })])
    // The old VM still exists at the provider, paused (its data can be copied off).
    const old = await inDO(vmStub(t.team), async (_i, st) => st.storage.sql.exec<{ state: string }>(`SELECT state FROM fake_vm WHERE id = ?`, first.vm).toArray()[0])
    expect(old?.state).toBe("paused")
    // Only the owner deletes it, by its exact id.
    const del = await t.admin(t.ownerP, "team_vm.retired.delete", { vm: first.vm })
    expect(del.ok, JSON.stringify(del)).toBe(true)
    expect((await t.status()).retired).toEqual([])
    const gone = await inDO(vmStub(t.team), async (_i, st) => st.storage.sql.exec(`SELECT 1 FROM fake_vm WHERE id = ?`, first.vm).toArray().length)
    expect(gone).toBe(0)
    expect((await t.admin(t.ownerP, "team_vm.retired.delete", { vm: s.vm })).error?.code).toBe("selector.not_found")
  })
})

describe("team VM taint (TeamVmDO reducer)", () => {
  const sys: Principal = { identity: "system:team_vm", kind: "system" }
  const fromTeam = (team: string): Principal => ({ identity: `system:team:${team}`, kind: "system" })
  const ctx = (p: Principal, now: number): ReduceContext => ({ principal: p, now, tx: `tx${now}`, newId: (x) => `${x}_${now}` })
  const running = { ...teamVmDomain.initial(), team: "team_t", vm: "vm-a", slug: "s", epoch: 1, status: "running" as const, vm_created_at: 1_000 }

  it("taints only for a certificate valid after the VM was created, and only from the team's own TeamDO", () => {
    const before = teamVmDomain.reduce(running, "team_vm.member_removed", { user: "user_a", at: 5_000, cert_valid_before: 900 }, ctx(fromTeam("team_t"), 5_000))
    expect(before).toMatchObject({ ok: true })
    expect((before as any).state.taint ?? null).toBeNull()
    const after = teamVmDomain.reduce(running, "team_vm.member_removed", { user: "user_a", at: 5_000, cert_valid_before: 1_500 }, ctx(fromTeam("team_t"), 5_000))
    expect((after as any).state.taint).toMatchObject({ epoch: 1, users: ["user_a"] })
    const forged = teamVmDomain.reduce(running, "team_vm.member_removed", { user: "user_a", at: 5_000, cert_valid_before: 1_500 }, ctx(fromTeam("team_other"), 5_000))
    expect((forged as any).state?.taint ?? null).toBeNull()
  })

  it("a tainted epoch's install cannot bind until the taint is accepted", () => {
    const tainted = { ...running, taint: { epoch: 1, at: 2_000, users: ["user_a"], accepted_by: null, accepted_at: null } }
    expect(teamVmDomain.reduce(tainted, "team_vm.bind_install", { install: "inst_00000000000000000001", epoch: 1, vm: "vm-a" }, ctx(sys, 3_000))).toMatchObject({ ok: false, code: "team_vm.tainted" })
    const accepted = { ...tainted, taint: { ...tainted.taint, accepted_by: "user_o", accepted_at: 2_500 } }
    expect(teamVmDomain.reduce(accepted, "team_vm.bind_install", { install: "inst_00000000000000000001", epoch: 1, vm: "vm-a" }, ctx(sys, 3_000))).toMatchObject({ ok: true })
  })
})
