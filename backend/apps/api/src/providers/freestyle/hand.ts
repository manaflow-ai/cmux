import type { Env } from "../../env.ts"
import type { MadeMachine, SandboxProvider } from "../../hand-providers.ts"

const TIMEOUT_MS = 20_000
const IDLE_SECONDS = 1800

const freestyleBase = (env: Env) => (env.CLOUD_FREESTYLE_API_URL || "https://api.freestyle.sh").replace(/\/+$/, "")
/** The hands-only Freestyle key (HAND_FREESTYLE_API_KEY): no other code reads it, and hand sandboxes use no other key. */
const freestyleHeaders = (env: Env) => ({ authorization: `Bearer ${env.HAND_FREESTYLE_API_KEY}`, "content-type": "application/json" })
const freestyle = (env: Env, method: string, path: string, body?: unknown, ms = TIMEOUT_MS) =>
  fetch(`${freestyleBase(env)}${path}`, { method, headers: freestyleHeaders(env), redirect: "manual", signal: AbortSignal.timeout(ms), ...(body === undefined ? {} : { body: JSON.stringify(body) }) }).catch(() => null)

/** Hand sandboxes on Freestyle (hand-providers.ts): only HAND_FREESTYLE_API_KEY and HAND_SANDBOX_SNAPSHOT. */
export const freestyleHands: SandboxProvider = {
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
