import { describe, expect, it } from "vitest"
import { bindFile, cloudStub, DAEMON, post, SIZE, signedInWithInstall, vmKey, WG_KEY } from "./cloud-bind-support.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Idle pause (state-placement.md 7 item 4; coordinator 2026-10-05): OFF by default (team policy
 * cloud.idlePause, default false) until Lawrence decides on auto-start. Idle counts only from the VM's
 * own activity reports (cloud.vm.status.report): no sessions and the last input or agent action older
 * than the machine's idle policy. A VM that stops reporting is unknown, never idle. The pause goes
 * through the money-op path (ledger, prefix guard, per-team limit).
 */

const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const op = (token: string, name: string, params: unknown, key?: string) => post("/v1/ops", token, { op: name, params, ...(key ? { idempotency_key: key } : {}), origin: key ? "user" : "cli" })

const vmSetup = async (sub: string) => {
  const a = await signedInWithInstall(sub, "mac")
  const created = await op(a.session, "cloud.machine.create", { size: SIZE }, crypto.randomUUID())
  const machine = created.body.value.machine.id as string
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
  const policy = async (on: boolean, version: number) => op(a.session, "team.policy.update", { changes: [{ key: "cloud.idlePause", value: { value: on, mode: "enforced" } }], expected_version: version, reason: "idle pause test" }, crypto.randomUUID())
  return { a, machine, stub, report, status, policy }
}
const hoursAgo = (h: number) => Date.now() - h * 3600_000

describe("idle pause", { timeout: 60_000 }, () => {
  it("is off by default: an idle report pauses nothing", async () => {
    const s = await vmSetup("cloud-bind-1")
    expect((await s.report({ active_sessions: 0, last_user_input_at: hoursAgo(5) })).body.ok).toBe(true)
    expect(await s.status()).toBe("running")
  })

  it("with cloud.idlePause on, a report of no sessions and no activity past the idle policy pauses the machine through the money-op path", async () => {
    const s = await vmSetup("cloud-bind-2")
    expect((await s.policy(true, 0)).body.ok).toBe(true)
    // Idle counts from the bind at the earliest: move past the 30 min idle policy.
    await s.stub.fakeControl({ advance_ms: 31 * 60_000 } as never)
    expect((await s.report({ active_sessions: 0, last_user_input_at: hoursAgo(5), last_agent_action_at: hoursAgo(4) })).body.ok).toBe(true)
    expect(["pausing", "paused"]).toContain(await s.status())
    expect(((await s.stub.fakeControl({})) as unknown as { pauses: number }).pauses).toBe(1)
  })

  it("never pauses on recent activity, open sessions, a report without activity times, or a VM that stopped reporting", async () => {
    const s = await vmSetup("cloud-bind-3")
    expect((await s.policy(true, 0)).body.ok).toBe(true)
    await s.report({ active_sessions: 0, last_user_input_at: Date.now() - 60_000 })
    expect(await s.status()).toBe("running")
    await s.stub.fakeControl({ advance_ms: 11_000 } as never)
    await s.report({ active_sessions: 2, last_user_input_at: hoursAgo(5) })
    expect(await s.status()).toBe("running")
    await s.stub.fakeControl({ advance_ms: 11_000 } as never)
    await s.report({ active_sessions: 0 })
    expect(await s.status()).toBe("running")
    // No report for hours: unknown, not idle.
    await s.stub.fakeControl({ advance_ms: 5 * 3600_000 } as never)
    await fireAlarm(s.stub)
    expect(await s.status()).toBe("running")
  })

  // hq-ff image lead, auto7 (2026-10-06): a machine nobody typed into, whose VM keeps reporting, never paused.
  describe("a reporting machine with no activity times: the idle period starts at its last start or bind", () => {
    // The DO clock moves with fakeControl; the test keeps the same offset to write the VM's times.
    const clocked = async (sub: string) => {
      const s = await vmSetup(sub)
      expect((await s.policy(true, 0)).body.ok).toBe(true)
      expect((await op(s.a.session, "cloud.machine.idle_policy.set", { machine: s.machine, idle_seconds: 60 }, crypto.randomUUID())).body.ok).toBe(true)
      let skew = 0
      const advance = async (ms: number) => {
        skew += ms
        await s.stub.fakeControl({ advance_ms: ms } as never)
      }
      return { ...s, advance, vmNow: () => Date.now() + skew }
    }

    it("create, bind, no input: reports every 20 s with no times; running at 40 s, paused after about 60 s", async () => {
      const s = await clocked("cloud-bind-5")
      for (let t = 20; t <= 40; t += 20) {
        await s.advance(20_000)
        expect((await s.report({ active_sessions: 0 })).body.ok).toBe(true)
        expect(await s.status(), `at ${t} s`).toBe("running")
      }
      await s.advance(21_000)
      await s.report({ active_sessions: 0 })
      expect(["pausing", "paused"]).toContain(await s.status())
      const got = (await post("/v1/read", s.a.session, { op: "cloud.machine.get", params: { machine: s.machine } })).body.value
      expect(got.pause_reason).toBe("idle")
    })

    it("an open session still keeps a machine with no activity times running", async () => {
      const s = await clocked("cloud-bind-6")
      await s.advance(120_000)
      await s.report({ active_sessions: 1 })
      expect(await s.status()).toBe("running")
    })

    it("agent input alone does not keep a machine awake: the person's input time stays, reports continue, it pauses about 60 s after that input", async () => {
      const s = await clocked("cloud-bind-1")
      await s.advance(5_000)
      const personAt = s.vmNow()
      await s.report({ active_sessions: 0, last_user_input_at: personAt })
      // The agent's v2 writes every 20 s do not move last_user_input_at (cmux-tui activity.rs).
      for (let t = 20; t <= 40; t += 20) {
        await s.advance(20_000)
        await s.report({ active_sessions: 0, last_user_input_at: personAt })
        expect(await s.status(), `at ${t} s`).toBe("running")
      }
      await s.advance(21_000)
      await s.report({ active_sessions: 0, last_user_input_at: personAt })
      expect(["pausing", "paused"]).toContain(await s.status())
    })

    it("a person's input every 20 s keeps it running", async () => {
      const s = await clocked("cloud-route-1")
      for (let t = 20; t <= 200; t += 20) {
        await s.advance(20_000)
        await s.report({ active_sessions: 0, last_user_input_at: s.vmNow() - 1_000 })
        expect(await s.status(), `at ${t} s`).toBe("running")
      }
    })
  })

  it("a machine started after an idle pause waits a full idle period before it can pause again (review P2)", async () => {
    const s = await vmSetup("cloud-bind-4")
    expect((await s.policy(true, 0)).body.ok).toBe(true)
    const old = { active_sessions: 0, last_user_input_at: hoursAgo(5) }
    await s.stub.fakeControl({ advance_ms: 31 * 60_000 } as never)
    await s.report(old)
    expect(await s.status()).toBe("paused")
    expect((await op(s.a.session, "cloud.machine.start", { machine: s.machine }, crypto.randomUUID())).body.ok).toBe(true)
    expect(await s.status()).toBe("running")
    // The resumed VM still reports its old times (memory was kept): not idle until a full period after the start.
    await s.stub.fakeControl({ advance_ms: 11_000 } as never)
    await s.report(old)
    expect(await s.status()).toBe("running")
    expect(((await s.stub.fakeControl({})) as unknown as { pauses: number }).pauses).toBe(1)
  })
})
