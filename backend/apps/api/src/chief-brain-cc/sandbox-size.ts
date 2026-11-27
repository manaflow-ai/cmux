import type { Env } from "../env.ts"

/**
 * Sizes, plan limits and cost of the Chief's sandboxes (freestyle.sh/docs/vms/pricing-and-limits, 2026-10-21).
 * The account is on Pro (probed 2026-10-21: 33 vCPU is refused, "up to 32 vCPUs per VM");
 * CHIEF_CC_FREESTYLE_PLAN names another plan. Sizes over the plan's per-VM maximums are refused before
 * Freestyle sees them. Cost is Freestyle's list price per hour of allocation: a running VM pays for vCPU, memory
 * and disk, a paused or stopped one for its disk only.
 */
export const PLANS = {
  free: { cpu: 4, memory_mb: 8 * 1024, disk_gb: 32 },
  hobby: { cpu: 8, memory_mb: 16 * 1024, disk_gb: 64 },
  pro: { cpu: 32, memory_mb: 64 * 1024, disk_gb: 256 }
} as const
export type Resources = { cpu: number; memory_mb: number; disk_gb: number }
export type Size = Partial<Resources>
const PRICE = { cpu_h: 0.04032, gib_memory_h: 0.0129, gib_disk_h: 0.000086 }
const MIB_PER_GB = 1024

export const planOf = (env: Env): { name: keyof typeof PLANS; max: Resources } => {
  const name = (env.CHIEF_CC_FREESTYLE_PLAN ?? "pro") as keyof typeof PLANS
  return PLANS[name] ? { name, max: PLANS[name] } : { name: "pro", max: PLANS.pro }
}

/** The sizes asked for: whole numbers from 1 to the plan's maximum, each optional; a string error when one is not. */
export const sizeOf = (env: Env, req: Record<string, unknown>): Size | string => {
  const { name, max } = planOf(env)
  const out: Size = {}
  for (const k of ["cpu", "memory_mb", "disk_gb"] as const) {
    const v = req[k]
    if (v === undefined || v === null) continue
    if (typeof v !== "number" || !Number.isInteger(v) || v < 1) return `${k} must be a whole number`
    if (v > max[k]) return `${k} is at most ${max[k]} on the Freestyle ${name} plan`
    out[k] = v
  }
  return out
}
export const hasSize = (s: Size) => s.cpu !== undefined || s.memory_mb !== undefined || s.disk_gb !== undefined

/** Freestyle's resources (MiB) as the Chief sees them, or null when absent. */
export const resourcesOf = (r: unknown): Resources | null => {
  const x = (r && typeof r === "object" ? r : {}) as { cpu?: unknown; memory?: unknown; storage?: unknown }
  if (typeof x.cpu !== "number" || typeof x.memory !== "number" || typeof x.storage !== "number") return null
  return { cpu: x.cpu, memory_mb: x.memory, disk_gb: Math.round(x.storage / MIB_PER_GB) }
}
export const toFreestyle = (s: Size) => ({
  ...(s.cpu !== undefined ? { cpu: s.cpu } : {}),
  ...(s.memory_mb !== undefined ? { memory: s.memory_mb } : {}),
  ...(s.disk_gb !== undefined ? { storage: s.disk_gb * MIB_PER_GB } : {})
})

const cents = (x: number) => Math.round(x * 10_000) / 10_000
/** Dollars per hour while running and while paused or stopped (disk only), at list prices. */
export const costOf = (r: Resources | null): { running_usd_per_hour: number; paused_usd_per_hour: number } | null => {
  if (!r) return null
  const disk = (r.disk_gb * MIB_PER_GB) / 1024 * PRICE.gib_disk_h
  return { running_usd_per_hour: cents(r.cpu * PRICE.cpu_h + (r.memory_mb / 1024) * PRICE.gib_memory_h + disk), paused_usd_per_hour: cents(disk) }
}

/** Grows the guest's root filesystem to its disk (the partition first when there is one); prints df for /. */
export const GROW_FS = [
  "set +e",
  "src=$(readlink -f /dev/block/$(findmnt -no MAJ:MIN /) 2>/dev/null || findmnt -no SOURCE /)",
  "fs=$(findmnt -no FSTYPE /)",
  'part=$(cat /sys/class/block/$(basename "$src")/partition 2>/dev/null)',
  'if [ -n "$part" ] && command -v growpart >/dev/null; then growpart /dev/$(lsblk -no PKNAME "$src" | head -1) "$part" >/dev/null 2>&1; fi',
  'case "$fs" in ext*) resize2fs "$src" >/dev/null 2>&1 ;; xfs) xfs_growfs / >/dev/null 2>&1 ;; btrfs) btrfs filesystem resize max / >/dev/null 2>&1 ;; esac',
  "df -h / | tail -1"
].join("\n")

/** What the guest sees: CPUs online, memory and the root filesystem (one line each). */
export const GUEST_SIZE = "nproc; awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo; df -h / | tail -1"
export type Guest = { nproc: number; memory_mb: number; df: string }
export const guestOf = (out: string): Guest | null => {
  const [n, m, ...df] = out.trim().split("\n")
  const nproc = Number(n)
  const memory_mb = Number(m)
  return Number.isFinite(nproc) && Number.isFinite(memory_mb) ? { nproc, memory_mb, df: df.join(" ").trim() } : null
}
