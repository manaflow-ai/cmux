import { env } from "cloudflare:workers"
import type { Principal, ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { teamVmDomain } from "../src/domains/team-vm.ts"
import { ensureSshTables } from "../src/team-ssh-ca.ts"
import { certTaintGate } from "../src/team-ssh-taint.ts"
import { pauseWakeAt } from "../src/domains/team-vm-taint.ts"
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

  it("a member who never had a certificate taints nothing, and the holder record survives a removal", async () => {
    const t = await fresh()
    await t.wake()
    await t.remove(t.member)
    expect((await t.status()).taint ?? null).toBeNull()
    const t2 = await fresh()
    await t2.wake()
    expect((await t2.op(t2.memberP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })).ok).toBe(true)
    await t2.remove(t2.member)
    // Kept for a re-join: a later removal of the same person still knows they once held root.
    const held = await inDO(t2.stub, async (_i, st) => st.storage.sql.exec(`SELECT 1 FROM ssh_cert_holders WHERE user = ?`, t2.member).toArray().length)
    expect(held).toBe(1)
  })

  it("an admin acts like an owner; members and agents cannot rebuild or delete", async () => {
    const t = await fresh()
    const first = await t.wake()
    const admin = "user_00000000000000077004"
    await inDO(t.stub, async (instance) => {
      const engine = instance.boundEngine
      engine.state = { ...engine.currentState, members: { ...engine.currentState.members, [admin]: { user: admin, role: "admin", display_name: "Admin" } } }
    })
    expect((await t.op(t.memberP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })).ok).toBe(true)
    await t.remove(t.member)
    const adminP: Principal = { identity: `session:${admin}`, kind: "session", user: admin, team: t.team }
    const member2 = "user_00000000000000077005"
    await inDO(t.stub, async (instance) => {
      const engine = instance.boundEngine
      engine.state = { ...engine.currentState, members: { ...engine.currentState.members, [member2]: { user: member2, role: "member", display_name: "M2" } } }
    })
    const m2: Principal = { identity: `session:${member2}`, kind: "session", user: member2, team: t.team }
    expect((await t.admin(m2, "team_vm.rebuild", { epoch: first.epoch })).error?.code).toBe("auth.forbidden")
    expect((await t.admin({ ...adminP, agent: "agent_00000000000000000002" }, "team_vm.rebuild", { epoch: first.epoch })).error?.code).toBe("auth.forbidden")
    // The admin's own certificate is issued and audited; the admin's agent gets none.
    expect((await t.op({ ...adminP, agent: "agent_00000000000000000002" }, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })).error?.code).toBe("team_vm.tainted")
    expect((await t.op(adminP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })).ok).toBe(true)
    expect((await t.admin(adminP, "team_vm.taint.accept", { epoch: first.epoch, users: [t.member] })).ok).toBe(true)
    expect((await t.status()).taint).toMatchObject({ accepted_by: admin })
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
    const users = [t.member]
    expect((await t.admin(staysP, "team_vm.taint.accept", { epoch, users })).error?.code).toBe("auth.forbidden")
    expect((await t.admin({ ...t.ownerP, agent: "agent_00000000000000000001" }, "team_vm.taint.accept", { epoch, users })).error?.code).toBe("auth.forbidden")
    expect((await t.admin(t.install(t.owner, ["read", "mutate-own", "mutate-shared", "execute", "destructive"]), "team_vm.taint.accept", { epoch, users })).error?.code).toBe("auth.forbidden")
    expect((await t.admin(t.ownerP, "team_vm.taint.accept", { epoch: epoch + 1, users })).error?.code).toBe("team_vm.not_tainted")
    // The owner accepts exactly the removals the status showed.
    expect((await t.admin(t.ownerP, "team_vm.taint.accept", { epoch, users: [] })).error?.code).toBe("team_vm.stale_taint")
    // The public route reaches the same path.
    const r = await mutate(t.token, "team_vm.taint.accept", { epoch, users })
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
    // The old epoch's install lost its grant.
    const revoked = await inDO(vmStub(t.team), async (_i, st) => st.storage.sql.exec<{ revoked: number }>(`SELECT revoked FROM team_vm_bind_install WHERE epoch = ?`, first.epoch).toArray()[0]?.revoked ?? null)
    expect(revoked).toBe(1)
    // Only an owner or admin deletes it, by its exact id.
    const stays: Principal = { identity: `session:user_00000000000000077009`, kind: "session", user: "user_00000000000000077009", team: t.team }
    expect((await t.admin(stays, "team_vm.retired.delete", { vm: first.vm })).error?.code).toBe("auth.forbidden")
    const del = await t.admin(t.ownerP, "team_vm.retired.delete", { vm: first.vm, files_copied: true })
    expect(del.ok, JSON.stringify(del)).toBe(true)
    expect((await t.status()).retired).toEqual([])
    const gone = await inDO(vmStub(t.team), async (_i, st) => st.storage.sql.exec(`SELECT 1 FROM fake_vm WHERE id = ?`, first.vm).toArray().length)
    expect(gone).toBe(0)
    expect((await t.admin(t.ownerP, "team_vm.retired.delete", { vm: s.vm, files_copied: true })).error?.code).toBe("selector.not_found")
  })

  it("retired.delete without the owner's files_copied confirmation answers team_vm.retired_files_unconfirmed and keeps the VM (cx-zr9i)", async () => {
    const t = await fresh()
    const first = await t.wake()
    expect((await t.op(t.memberP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })).ok).toBe(true)
    await t.remove(t.member)
    expect((await t.admin(t.ownerP, "team_vm.rebuild", { epoch: first.epoch })).ok).toBe(true)
    await fireAlarm(vmStub(t.team))
    // /srv/team stays only on the paused old VM until journal replay exists: deleting it needs the owner's word that it was copied off.
    for (const params of [{ vm: first.vm }, { vm: first.vm, files_copied: false }, { vm: first.vm, files_copied: "yes" }]) {
      const r = await t.admin(t.ownerP, "team_vm.retired.delete", params)
      expect(r.ok, JSON.stringify(r)).toBe(false)
      expect(r.error?.code).toBe("team_vm.retired_files_unconfirmed")
    }
    expect((await t.status()).retired).toEqual([expect.objectContaining({ vm: first.vm, state: "paused" })])
    const kept = await inDO(vmStub(t.team), async (_i, st) => st.storage.sql.exec<{ state: string }>(`SELECT state FROM fake_vm WHERE id = ?`, first.vm).toArray()[0])
    expect(kept?.state).toBe("paused")
    expect((await t.auditSummaries()).some((a) => a.op === "team_vm.taint_audit" && a.detail?.action === "retired_deleted")).toBe(false)
    // A member still gets auth.forbidden first (the confirmation never leaks the role check).
    expect((await t.admin(t.memberP, "team_vm.retired.delete", { vm: first.vm })).error?.code).toBe("auth.forbidden")
    expect((await t.admin(t.ownerP, "team_vm.retired.delete", { vm: first.vm, files_copied: true })).ok).toBe(true)
  })

  it("a failed pause keeps members out until the provider confirms it, and retries with backoff", async () => {
    const t = await fresh()
    const first = await t.wake()
    const stays = "user_00000000000000077006"
    await inDO(t.stub, async (instance) => {
      const engine = instance.boundEngine
      engine.state = { ...engine.currentState, members: { ...engine.currentState.members, [stays]: { user: stays, role: "member", display_name: "Stays" } } }
    })
    const staysP: Principal = { identity: `session:${stays}`, kind: "session", user: stays, team: t.team }
    expect((await t.op(t.memberP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })).ok).toBe(true)
    await t.remove(t.member)
    // The provider refuses every pause until the test lets it through.
    await vmStub(t.team).fakeControl({ fail_pause: 1000 })
    expect((await t.admin(t.ownerP, "team_vm.rebuild", { epoch: first.epoch })).ok).toBe(true)
    const s = await t.status()
    expect(s.retired).toEqual([expect.objectContaining({ vm: first.vm, state: "pausing" })])
    expect((await t.op(staysP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })).error?.code).toBe("team_vm.tainted")
    await vmStub(t.team).fakeControl({ fail_pause: 0 })
    await vmStub(t.team).fakeAlarm(10 * 60_000)
    expect((await t.status()).retired).toEqual([expect.objectContaining({ vm: first.vm, state: "paused" })])
    expect((await t.op(staysP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })).ok).toBe(true)
  })
})

