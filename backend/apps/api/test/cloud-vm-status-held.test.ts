import { runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { bindFile, cloudStub, DAEMON, post, SIZE, signedInWithInstall, vmKey, WG_KEY } from "./cloud-bind-support.ts"
import { quiesce } from "./setup/alarm.ts"

/**
 * cloud.vm.status.report is coalesced: at most one applied per 10 s per machine, and "the latest held
 * report applies when the window ends" (cloud-client-contract.md 1.7). dev-e2e on 2026-10-08 saw the
 * change, heartbeat and resume reports answered `held`; a held report must move CloudDO's alarm to the
 * end of its window, or it waits for an unrelated wake (the cost backstop is a minute or more away).
 */

const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const op = (token: string, name: string, params: unknown) => post("/v1/ops", token, { op: name, params, origin: "cli" })
type Instance = { alarm?: () => Promise<void>; alarmIdle?: Promise<void> }
const runIn = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: Instance, state: DurableObjectState) => Promise<T>) => Promise<T>

describe("held status reports", { timeout: 60_000 }, () => {
  it("a held report arms the alarm for the end of its window", async () => {
    const a = await signedInWithInstall("cloud-bind-1", "mac")
    const created = await post("/v1/ops", a.session, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const machine = created.body.value.machine.id as string
    const stub = cloudStub(a.team)
    const { json } = await bindFile(stub, machine)
    const key = await vmKey()
    const bound = await post("/v1/cloud/bind", undefined, { team: a.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk })
    const install = bound.body.value.install as { id: string; user: string }
    const ch = await post("/v1/auth/challenge", undefined, { user: install.user, install: install.id })
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key.pair.privateKey, new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`))
    const vmToken = (await post("/v1/auth/token", undefined, { user: install.user, install: install.id, nonce: ch.body.nonce, signature: b64u(sig) })).body.access_token as string
    const report = (sessions: number) => op(vmToken, "cloud.vm.status.report", { machine, state: "running", daemon: DAEMON, activity: { active_sessions: sessions } })

    expect((await report(0)).body.value).toEqual({ applied: true })
    // No alarm from earlier commits: only the held report below may arm one.
    await runIn(stub, (instance, state) => quiesce(instance, state))
    const heldAt = Date.now()
    expect((await report(1)).body.value).toEqual({ applied: false })
    const alarm = await runIn(stub, (_instance, state) => state.storage.getAlarm())
    expect(alarm).not.toBeNull()
    expect(alarm!).toBeLessThanOrEqual(heldAt + 10_000 + 1_000)
  })
})
