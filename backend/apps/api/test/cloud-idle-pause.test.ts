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
  const report = (activity: Record<string, unknown>) => op(vmToken, "cloud.vm.status.report", { machine, state: "running", daemon: DAEMON, activity })
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
})
