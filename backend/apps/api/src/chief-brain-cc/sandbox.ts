import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"
import { writeConfig } from "../chief-brain/brain-store.ts"
import { CcError, execRoot, freestyle, vmName } from "./vm.ts"

/**
 * The Chief's own sandbox VMs (`chief-vm` in the turn machine; msg 8200 items 6 and 13): machines that outlive a
 * turn, so the Chief keeps a disk, repos and builds between turns without holding a Freestyle key. Every key the
 * Worker could hand out controls the whole Freestyle account (production VMs too), so the key stays here and the
 * Chief gets five actions through its running turn's token: create, list, exec, resize, delete. Only VMs this brain
 * made (their ids in cb_config `cc_sandboxes`) are reachable; at most MAX_LIVE at a time; each has a TTL and pauses
 * when idle (Freestyle resumes it on the next exec).
 *
 * Resize (Lawrence, 2026-10-21): Freestyle's POST /v5/vms/ID/resize, grow only on every axis, at most MAX_SIZE.
 * vCPU and memory apply live; the disk grows only on a running VM, so a paused one is woken first, and the guest's
 * root filesystem is then grown (growpart, resize2fs or xfs_growfs; a no-op when Freestyle already did) so df shows
 * it. `create` takes the same sizes (Freestyle makes a VM at its default 4 vCPU / 8 GiB / 32 GB; it is grown after).
 */
const MAX_LIVE = 2
const TTL_S = 12 * 3600
const IDLE_S = 1800
const EXEC_MAX_MS = 300_000
/** The most a sandbox may be grown to: vCPU, memory in MiB, disk in GB (Freestyle's plan limit may stop it sooner: 429). */
const MAX_SIZE = { cpu: 16, memory_mb: 65_536, disk_gb: 256 } as const
const MIB_PER_GB = 1024

type Size = { cpu?: number; memory_mb?: number; disk_gb?: number }
type Resources = { cpu: number; memory_mb: number; disk_gb: number }
/** The sizes asked for: whole numbers from 1 to MAX_SIZE, each optional; a string error when one is not. */
const sizeOf = (req: Record<string, unknown>): Size | string => {
  const out: Size = {}
  for (const k of ["cpu", "memory_mb", "disk_gb"] as const) {
    const v = req[k]
    if (v === undefined || v === null) continue
    if (typeof v !== "number" || !Number.isInteger(v) || v < 1) return `${k} must be a whole number`
    if (v > MAX_SIZE[k]) return `${k} is at most ${MAX_SIZE[k]}`
    out[k] = v
  }
  return out
}
const hasSize = (s: Size) => s.cpu !== undefined || s.memory_mb !== undefined || s.disk_gb !== undefined
const resourcesOf = (r: unknown): Resources | null => {
  const x = (r && typeof r === "object" ? r : {}) as { cpu?: unknown; memory?: unknown; storage?: unknown }
  if (typeof x.cpu !== "number" || typeof x.memory !== "number" || typeof x.storage !== "number") return null
  return { cpu: x.cpu, memory_mb: x.memory, disk_gb: Math.round(x.storage / MIB_PER_GB) }
}
/** Grows the guest's root filesystem to its disk (the partition first when there is one); prints df for /. */
const GROW_FS = [
  "set +e",
  "src=$(readlink -f /dev/block/$(findmnt -no MAJ:MIN /) 2>/dev/null || findmnt -no SOURCE /)",
  "fs=$(findmnt -no FSTYPE /)",
  "part=$(cat /sys/class/block/$(basename \"$src\")/partition 2>/dev/null)",
  "if [ -n \"$part\" ] && command -v growpart >/dev/null; then growpart /dev/$(lsblk -no PKNAME \"$src\" | head -1) \"$part\" >/dev/null 2>&1; fi",
  "case \"$fs\" in ext*) resize2fs \"$src\" >/dev/null 2>&1 ;; xfs) xfs_growfs / >/dev/null 2>&1 ;; btrfs) btrfs filesystem resize max / >/dev/null 2>&1 ;; esac",
  "df -h / | tail -1"
].join("\n")

