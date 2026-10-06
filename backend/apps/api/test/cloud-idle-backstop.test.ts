import { describe, expect, it } from "vitest"
import { createBody } from "../src/cloud-driver.ts"
import { bindFile, cloudStub, DAEMON, post, SIZE, signedInWithInstall, vmKey, WG_KEY } from "./cloud-bind-support.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Coordinator decision (2026-10-05): Freestyle never changes a machine's state by itself (every
 * Freestyle timer -1, automaticRestart true), so our record stays true; our own 24 h backstop idle
 * pause, ON for every team, bounds the cost of a forgotten machine (reports only, money-op path);
 * idle_policy.set changes only our policy.
 */

const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const op = (token: string, name: string, params: unknown, key?: string) => post("/v1/ops", token, { op: name, params, ...(key ? { idempotency_key: key } : {}), origin: key ? "user" : "cli" })
const H = 3600_000

const vmSetup = async (sub: string) => {
  const a = await signedInWithInstall(sub, "mac")
  const machine = (await op(a.session, "cloud.machine.create", { size: SIZE }, crypto.randomUUID())).body.value.machine.id as string
  const stub = cloudStub(a.team)
  const { json } = await bindFile(stub, machine)
  const key = await vmKey()
  const bound = await post("/v1/cloud/bind", undefined, { team: a.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk })
  const install = bound.body.value.install as { id: string; user: string }
  const ch = await post("/v1/auth/challenge", undefined, { user: install.user, install: install.id })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key.pair.privateKey, new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`))
  const vmToken = (await post("/v1/auth/token", undefined, { user: install.user, install: install.id, nonce: ch.body.nonce, signature: b64u(sig) })).body.access_token as string
  // A daemon that can see sessions advertises the activity capability (coordinator, 2026-10-05).
  const report = (activity: Record<string, unknown>, capabilities: Array<string> = [...DAEMON.capabilities, "activity"]) => op(vmToken, "cloud.vm.status.report", { machine, state: "running", daemon: { ...DAEMON, capabilities }, activity })
  const status = async () => (await post("/v1/read", a.session, { op: "cloud.machine.get", params: { machine } })).body.value.status as string
  return { a, machine, stub, report, status }
}

describe("Freestyle timers off, our 24 h backstop on", { timeout: 60_000 }, () => {
  it("the create request turns every Freestyle timer off and keeps automatic restart", () => {
    const body = createBody("cmuxnp-test-cld-vm-00000000000000000001", "snap", { team: "team_00000000000000000001", machine: "vm_00000000000000000001" }, { idleSeconds: 1800 })
    expect(body).toMatchObject({ idleTimeoutSeconds: -1, autoDeleteSeconds: -1, ttlSeconds: -1, maxRunSeconds: -1, maxRunTotalSeconds: -1, automaticRestart: true })
  })

  it("with cloud.idlePause off, a machine idle 24 h by its own reports pauses; 23 h does not", async () => {
    const s = await vmSetup("cloud-bind-5")
    await s.stub.fakeControl({ advance_ms: 25 * H } as never)
    await s.report({ active_sessions: 0, last_user_input_at: Date.now() + 25 * H - 23 * H })
    expect(await s.status()).toBe("running")
    await s.stub.fakeControl({ advance_ms: 11_000 } as never)
    await s.report({ active_sessions: 0, last_user_input_at: Date.now() - 1 * H })
    expect(["pausing", "paused"]).toContain(await s.status())
  })

  it("idle_policy.set changes only our policy: no provider call, the VM's Freestyle timer stays off", async () => {
    const s = await vmSetup("cloud-bind-6")
    const before = (await s.stub.fakeControl({})) as unknown as { creates: number; pauses: number; vms: Array<{ name: string; idle: number | null }> }
    expect((await op(s.a.session, "cloud.machine.idle_policy.set", { machine: s.machine, idle_seconds: 600 }, crypto.randomUUID())).body.ok).toBe(true)
    const after = (await s.stub.fakeControl({})) as unknown as { creates: number; pauses: number; vms: Array<{ name: string; idle: number | null }> }
    expect([after.creates, after.pauses]).toEqual([before.creates, before.pauses])
    expect(after.vms.find((v) => v.name.endsWith(s.machine.replace(/_/g, "-")))?.idle).toBe(-1)
  })

  it("cost backstop: a running machine with no applied report for 24 h after its bind is paused with pause_reason no_report", async () => {
    const s = await vmSetup("cloud-bind-1")
    await s.stub.fakeControl({ advance_ms: 23 * H } as never)
    await fireAlarm(s.stub)
    expect(await s.status()).toBe("running")
    await s.stub.fakeControl({ advance_ms: 2 * H } as never)
    await fireAlarm(s.stub)
    const got = (await post("/v1/read", s.a.session, { op: "cloud.machine.get", params: { machine: s.machine } })).body.value
    expect(got).toMatchObject({ status: "paused", pause_reason: "no_report" })
    // A start clears the reason (the person decided).
    expect((await op(s.a.session, "cloud.machine.start", { machine: s.machine }, crypto.randomUUID())).body.ok).toBe(true)
    const after = (await post("/v1/read", s.a.session, { op: "cloud.machine.get", params: { machine: s.machine } })).body.value
    expect(after).toMatchObject({ status: "running", pause_reason: null })
  })

  it("a report keeps the cost backstop away", async () => {
    const s = await vmSetup("cloud-bind-2")
    await s.stub.fakeControl({ advance_ms: 23 * H } as never)
    const rep = await s.report({ active_sessions: 1, last_user_input_at: Date.now() + 23 * H })
    expect(rep.body, JSON.stringify(rep.body)).toMatchObject({ ok: true, value: { applied: true } })
    const dbg = (await post("/v1/read", s.a.session, { op: "cloud.machine.get", params: { machine: s.machine } })).body.value
    expect(dbg, JSON.stringify(dbg)).toMatchObject({ status: "running" })
    await s.stub.fakeControl({ advance_ms: 2 * H } as never)
    await fireAlarm(s.stub)
    expect(await s.status()).toBe("running")
  })

  it("connect_info and link_token check the VM's real state: a VM powered off inside is recorded paused and link_token refuses", async () => {
    const s = await vmSetup("cloud-bind-3")
    const vm = ((await s.stub.fakeControl({})) as unknown as { vms: Array<{ name: string }> }).vms.find((v) => v.name.endsWith(s.machine.replace(/_/g, "-")))!
    await s.stub.fakeControl({ vm_state: { name: vm.name, state: "stopped" } } as never)
    const ci = await post("/v1/read", s.a.installToken, { op: "cloud.machine.connect_info", params: { machine: s.machine } })
    expect(ci.body.value.state, JSON.stringify(ci.body)).toBe("paused")
    const host = ci.body.value.host as string
    const lt = await post("/v1/ops", s.a.installToken, { op: "cloud.machine.link_token", params: { host, services: ["ssh"] }, origin: "cli" })
    expect(lt.body.error?.code).toBe("cloud.machine.paused")
    const got = (await post("/v1/read", s.a.session, { op: "cloud.machine.get", params: { machine: s.machine } })).body.value
    expect(got).toMatchObject({ status: "paused", pause_reason: "provider_stopped" })
  })

  it("a machine that never binds is paused by the cost backstop 24 h after create (review P2)", async () => {
    const a = await signedInWithInstall("cloud-bind-4", "mac")
    const machine = (await op(a.session, "cloud.machine.create", { size: SIZE }, crypto.randomUUID())).body.value.machine.id as string
    const stub = cloudStub(a.team)
    await stub.fakeControl({ advance_ms: 25 * H } as never)
    await fireAlarm(stub)
    const got = (await post("/v1/read", a.session, { op: "cloud.machine.get", params: { machine } })).body.value
    expect(got).toMatchObject({ status: "paused", pause_reason: "no_report" })
    // It can never bind now (its bind token expired): a start is refused with not_bound, so it cannot run for nothing (review P3).
    const st = await op(a.session, "cloud.machine.start", { machine }, crypto.randomUUID())
    expect(st.body.error?.code, JSON.stringify(st.body)).toBe("cloud.machine.not_bound")
  })

  it("the real-state check changes nothing on an unknown or missing state field, and reads the provider at most once per 30 s (review P2)", async () => {
    const s = await vmSetup("cloud-bind-5")
    const vm = ((await s.stub.fakeControl({})) as unknown as { vms: Array<{ name: string }> }).vms.find((v) => v.name.endsWith(s.machine.replace(/_/g, "-")))!
    const reads = async () => ((await s.stub.fakeControl({})) as unknown as { state_reads: number }).state_reads
    const ci = () => post("/v1/read", s.a.installToken, { op: "cloud.machine.connect_info", params: { machine: s.machine } })
    const r0 = await reads()
    for (let i = 0; i < 3; i++) await ci()
    expect((await reads()) - r0).toBe(1)
    await s.stub.fakeControl({ vm_state: { name: vm.name, state: "restarting" }, advance_ms: 31_000 } as never)
    expect((await ci()).body.value.state).toBe("running")
    await s.stub.fakeControl({ vm_state: { name: vm.name, state: "<none>" }, advance_ms: 31_000 } as never)
    expect((await ci()).body.value.state).toBe("running")
    expect(await s.status()).toBe("running")
  })

  it("a cost-backstop pause the provider keeps refusing backs off exponentially (60 s, 2 min, 4 min ... capped at 1 h)", async () => {
    const s = await vmSetup("cloud-bind-6")
    await s.stub.fakeControl({ power_refuse: 100 } as never)
    const calls = async () => ((await s.stub.fakeControl({})) as unknown as { power_calls: number }).power_calls
    await s.stub.fakeControl({ advance_ms: 25 * H } as never)
    await fireAlarm(s.stub)
    const first = await calls()
    expect(first).toBeGreaterThan(0)
    expect(await s.status()).toBe("running")
    // 61 s later: still inside the 2 min backoff, no new attempt.
    await s.stub.fakeControl({ advance_ms: 61_000 } as never)
    await fireAlarm(s.stub)
    expect(await calls()).toBe(first)
    await s.stub.fakeControl({ advance_ms: 70_000 } as never)
    await fireAlarm(s.stub)
    expect(await calls()).toBeGreaterThan(first)
  })

  it("a report without the activity capability never counts as idle and does not reset the no_report clock (coordinator, 2026-10-05)", async () => {
    const s = await vmSetup("cloud-bind-3")
    const plain = [...DAEMON.capabilities]
    // With cloud.idlePause on (30 min policy), a capable daemon's idle report would pause the machine now.
    expect((await op(s.a.session, "team.policy.update", { changes: [{ key: "cloud.idlePause", value: { value: true, mode: "enforced" } }], expected_version: 0, reason: "test" }, crypto.randomUUID())).body.ok).toBe(true)
    // 23 h after the bind: idle by its times, but the daemon cannot see sessions: no pause.
    await s.stub.fakeControl({ advance_ms: 23 * H } as never)
    await s.report({ active_sessions: 0, last_user_input_at: Date.now() + 23 * H - 20 * H }, plain)
    expect(await s.status()).toBe("running")
    // Its reports do not keep the machine alive either: 24 h after the bind the no_report backstop pauses it.
    await s.stub.fakeControl({ advance_ms: 2 * H } as never)
    await s.report({ active_sessions: 0 }, plain)
    const { fireAlarm } = await import("./setup/alarm.ts")
    await fireAlarm(s.stub)
    const got = (await post("/v1/read", s.a.session, { op: "cloud.machine.get", params: { machine: s.machine } })).body.value
    expect(got).toMatchObject({ status: "paused", pause_reason: "no_report" })
  })

  it("a held report from a replaced install does not reset the no_report clock (review P3)", async () => {
    const s = await vmSetup("cloud-bind-4")
    const { runInDurableObject } = await import("cloudflare:test")
    // A capable report from another install is held for the machine (the queue keys by machine), then the alarm takes it.
    await s.stub.fakeControl({ advance_ms: 23 * H } as never)
    await (runInDurableObject as unknown as (x: unknown, f: (i: any) => Promise<void>) => Promise<void>)(s.stub, async (i: any) => {
      const now = Date.now() + i.skewMs
      i.vmStatus.offer(s.machine, { machine: s.machine, state: "running", daemon: { version: "x", capabilities: ["activity"] }, activity: { active_sessions: 1 }, install: "inst_00000000000000000099" }, now - 20_000)
      i.vmStatus.offer(s.machine, { machine: s.machine, state: "running", daemon: { version: "x", capabilities: ["activity"] }, activity: { active_sessions: 1 }, install: "inst_00000000000000000099" }, now - 5_000)
    })
    await s.stub.fakeControl({ advance_ms: 30_000 } as never)
    const { fireAlarm } = await import("./setup/alarm.ts")
    await fireAlarm(s.stub)
    await s.stub.fakeControl({ advance_ms: 2 * H } as never)
    await fireAlarm(s.stub)
    const got = (await post("/v1/read", s.a.session, { op: "cloud.machine.get", params: { machine: s.machine } })).body.value
    expect(got).toMatchObject({ status: "paused", pause_reason: "no_report" })
  })
})
