import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"
import { writeConfig } from "../chief-brain/brain-store.ts"
import { CcError, execRoot, freestyle, vmName } from "./vm.ts"

/**
 * The Chief's own sandbox VMs (`chief-vm` in the turn machine; msg 8200 items 6 and 13): machines that outlive a
 * turn, so the Chief keeps a disk, repos and builds between turns without holding a Freestyle key. Every key the
 * Worker could hand out controls the whole Freestyle account (production VMs too), so the key stays here and the
 * Chief gets four actions through its running turn's token: create, list, exec, delete. Only VMs this brain made
 * (their ids in cb_config `cc_sandboxes`) are reachable; at most MAX_LIVE at a time; each has a TTL and pauses
 * when idle (Freestyle resumes it on the next exec).
 */
const MAX_LIVE = 2
const TTL_S = 12 * 3600
const IDLE_S = 1800
const EXEC_MAX_MS = 300_000

type Sandbox = { id: string; name: string; created_at: number }
type Out = { status: number; json: unknown }

const listOf = (b: ChiefBrainDO): Array<Sandbox> => {
  const raw = b.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = 'cc_sandboxes'`).toArray()[0]?.value
  try {
    const xs = JSON.parse(raw ?? "[]") as Array<Sandbox>
    return Array.isArray(xs) ? xs.filter((x) => typeof x?.id === "string") : []
  } catch {
    return []
  }
}
const save = (b: ChiefBrainDO, xs: ReadonlyArray<Sandbox>) => writeConfig(b.sql, { cc_sandboxes: JSON.stringify(xs) })

/** Its state at Freestyle, or null when it is gone (expired, deleted). */
const stateOf = async (b: ChiefBrainDO, id: string): Promise<string | null> => {
  const res = await freestyle(b.doEnv, "GET", `/v5/vms/${encodeURIComponent(id)}`, undefined, 10_000).catch(() => null)
  if (!res) return "unknown"
  if (res.status === 404) return void (await res.body?.cancel().catch(() => undefined)), null
  const r = (await res.json().catch(() => null)) as { state?: unknown } | null
  return typeof r?.state === "string" ? r.state : "unknown"
}

/** The sandboxes still alive (gone ones are dropped from the list). */
const live = async (b: ChiefBrainDO): Promise<Array<Sandbox & { state: string }>> => {
  const out: Array<Sandbox & { state: string }> = []
  for (const s of listOf(b)) {
    const state = await stateOf(b, s.id)
    if (state !== null) out.push({ ...s, state })
  }
  save(b, out.map(({ state: _, ...s }) => s))
  return out
}

export async function ccSandbox(b: ChiefBrainDO, agent: string, raw: unknown): Promise<Out> {
  const req = (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {}) as { action?: unknown; id?: unknown; command?: unknown; timeout_ms?: unknown; user?: unknown }
  const env = b.doEnv
  try {
    switch (req.action) {
      case "list":
        return { status: 200, json: { vms: await live(b), max: MAX_LIVE } }
      case "create": {
        const now = await live(b)
        if (now.length >= MAX_LIVE) return { status: 429, json: { error: `at most ${MAX_LIVE} sandboxes; delete one first (chief-vm delete ID)`, vms: now } }
        const name = vmName(env).replace("-ccb-", "-ccs-")
        const res = await freestyle(env, "POST", "/v5/vms", {
          slug: name,
          snapshotId: env.CHIEF_CC_SNAPSHOT,
          idleTimeoutSeconds: IDLE_S,
          ttlSeconds: TTL_S,
          automaticRestart: false,
          metadata: { cmux_chief_sandbox: agent },
          firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] }
        }, 120_000)
        const body = (await res.json().catch(() => null)) as { id?: string; vmId?: string } | null
        const id = body?.id ?? body?.vmId
        if (!res.ok || !id) return { status: 502, json: { error: `Freestyle did not make the VM (${res.status})` } }
        const s: Sandbox = { id, name, created_at: Date.now() }
        save(b, [...listOf(b), s])
        return { status: 200, json: { vm: s, ttl_seconds: TTL_S, idle_pause_seconds: IDLE_S } }
      }
      case "exec":
      case "delete": {
        const id = typeof req.id === "string" ? req.id : ""
        if (!listOf(b).some((s) => s.id === id)) return { status: 404, json: { error: "not one of your sandboxes (chief-vm list)" } }
        if (req.action === "delete") {
          const res = await freestyle(env, "DELETE", `/v5/vms/${encodeURIComponent(id)}`).catch(() => null)
          await res?.body?.cancel().catch(() => undefined)
          if (!res || !(res.ok || res.status === 404)) return { status: 502, json: { error: `not deleted (${res?.status ?? "no answer"})` } }
          save(b, listOf(b).filter((s) => s.id !== id))
          return { status: 200, json: { deleted: id } }
        }
        if (typeof req.command !== "string" || !req.command.trim() || req.command.length > 100_000) return { status: 400, json: { error: "exec needs a command" } }
        const ms = Math.min(EXEC_MAX_MS, Math.max(1_000, Number(req.timeout_ms) || 120_000))
        const r = await execRoot(env, id, req.command, null, ms)
        return { status: 200, json: { exit: r.exit, stdout: r.stdout } }
      }
      default:
        return { status: 400, json: { error: "action must be create, list, exec or delete" } }
    }
  } catch (e) {
    return { status: 502, json: { error: e instanceof CcError ? e.message : "the sandbox call failed" } }
  }
}