describe("team_vm.accounts is fenced to the current epoch's install (cx-n3fb)", { timeout: 60_000 }, () => {
  const vmInstall = (team: string) => inDO(vmStub(team), async (instance) => (instance.boundEngine?.currentState?.vm_install ?? null) as string | null)
  const boundInstall = async (team: string, epoch: number, vm: string): Promise<string> => {
    await fireAlarm(vmStub(team))
    const bound = await vmInstall(team)
    if (bound) return bound
    const install = "inst_00000000000000077101"
    await inDO(vmStub(team), async (instance) => instance.submitSystem("team_vm.bind_install", { install, epoch, vm }, `bind_install:${epoch}:${install}`))
    expect(await vmInstall(team)).toBe(install)
    return install
  }

  it("answers the current epoch's install, and refuses another install, an old epoch's install and a team without a VM", async () => {
    const t = await fresh()
    const vmP = (id: string): Principal => t.install(t.owner, ["read", "mutate-own"], "team-vm", id)
    const accounts = (p: Principal) => (t.stub as any).readOp(t.team, p, "team_vm.accounts", {})
    // No team VM record yet: no install is current.
    expect(await accounts(vmP("inst_00000000000000077102"))).toMatchObject({ ok: false, code: "team_vm.stale_epoch" })
    const first = await t.wake()
    const current = await boundInstall(t.team, first.epoch, first.vm)
    expect(await accounts(vmP(current))).toMatchObject({ ok: true })
    expect(await accounts(vmP("inst_00000000000000077103"))).toMatchObject({ ok: false, code: "team_vm.stale_epoch" })
    // Owners and admins in a session are not an install: unchanged.
    expect(await accounts(t.ownerP)).toMatchObject({ ok: true })
    // A rebuild moves the epoch: the old install is no longer current.
    expect((await t.op(t.memberP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })).ok).toBe(true)
    await t.remove(t.member)
    expect((await t.admin(t.ownerP, "team_vm.rebuild", { epoch: first.epoch })).ok).toBe(true)
    await fireAlarm(vmStub(t.team))
    expect((await t.status()).epoch).toBe(first.epoch + 1)
    expect(await accounts(vmP(current))).toMatchObject({ ok: false, code: "team_vm.stale_epoch" })
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

  it("a removal after an acceptance needs a new one, also for the same member re-joined and removed again", () => {
    const accepted = { ...running, taint: { epoch: 1, at: 2_000, users: ["user_a"], accepted_by: "user_o", accepted_at: 3_000 } }
    const replay = teamVmDomain.reduce(accepted, "team_vm.member_removed", { user: "user_a", at: 2_000, cert_valid_before: 9_000 }, ctx(fromTeam("team_t"), 4_000))
    expect((replay as any).state.taint.accepted_by).toBe("user_o")
    const again = teamVmDomain.reduce(accepted, "team_vm.member_removed", { user: "user_a", at: 5_000, cert_valid_before: 9_000 }, ctx(fromTeam("team_t"), 5_000))
    expect((again as any).state.taint).toMatchObject({ users: ["user_a"], accepted_by: null })
  })

  it("the owner-action ops refuse every identity but TeamVmDO's own", () => {
    const tainted = { ...running, taint: { epoch: 1, at: 2_000, users: ["user_a"], accepted_by: null, accepted_at: null } }
    for (const who of [fromTeam("team_t"), { identity: "system:team", kind: "system" } as Principal, { identity: "user:x", kind: "session", user: "x", team: "team_t" } as Principal]) {
      expect(teamVmDomain.reduce(tainted, "team_vm.taint_accepted", { epoch: 1, users: ["user_a"], by: "x" }, ctx(who, 3_000))).toMatchObject({ ok: false, code: "auth.forbidden" })
      expect(teamVmDomain.reduce(tainted, "team_vm.rebuild_requested", { epoch: 1, by: "x" }, ctx(who, 3_000))).toMatchObject({ ok: false, code: "auth.forbidden" })
    }
  })

  it("a failed pause backs off, and the alarm follows it", () => {
    const retired = { ...running, vm: null, retired: [{ vm: "vm-a", slug: "s", epoch: 1, state: "pausing" as const, at: 1_000, by: "o", tainted_by: [], pause_attempts: 0, pause_retry_at: 1_000 }] }
    const r1 = teamVmDomain.reduce(retired, "team_vm.retired_pause_failed", { vm: "vm-a" }, ctx(sys, 2_000)) as any
    expect(pauseWakeAt(r1.state)).toBe(2_000 + 2_000)
    const r2 = teamVmDomain.reduce(r1.state, "team_vm.retired_pause_failed", { vm: "vm-a" }, ctx(sys, 4_000)) as any
    expect(pauseWakeAt(r2.state)).toBe(4_000 + 4_000)
  })

  it("an unreachable team VM record fails closed for members and open for admins", async () => {
    const down = async () => {
      throw new Error("down")
    }
    expect(await certTaintGate(down, false)).toMatchObject({ refuse: true, unreachable: true })
    expect(await certTaintGate(down, true)).toMatchObject({ refuse: false })
  })

  it("a tainted epoch's install cannot bind until the taint is accepted", () => {
    const tainted = { ...running, taint: { epoch: 1, at: 2_000, users: ["user_a"], accepted_by: null, accepted_at: null } }
    expect(teamVmDomain.reduce(tainted, "team_vm.bind_install", { install: "inst_00000000000000000001", epoch: 1, vm: "vm-a" }, ctx(sys, 3_000))).toMatchObject({ ok: false, code: "team_vm.tainted" })
    const accepted = { ...tainted, taint: { ...tainted.taint, accepted_by: "user_o", accepted_at: 2_500 } }
    expect(teamVmDomain.reduce(accepted, "team_vm.bind_install", { install: "inst_00000000000000000001", epoch: 1, vm: "vm-a" }, ctx(sys, 3_000))).toMatchObject({ ok: true })
  })
})
