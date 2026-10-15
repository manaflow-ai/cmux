import type { Env } from "./env.ts"
import { handStub, mintPairCode } from "./hand-api.ts"
import { randomB32, type HandCaller, type HandReply } from "./hand-wire.ts"

/**
 * A new Freestyle sandbox with its hand: mint a pairing code, create the VM, and run the install line
 * in it through the provider's exec (no SSH, no inbound port). The VM is the hand's: removing the
 * hand deletes it. Off unless the environment names the sandbox image (HAND_SANDBOX_SNAPSHOT) and has
 * the Cloud Freestyle key; VMs are named under CLOUD_NAME_PREFIX and pause when idle.
 */

const SANDBOX_NAME = /^[A-Za-z0-9._-]{1,40}$/
const IDLE_SECONDS = 1800
const INSTALL_TIMEOUT_MS = 150_000

const base = (env: Env) => (env.CLOUD_FREESTYLE_API_URL || "https://api.freestyle.sh").replace(/\/+$/, "")
const headers = (env: Env) => ({ authorization: `Bearer ${env.CLOUD_FREESTYLE_API_KEY}`, "content-type": "application/json" })

export interface Sandbox {
  readonly hand: string
  readonly name: string
  readonly vm: string
  readonly online: boolean
}

export const createSandbox = async (env: Env, caller: HandCaller, name: string, origin: string): Promise<HandReply<Sandbox>> => {
  if (!env.CLOUD_FREESTYLE_API_KEY || !env.HAND_SANDBOX_SNAPSHOT) return { ok: false, error: { code: "hand.sandbox_unavailable", message: "sandboxes are off on this deployment" } }
  if (!SANDBOX_NAME.test(name)) return { ok: false, error: { code: "request.invalid", message: "name: 1-40 letters, digits, . _ -" } }
  if (!/^https:\/\/[A-Za-z0-9.-]+$/.test(origin)) return { ok: false, error: { code: "hand.sandbox_unavailable", message: "the API origin is not public https; a sandbox cannot reach it" } }
  const minted = await mintPairCode(env, caller, name, origin)
  if (!minted.ok) return minted
  const { hand, code } = minted.value
  const created = await fetch(`${base(env)}/v5/vms`, {
    method: "POST",
    headers: headers(env),
    redirect: "manual",
    body: JSON.stringify({
      slug: `${env.CLOUD_NAME_PREFIX ?? "cmuxnp-dev-cld-"}hand-${randomB32(12)}`,
      snapshotId: env.HAND_SANDBOX_SNAPSHOT,
      idleTimeoutSeconds: IDLE_SECONDS,
      automaticRestart: false,
      metadata: { cmux_hand: hand, cmux_owner: caller.user },
      firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] }
    })
  }).catch(() => null)
  const body = (await created?.json().catch(() => null)) as { vmId?: string; id?: string } | null
  const vm = body?.vmId ?? body?.id
  if (!created?.ok || !vm) return { ok: false, error: { code: "hand.sandbox_failed", message: `the sandbox was not created (${created?.status ?? "no answer"})` } }
  const stub = handStub(env, hand)
  await stub.setSandbox(vm)
  // The code and name are checked shapes (PAIR_CODE, SANDBOX_NAME), so the line needs no quoting beyond this.
  const command = `sh -c 'curl -fsSL ${origin}/hand/install.sh | sh -s -- --pair ${code} --name ${name}'`
  const exec = await fetch(`${base(env)}/v5/vms/${encodeURIComponent(vm)}/exec-await`, {
    method: "POST",
    headers: headers(env),
    redirect: "manual",
    body: JSON.stringify({ command, timeoutMs: INSTALL_TIMEOUT_MS, linuxUser: "root" }),
    signal: AbortSignal.timeout(INSTALL_TIMEOUT_MS + 10_000)
  }).catch(() => null)
  const ran = (await exec?.json().catch(() => null)) as { statusCode?: number | null; stderr?: string } | null
  if (!exec?.ok || ran?.statusCode !== 0) {
    return { ok: false, error: { code: "hand.sandbox_install_failed", message: `the hand did not install in ${vm}: ${(ran?.stderr ?? "").slice(-300)}` } }
  }
  const online = await stub.waitOnline(30_000)
  return { ok: true, value: { hand, name, vm, online } }
}

/** Deletes the sandbox VM of a removed hand (by its exact id; a missing VM is fine). */
export const deleteSandboxVm = async (env: Env, vm: string): Promise<void> => {
  if (!env.CLOUD_FREESTYLE_API_KEY) return
  await fetch(`${base(env)}/v5/vms/${encodeURIComponent(vm)}`, { method: "DELETE", headers: headers(env), redirect: "manual" }).catch(() => undefined)
}
