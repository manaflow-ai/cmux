import type { Env } from "./env.ts"

/**
 * Where a Chief's hand sandbox runs. A hand is provider-agnostic (it is `curl install.sh | sh` on any
 * Linux or macOS host), so a provider only makes a machine, runs the install line in it, pauses or
 * deletes it, and lists the machines this deployment made (for the sweep).
 *
 * This is NOT the cmux Cloud VM product: Cloud VMs are Freestyle only, with no fallback provider
 * (cloud-driver.ts). Hand sandboxes are a separate, user-chosen place to run work; the person picks
 * the provider. Every person also has the bring-your-own path: run the install line with a
 * `sandbox` code in any machine of their own.
 *
 * Adapters: Freestyle today (HAND_FREESTYLE_API_KEY). E2B, Daytona, Modal, Blaxel, a Docker host, a
 * Kubernetes pod and any SSH host are thin adapters of the same five calls; each needs its own
 * hands-only key in the environment before it is listed.
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

const TIMEOUT_MS = 20_000
const IDLE_SECONDS = 1800

const freestyleBase = (env: Env) => (env.CLOUD_FREESTYLE_API_URL || "https://api.freestyle.sh").replace(/\/+$/, "")
/** The hands-only Freestyle key (HAND_FREESTYLE_API_KEY): no other code reads it, and hand sandboxes use no other key. */
const freestyleHeaders = (env: Env) => ({ authorization: `Bearer ${env.HAND_FREESTYLE_API_KEY}`, "content-type": "application/json" })
const freestyle = (env: Env, method: string, path: string, body?: unknown, ms = TIMEOUT_MS) =>
  fetch(`${freestyleBase(env)}${path}`, { method, headers: freestyleHeaders(env), redirect: "manual", signal: AbortSignal.timeout(ms), ...(body === undefined ? {} : { body: JSON.stringify(body) }) }).catch(() => null)

export const freestyleProvider: SandboxProvider = {
  id: "freestyle",
  ready: (env) => Boolean(env.HAND_FREESTYLE_API_KEY && env.HAND_SANDBOX_SNAPSHOT),
  canManage: (env) => Boolean(env.HAND_FREESTYLE_API_KEY),
  async create(env, input) {
    const res = await freestyle(env, "POST", "/v5/vms", {
      slug: input.name,
      snapshotId: env.HAND_SANDBOX_SNAPSHOT,
      idleTimeoutSeconds: IDLE_SECONDS,
      automaticRestart: false,
      metadata: { cmux_hand: input.hand, cmux_owner: input.owner, cmux_deployment: input.deployment },
      firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] }
    })
    const body = (await res?.json().catch(() => null)) as { vmId?: string; id?: string } | null
    const id = body?.vmId ?? body?.id
    return res?.ok && id ? { id } : null
  },
  async exec(env, id, command, timeoutMs) {
    const res = await freestyle(env, "POST", `/v5/vms/${encodeURIComponent(id)}/exec-await`, { command, timeoutMs, linuxUser: "root" }, timeoutMs + 10_000)
    const ran = (await res?.json().catch(() => null)) as { statusCode?: number | null } | null
    return res?.ok && typeof ran?.statusCode === "number" ? ran.statusCode : null
  },
  async pause(env, id) {
    const res = await freestyle(env, "POST", `/v5/vms/${encodeURIComponent(id)}/pause`)
    return res !== null && res.ok
  },
  async remove(env, id) {
    const res = await freestyle(env, "DELETE", `/v5/vms/${encodeURIComponent(id)}`)
    return res !== null && (res.ok || res.status === 404)
  },
  async list(env, prefix) {
    const out: Array<MadeMachine> = []
    const done = new Set<string>()
    for (let page = 0; page < 20; page++) {
      const res = await freestyle(env, "GET", `/v5/vms?limit=100&offset=${page * 100}`)
      if (!res?.ok) break
      const vms = ((await res.json().catch(() => ({}))) as { vms?: Array<{ id?: string; slug?: string | null; createdAt?: string; metadata?: Record<string, unknown> | null }> }).vms ?? []
      // A list that ignores the offset gives the same page again: stop there.
      if (vms.every((v) => !v.id || done.has(v.id))) break
      for (const v of vms) {
        if (!v.id || done.has(v.id)) continue
        done.add(v.id)
        if (!v.slug?.startsWith(`${prefix}hand-`) || typeof v.metadata?.cmux_hand !== "string") continue
        out.push({ id: v.id, created_at: Date.parse(v.createdAt ?? ""), hand: v.metadata.cmux_hand, deployment: typeof v.metadata.cmux_deployment === "string" ? v.metadata.cmux_deployment : undefined })
      }
      if (vms.length < 100) break
    }
    return out
  }
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

/** Providers by id; only the ones whose key is on this deployment are offered. */
export const PROVIDERS: Readonly<Record<string, SandboxProvider>> = {
  freestyle: freestyleProvider,
  e2b: stub("e2b", "HAND_E2B_API_KEY"),
  daytona: stub("daytona", "HAND_DAYTONA_API_KEY"),
  modal: stub("modal", "HAND_MODAL_TOKEN"),
  blaxel: stub("blaxel", "HAND_BLAXEL_API_KEY"),
  docker: stub("docker", "HAND_DOCKER_HOST"),
  kubernetes: stub("kubernetes", "HAND_KUBERNETES_CONFIG"),
  ssh: stub("ssh", "HAND_SSH_HOST"),
  test: testProvider
}

/** The provider a person asked for (default: the first ready one), or null when none is ready. */
export const sandboxProvider = (env: Env, wanted?: string): SandboxProvider | null => {
  if (wanted) return PROVIDERS[wanted]?.ready(env) ? PROVIDERS[wanted]! : null
  // (an unknown or stub provider: the caller answers "not set up"; hand-sandbox.ts names the provider)
  return Object.values(PROVIDERS).find((p) => p.ready(env)) ?? null
}
