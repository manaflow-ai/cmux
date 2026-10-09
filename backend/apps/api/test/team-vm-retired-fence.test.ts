import { env } from "cloudflare:workers"
import type { Principal } from "@cmux/ownership"
import { afterEach, describe, expect, it, vi } from "vitest"
import { DriverError, FakeDriver, FreestyleDriver } from "../src/team-vm-driver.ts"
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

  it("a retired VM paused before the fence existed gets fenced on the next alarm and then stays paused", async () => {
    const t = await rebuilt()
    // Stand for a row a pre-fence TeamVmDO paused: paused, no fence flag, and no budget spent at the provider.
    await inDO(vmStub(t.team), async (instance) => {
      const engine = instance.boundEngine
      const retired = engine.currentState.retired.map(({ fenced: _f, ...r }: any) => ({ ...r, state: "paused" }))
      engine.state = { ...engine.currentState, retired }
      instance.sqlStore.exec(`DELETE FROM fake_fence WHERE id = ?`, t.first.vm)
    })
    await vmStub(t.team).fakeAlarm(10 * 60_000)
    expect((await t.status()).retired).toEqual([expect.objectContaining({ vm: t.first.vm, state: "paused" })])
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

describe("FreestyleDriver.retireVm (cx-009a)", () => {
  afterEach(() => vi.unstubAllGlobals())
  /** Answers each call from `answers` in order and records method, path and body. */
  const provider = (answers: Array<[number, unknown]>) => {
    const calls: Array<{ method: string; path: string; body: unknown }> = []
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
      calls.push({ method: init.method ?? "GET", path: new URL(url).pathname, body: init.body ? JSON.parse(String(init.body)) : undefined })
      const [status, body] = answers.shift() ?? [500, {}]
      return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })
    })
    return { calls, driver: new FreestyleDriver("test-key", "https://provider.test", "snap") }
  }

  it("spends the run budget before the pause, so no inbound packet can resume the VM between the two calls", async () => {
    const p = provider([[200, { state: "running", maxRunTotalSeconds: 1 }], [200, { state: "paused" }]])
    await p.driver.retireVm("vm-1")
    expect(p.calls).toEqual([
      { method: "PATCH", path: "/v5/vms/vm-1", body: { maxRunTotalSeconds: 1 } },
      { method: "POST", path: "/v5/vms/vm-1/pause", body: undefined }
    ])
  })

  it("a VM the budget already paused counts as retired (the provider refuses a second pause with 409)", async () => {
    const p = provider([[200, {}], [409, { code: "CONFLICT" }], [200, { id: "vm-1", state: "paused" }]])
    await p.driver.retireVm("vm-1")
    expect(p.calls.map((c) => c.method)).toEqual(["PATCH", "POST", "GET"])
  })

  it("a VM that is gone answers vm_missing; a refused budget is an error and nothing is paused", async () => {
    const gone = provider([[404, { code: "NOT_FOUND" }]])
    await expect(gone.driver.retireVm("vm-1")).rejects.toMatchObject({ code: "team_vm.vm_missing" })
    vi.unstubAllGlobals()
    const refused = provider([[500, { code: "INTERNAL" }]])
    const err = await refused.driver.retireVm("vm-1").catch((e) => e)
    expect(err).toBeInstanceOf(DriverError)
    expect(refused.calls.map((c) => c.method)).toEqual(["PATCH"])
  })
})
