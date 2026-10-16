import type { Env } from "./env.ts"
import { handStub, indexStub, mintPairCode } from "./hand-api.ts"
import { randomB32, type HandCaller, type HandReply } from "./hand-wire.ts"

/**
 * A new Freestyle sandbox with its hand: mint a pairing code, create the VM, and run the install line
 * in it through the provider's exec (no SSH, no inbound port). The VM is the hand's: removing the
 * hand deletes it, a failed install deletes it at once, an unredeemed code deletes it at expiry, and
 * a sandbox lives at most 24 h (hand-do.ts). Off unless the environment names the sandbox image
 * (HAND_SANDBOX_SNAPSHOT, baked by scripts/bake-hand-sandbox.ts), its own public origin
 * (CLOUD_API_ORIGIN), its VM name prefix (CLOUD_NAME_PREFIX) and the hands-only Freestyle key
 * (HAND_FREESTYLE_API_KEY). An owner has at most HAND_SANDBOX_MAX (default 3) live sandboxes.
 */

const SANDBOX_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$/
const IDLE_SECONDS = 1800
const INSTALL_TIMEOUT_MS = 150_000
const PROVIDER_TIMEOUT_MS = 20_000
/** VM name prefixes of the non-production environments (FREESTYLE-NAMES; cloud-driver.ts). */
const PREFIX = /^cmuxnp-(dev|stg|prod)-cld-$/

const base = (env: Env) => (env.CLOUD_FREESTYLE_API_URL || "https://api.freestyle.sh").replace(/\/+$/, "")
/** The hands-only Freestyle key (HAND_FREESTYLE_API_KEY): no other code reads it, and sandboxes use no other key. */
const headers = (env: Env) => ({ authorization: `Bearer ${env.HAND_FREESTYLE_API_KEY}`, "content-type": "application/json" })
const maxSandboxes = (env: Env) => {
  const n = Number(env.HAND_SANDBOX_MAX ?? "3")
  return Number.isInteger(n) && n >= 0 && n <= 20 ? n : 3
}
const unavailable = (message: string): HandReply<never> => ({ ok: false, error: { code: "hand.sandbox_unavailable", message } })

export interface Sandbox {
  readonly hand: string
  readonly name: string
  readonly vm: string
  readonly online: boolean
}

export const createSandbox = async (env: Env, caller: HandCaller, name: string): Promise<HandReply<Sandbox>> => {
  if (!env.HAND_FREESTYLE_API_KEY || !env.HAND_SANDBOX_SNAPSHOT) return unavailable("sandboxes are off on this deployment")
  // The deployment's own origin only (never a fallback to another environment): the sandbox pairs with it.
  const origin = (env.CLOUD_API_ORIGIN ?? "").replace(/\/$/, "")
  if (!/^https:\/\/[A-Za-z0-9.-]+$/.test(origin)) return unavailable("this deployment names no public https origin; a sandbox cannot reach it")
  const prefix = env.CLOUD_NAME_PREFIX ?? ""
  if (!PREFIX.test(prefix)) return unavailable("this deployment names no sandbox VM prefix")
  if (!SANDBOX_NAME.test(name)) return { ok: false, error: { code: "request.invalid", message: "name: 1-40 letters, digits, . _ -, starting with a letter or digit" } }
  if (env.PAIR_BEGIN_LIMIT) {
    const { success } = await env.PAIR_BEGIN_LIMIT.limit({ key: `hand-sandbox:${caller.user}` })
    if (!success) return { ok: false, error: { code: "rate_limited", message: "too many new sandboxes; wait a minute" } }
  }
  const live = (await indexStub(env, caller.user).listHands()).filter((h) => h.sandbox && h.revoked_at === null).length
  if (live >= maxSandboxes(env)) return { ok: false, error: { code: "hand.sandbox_limit", message: `you have ${live} sandboxes (the most is ${maxSandboxes(env)}); remove one first` } }
  const minted = await mintPairCode(env, caller, name, origin)
  if (!minted.ok) return minted
  const { hand, code } = minted.value
  const stub = handStub(env, hand)
  const created = await fetch(`${base(env)}/v5/vms`, {
    method: "POST",
    headers: headers(env),
    redirect: "manual",
    signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
    body: JSON.stringify({
      slug: `${prefix}hand-${randomB32(12)}`,
      snapshotId: env.HAND_SANDBOX_SNAPSHOT,
      idleTimeoutSeconds: IDLE_SECONDS,
      automaticRestart: false,
      metadata: { cmux_hand: hand, cmux_owner: caller.user, cmux_deployment: origin },
      firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] }
    })
  }).catch(() => null)
  const body = (await created?.json().catch(() => null)) as { vmId?: string; id?: string } | null
  const vm = body?.vmId ?? body?.id
  if (!created?.ok || !vm) {
    // No VM id came back: the code is dropped now. A VM the provider made anyway is named by
    // metadata.cmux_hand (UNVERIFIED: no sweep finds it yet).
    await stub.discard()
    return { ok: false, error: { code: "hand.sandbox_failed", message: `the sandbox was not created (${created?.status ?? "no answer"})` } }
  }
  await stub.setSandbox(vm)
  // The code and name are checked shapes (PAIR_CODE, SANDBOX_NAME); a login shell gives the
  // image's tools (node, claude, opencode) on the PATH the hand's service keeps.
  const command = `bash -lc 'curl -fsSL ${origin}/hand/install.sh | sh -s -- --pair ${code} --name ${name}'`
  const exec = await fetch(`${base(env)}/v5/vms/${encodeURIComponent(vm)}/exec-await`, {
    method: "POST",
    headers: headers(env),
    redirect: "manual",
    body: JSON.stringify({ command, timeoutMs: INSTALL_TIMEOUT_MS, linuxUser: "root" }),
    signal: AbortSignal.timeout(INSTALL_TIMEOUT_MS + 10_000)
  }).catch(() => null)
  const ran = (await exec?.json().catch(() => null)) as { statusCode?: number | null } | null
  if (!exec?.ok || ran?.statusCode !== 0) {
    // The VM's output stays on the VM side: it may hold anything; the answer names only the exit.
    await stub.discard()
    return { ok: false, error: { code: "hand.sandbox_install_failed", message: `the hand did not install in the sandbox (exit ${ran?.statusCode ?? exec?.status ?? "none"}); the sandbox was deleted` } }
  }
  const online = await stub.waitOnline(30_000)
  return { ok: true, value: { hand, name, vm, online } }
}

/** Deletes the sandbox VM of a removed hand by its exact id; true once the provider confirms (2xx or 404). */
export const deleteSandboxVm = async (env: Env, vm: string): Promise<boolean> => {
  if (!env.HAND_FREESTYLE_API_KEY) return false
  const res = await fetch(`${base(env)}/v5/vms/${encodeURIComponent(vm)}`, { method: "DELETE", headers: headers(env), redirect: "manual", signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS) }).catch(() => null)
  return res !== null && ((res.status >= 200 && res.status < 300) || res.status === 404)
}
