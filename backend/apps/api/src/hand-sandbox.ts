import type { Env } from "./env.ts"
import { handStub, indexStub, mintPairCode } from "./hand-api.ts"
import { sandboxProvider } from "./hand-providers.ts"
import { randomB32, type HandCaller, type HandReply } from "./hand-wire.ts"

/**
 * A new sandbox with its hand, on a person-chosen provider (hand-providers.ts): mint a pairing code,
 * make the machine, and run the install line in it through the provider (no SSH, no inbound port).
 * The machine is the hand's: removing the hand deletes it, a failed install deletes it at once, an
 * unredeemed code deletes it at expiry, and a sandbox lives at most 24 h (hand-do.ts). Off unless a
 * provider is ready, the deployment names its own public origin (CLOUD_API_ORIGIN) and its machine
 * prefix (CLOUD_NAME_PREFIX). An owner has at most HAND_SANDBOX_MAX (default 3) live sandboxes.
 * A sandbox hand runs at level `full` by default: no classifier and no approvals (hand-levels.ts).
 */

const SANDBOX_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$/
const INSTALL_TIMEOUT_MS = 150_000
/** Machine name prefixes of the environments (the provider naming decision; cloud-driver.ts). */
export const SANDBOX_PREFIX = /^cmuxnp-(dev|stg|prod)-cld-$/
/** The tests' prefix is accepted only where ENVIRONMENT is "test" (its provider is the test one). */
const sandboxPrefixOk = (env: Env, prefix: string) => SANDBOX_PREFIX.test(prefix) || (env.ENVIRONMENT === "test" && prefix === "cmuxnp-test-cld-")

const maxSandboxes = (env: Env) => {
  const n = Number(env.HAND_SANDBOX_MAX ?? "3")
  return Number.isInteger(n) && n >= 0 && n <= 20 ? n : 3
}
const unavailable = (message: string): HandReply<never> => ({ ok: false, error: { code: "hand.sandbox_unavailable", message } })

export interface Sandbox {
  readonly hand: string
  readonly name: string
  readonly vm: string
  readonly provider: string
  readonly online: boolean
}

export const createSandbox = async (env: Env, caller: HandCaller, name: string, wanted?: string): Promise<HandReply<Sandbox>> => {
  const provider = sandboxProvider(env, wanted)
  if (!provider) return unavailable(wanted ? `the sandbox provider ${wanted} is not set up on this deployment (no key configured)` : "sandboxes are off on this deployment")
  // The deployment's own origin only (never a fallback to another environment): the sandbox pairs with it.
  const origin = (env.CLOUD_API_ORIGIN ?? "").replace(/\/$/, "")
  if (!/^https:\/\/[A-Za-z0-9.-]+$/.test(origin)) return unavailable("this deployment names no public https origin; a sandbox cannot reach it")
  const prefix = env.CLOUD_NAME_PREFIX ?? ""
  if (!sandboxPrefixOk(env, prefix)) return unavailable("this deployment names no sandbox name prefix")
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
  const made = await provider.create(env, { name: `${prefix}hand-${randomB32(12)}`, hand, owner: caller.user, deployment: origin })
  if (!made) {
    // No id came back: the code is dropped now; a machine the provider made anyway carries this
    // deployment's tags, and the hourly sweep deletes it (hand-sweep.ts).
    await stub.discard()
    return { ok: false, error: { code: "hand.sandbox_failed", message: `the ${provider.id} sandbox was not created` } }
  }
  await stub.setSandbox(made.id, provider.id)
  // The code and name are checked shapes (PAIR_CODE, SANDBOX_NAME); a login shell gives the
  // image's tools (node, claude, opencode) on the PATH the hand's service keeps.
  const exit = await provider.exec(env, made.id, `bash -lc 'curl -fsSL ${origin}/hand/install.sh | sh -s -- --pair ${code} --name ${name}'`, INSTALL_TIMEOUT_MS)
  if (exit !== 0) {
    // The machine's output stays there: it may hold anything; the answer names only the exit.
    await stub.discard()
    return { ok: false, error: { code: "hand.sandbox_install_failed", message: `the hand did not install in the sandbox (exit ${exit ?? "none"}); the sandbox was deleted` } }
  }
  const online = await stub.waitOnline(30_000)
  return { ok: true, value: { hand, name, vm: made.id, provider: provider.id, online } }
}