/**
 * Grows sandbox `id` to `want` (omitted axes stay): refuses a shrink before Freestyle sees it, wakes a paused VM when
 * the disk grows, then grows the guest filesystem. The new resources and, after a disk change, the guest's df line.
 */
const grow = async (b: ChiefBrainDO, id: string, want: Size): Promise<Out> => {
  const env = b.doEnv
  const got = await freestyle(env, "GET", `/v5/vms/${encodeURIComponent(id)}`, undefined, 10_000)
  if (got.status === 404) return void (await got.body?.cancel().catch(() => undefined)), { status: 404, json: { error: "that sandbox is gone (chief-vm list)" } }
  const vm = (await got.json().catch(() => null)) as { state?: unknown; resources?: unknown } | null
  const now = resourcesOf(vm?.resources)
  if (now) {
    const less = (["cpu", "memory_mb", "disk_gb"] as const).filter((k) => want[k] !== undefined && want[k]! < now[k])
    if (less.length) return { status: 400, json: { error: `sandboxes only grow: ${less.map((k) => `${k} is ${now[k]}`).join(", ")}`, resources: now } }
  }
  const disk = want.disk_gb !== undefined && (!now || want.disk_gb > now.disk_gb)
  // The disk grows only while the VM runs; an exec resumes a paused one.
  if (disk && vm?.state !== "running") await execRoot(env, id, "true", null, 60_000)
  const res = await freestyle(env, "POST", `/v5/vms/${encodeURIComponent(id)}/resize`, {
    ...(want.cpu !== undefined ? { cpu: want.cpu } : {}),
    ...(want.memory_mb !== undefined ? { memory: want.memory_mb } : {}),
    ...(want.disk_gb !== undefined ? { storage: want.disk_gb * MIB_PER_GB } : {})
  }, 120_000)
  const body = (await res.json().catch(() => null)) as { resources?: unknown; message?: unknown } | null
  if (!res.ok) {
    const why = typeof body?.message === "string" ? `: ${body.message.slice(0, 300)}` : ""
    return { status: res.status === 400 || res.status === 409 || res.status === 429 ? res.status : 502, json: { error: `Freestyle did not resize it (${res.status})${why}` } }
  }
  const after = resourcesOf(body?.resources)
  const df = disk ? (await execRoot(env, id, GROW_FS, null, 120_000).catch(() => ({ stdout: "" }))).stdout.trim() : undefined
  return { status: 200, json: { id, resources: after, ...(df !== undefined ? { df } : {}) } }
}

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
  const req = (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {}) as { action?: unknown; id?: unknown; command?: unknown; timeout_ms?: unknown; user?: unknown } & Record<string, unknown>
  const env = b.doEnv
  try {
    switch (req.action) {
      case "list":
        return { status: 200, json: { vms: await live(b), max: MAX_LIVE } }
      case "create": {
        const size = sizeOf(req)
        if (typeof size === "string") return { status: 400, json: { error: size } }
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
        const made = { vm: s, ttl_seconds: TTL_S, idle_pause_seconds: IDLE_S }
        if (!hasSize(size)) return { status: 200, json: made }
        // Freestyle makes it at its default size; grow it now (it is running). The VM stays even when this fails.
        const g = await grow(b, id, size).catch((e) => ({ status: 502, json: { error: e instanceof CcError ? e.message : "the resize failed" } }))
        const gj = g.json as { resources?: unknown; df?: string; error?: string }
        return { status: 200, json: { ...made, ...(g.status === 200 ? { resources: gj.resources, ...(gj.df ? { df: gj.df } : {}) } : { resize_error: gj.error }) } }
      }
      case "resize": {
        const id = typeof req.id === "string" ? req.id : ""
        if (!listOf(b).some((s) => s.id === id)) return { status: 404, json: { error: "not one of your sandboxes (chief-vm list)" } }
        const size = sizeOf(req)
        if (typeof size === "string") return { status: 400, json: { error: size } }
        if (!hasSize(size)) return { status: 400, json: { error: "resize needs cpu, memory_mb or disk_gb" } }
        return await grow(b, id, size)
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
        return { status: 400, json: { error: "action must be create, list, exec, resize or delete" } }
    }
  } catch (e) {
    return { status: 502, json: { error: e instanceof CcError ? e.message : "the sandbox call failed" } }
  }
}
