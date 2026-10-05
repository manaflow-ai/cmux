import { describe, expect, it } from "vitest"
import { createBody } from "../src/cloud-driver.ts"
import { bindFile, cloudStub, DAEMON, post, SIZE, signedInWithInstall, vmKey, WG_KEY } from "./cloud-bind-support.ts"

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
  const report = (activity: Record<string, unknown>) => op(vmToken, "cloud.vm.status.report", { machine, state: "running", daemon: DAEMON, activity })
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
})
