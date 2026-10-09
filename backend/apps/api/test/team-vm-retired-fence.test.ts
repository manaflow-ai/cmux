import { env } from "cloudflare:workers"
import type { Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { FakeDriver } from "../src/team-vm-driver.ts"
import { api, inDO, mutate, setup, sshLine } from "./team-ssh-support.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * cx-009a: Freestyle resumes a paused VM on inbound traffic (measured 2026-10-09 on the dev
 * account: public IPv6 with a rule, a VPC peer, a WireGuard tunnel peer and the SSH proxy each
 * took a paused VM to running in under 1 s, and the connection succeeded). A VM that a rebuild
 * retired after a member removal is paused, so without a fence anything the removed member left
 * that can send it a packet would run it again. The fake provider models that wake.
 */
const ns = (env as unknown as { TEAM_VM_DO: DurableObjectNamespace }).TEAM_VM_DO
const vmStub = (team: string) => ns.get(ns.idFromName(team)) as any

/** One inbound connection attempt to `vm`, as the provider handles it. */
const inbound = (team: string, vm: string) => inDO(vmStub(team), async (instance) => new FakeDriver(instance.sqlStore).inbound(vm))
const fakeState = (team: string, vm: string) =>
  inDO(vmStub(team), async (_i, st) => st.storage.sql.exec<{ state: string }>(`SELECT state FROM fake_vm WHERE id = ?`, vm).toArray()[0]?.state ?? null)

let n = 0
const rebuilt = async () => {
  const t = await setup(`stack-fence-${String(++n).padStart(4, "0")}${Date.now() % 1_000_000}`)
  const admin = (p: Principal, op: string, params: unknown) => (t.stub as any).vmAdminOp(t.team, p, { op, params, idempotency_key: crypto.randomUUID() })
  const status = async () => (await api(t.token, "/v1/read", { op: "team_vm.status", params: {} })).value
  const woke = await mutate(t.token, "team_vm.ensure_awake", { reason: "ssh" })
  expect(woke.ok, JSON.stringify(woke)).toBe(true)
  const first = woke.value as { vm: string; epoch: number }
  expect((await t.op(t.memberP, "team_vm.ssh_cert", { public_key: await sshLine("ed25519"), class: "agent" })).ok).toBe(true)
  const removed = await inDO(t.stub, async (instance) => instance.submitSystem("team.member.remove", { user: t.member }, `remove:${t.member}:${crypto.randomUUID()}`))
  expect(removed.frames.find((f: any) => f.t === "reject")).toBeUndefined()
  await fireAlarm(t.stub)
  await fireAlarm(t.stub)
  const r = await admin(t.ownerP, "team_vm.rebuild", { epoch: first.epoch })
  expect(r.ok, JSON.stringify(r)).toBe(true)
  return { ...t, first, status }
}

describe("a retired team VM stays paused on inbound traffic (cx-009a)", { timeout: 60_000 }, () => {
  it("inbound traffic to the paused retired VM does not run it again", async () => {
    const t = await rebuilt()
    expect((await t.status()).retired).toEqual([expect.objectContaining({ vm: t.first.vm, state: "paused" })])
    expect(await fakeState(t.team, t.first.vm)).toBe("paused")
    await inbound(t.team, t.first.vm)
    expect(await fakeState(t.team, t.first.vm)).toBe("paused")
    // Later alarms (the retired VM's pause path included) leave it paused too.
    await vmStub(t.team).fakeAlarm(10 * 60_000)
    await inbound(t.team, t.first.vm)
    expect(await fakeState(t.team, t.first.vm)).toBe("paused")
  })

  it("the fence is only on the retired VM: the team's new VM still wakes on traffic after an idle pause", async () => {
    const t = await rebuilt()
    const s = await t.status()
    expect(s.vm).not.toBe(t.first.vm)
    await vmStub(t.team).fakeControl({ pause_all: true })
    await inbound(t.team, s.vm)
    expect(await fakeState(t.team, s.vm)).toBe("running")
    expect(await fakeState(t.team, t.first.vm)).toBe("paused")
  })
})
