import type { Env } from "./env.ts"
import { HAND_PROVIDERS } from "./providers/index.ts"

/**
 * Where a Chief's hand sandbox runs. A hand is provider-agnostic (it is `curl install.sh | sh` on any
 * Linux or macOS host), so a provider only makes a machine, runs the install line in it, pauses or
 * deletes it, and lists the machines this deployment made (for the sweep).
 *
 * This is NOT the cmux Cloud VM product: Cloud VMs have their own provider contract
 * (providers/contract.ts). Hand sandboxes are a separate, user-chosen place to run work; the person picks
 * the provider. Every person also has the bring-your-own path: run the install line with a
 * `sandbox` code in any machine of their own.
 *
 * Adapters live in providers/<name>/hand.ts, each with its own hands-only key in the environment;
 * one is written today (providers/index.ts). E2B, Daytona, Modal, Blaxel, a Docker host, a
 * Kubernetes pod and any SSH host are thin adapters of the same five calls, listed below as stubs
 * until written.
 */
export interface MadeMachine {
  readonly id: string
  readonly created_at: number
  /** The tags it was made with: the hand and this deployment's origin. */
  readonly hand?: string
  readonly deployment?: string
}

export interface CreateInput {
  /** The provider's machine name (this deployment's prefix + `hand-` + random). */
  readonly name: string
  readonly hand: string
  readonly owner: string
  readonly deployment: string
}

export interface SandboxProvider {
  readonly id: string
  /** The provider's key and image are set on this deployment (it can make sandboxes). */
  ready(env: Env): boolean
  /** The provider's key is set (it can list and delete what was made, even with no image now). */
  canManage(env: Env): boolean
  create(env: Env, input: CreateInput): Promise<{ id: string } | null>
  /** Runs `command` as root; the exit code, or null when the provider did not answer. */
  exec(env: Env, id: string, command: string, timeoutMs: number): Promise<number | null>
  pause(env: Env, id: string): Promise<boolean>
  /** Deletes by exact id; true once the provider confirms (a missing machine counts). */
  remove(env: Env, id: string): Promise<boolean>
  /** Machines with a hand tag and this deployment's name prefix. */
  list(env: Env, prefix: string): Promise<ReadonlyArray<MadeMachine>>
}

/** A provider whose adapter is not written yet: it answers that no key is configured (docs/chief-hands.md). */
const stub = (id: string, keyVar: string): SandboxProvider => {
  const none = async () => {
    throw new Error(`no key configured for the ${id} sandbox provider (${keyVar})`)
  }
  return { id, ready: () => false, canManage: () => false, create: none, exec: none, pause: none, remove: none, list: async () => [] }
}

/**
 * Test only (ENVIRONMENT "test"): a sandbox whose install command is handed to the test, which plays the machine
 * (pairs with the code, dials the hand socket). Never ready on a deployment.
 */
export const testSandboxInstalls: Array<{ readonly code: string; readonly name: string }> = []
const testProvider: SandboxProvider = {
  id: "test",
  ready: (env) => env.ENVIRONMENT === "test",
  canManage: (env) => env.ENVIRONMENT === "test",
  create: async () => ({ id: `test-vm-${crypto.randomUUID().slice(0, 8)}` }),
  exec: async (_env, _id, command) => {
    const m = /--pair (\S+) --name ([A-Za-z0-9._-]+)/.exec(command)
    if (!m) return 1
    testSandboxInstalls.push({ code: m[1]!, name: m[2]! })
    return 0
  },
  pause: async () => true,
  remove: async () => true,
  list: async () => []
}

/** Providers by id, written adapters first; only the ones whose key is on this deployment are offered. */
export const PROVIDERS: Readonly<Record<string, SandboxProvider>> = Object.fromEntries(
  [
    ...HAND_PROVIDERS,
    stub("e2b", "HAND_E2B_API_KEY"),
    stub("daytona", "HAND_DAYTONA_API_KEY"),
    stub("modal", "HAND_MODAL_TOKEN"),
    stub("blaxel", "HAND_BLAXEL_API_KEY"),
    stub("docker", "HAND_DOCKER_HOST"),
    stub("kubernetes", "HAND_KUBERNETES_CONFIG"),
    stub("ssh", "HAND_SSH_HOST"),
    testProvider
  ].map((p) => [p.id, p])
)

/** The provider a person asked for (default: the first ready one), or null when none is ready. */
export const sandboxProvider = (env: Env, wanted?: string): SandboxProvider | null => {
  if (wanted) return PROVIDERS[wanted]?.ready(env) ? PROVIDERS[wanted]! : null
  // (an unknown or stub provider: the caller answers "not set up"; hand-sandbox.ts names the provider)
  return Object.values(PROVIDERS).find((p) => p.ready(env)) ?? null
}
