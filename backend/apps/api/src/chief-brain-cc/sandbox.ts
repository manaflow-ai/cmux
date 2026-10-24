import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"
import { writeConfig } from "../chief-brain/brain-store.ts"
import { CcError, freestyle, vmName } from "./vm.ts"
import type { Env } from "../env.ts"
import { execAs, grant, LINUX_USERS, revokeGrant, revokeIdentity } from "./sandbox-access.ts"
import { fileVerb, snapshotVerb, snapsOf, takeSnapshot } from "./sandbox-files.ts"
import { costOf, GROW_FS, GUEST_SIZE, guestOf, hasSize, planOf, resourcesOf, sizeOf, toFreestyle, type Guest, type Resources, type Size } from "./sandbox-size.ts"

/**
 * The Chief's own sandbox VMs (`chief-vm` in the turn machine; msg 8200 items 6 and 13): machines that outlive a
 * turn, so the Chief keeps a disk, repos and builds between turns without holding a Freestyle key. Every key the
 * Worker could hand out controls the whole Freestyle account (production VMs too), so the key stays here and the
 * Chief gets actions through its running turn's token (plans/cmux-next/chief-vm-freestyle-parity.md): list, get,
 * create, update, resize, pause, start, stop, exec, delete, cap; fs (sandbox-files.ts); snapshot, snapshots,
 * snapshot_get, snapshot_rename, snapshot_delete, fork.
 *
 * Kept per Chief, not per conversation: everything here runs in the Chief's `<agent>/sandboxes` object (a brain-class
 * object named after no conversation; turn.ts forwards each call with the running turn's agent). Owner check on
 * every verb: only VMs this Chief made (their ids in that object's cb_config `cc_sandboxes`, and Freestyle's
 * metadata `cmux_chief_sandbox` naming this Chief) are reachable; anything else is 404. exec runs with the Chief's
 * own Freestyle identity token (sandbox-access.ts), never the team key. At most the Chief's cap at a time
 * (CHIEF_CC_SANDBOX_CAP, per Chief CHIEF_CC_SANDBOX_CAPS); each has a TTL and pauses when idle.
 *
 * Sizes (Lawrence, 2026-10-21): grow only on every axis, within the plan's per-VM maximums (sandbox-size.ts).
 * vCPU and memory apply live; the disk grows only on a running VM, so a paused one is started first, and the
 * guest's root filesystem is then grown (a no-op when Freestyle already did) so df shows it. create takes the same
 * sizes. create, resize, get and list show the cost per hour.
 */
const DEFAULT_CAP = 2
const MAX_CAP = 10
const TTL_S = 12 * 3600
const MAX_TTL_S = 72 * 3600
const IDLE_S = 1800
const EXEC_MAX_MS = 300_000
const OWNER_KEY = "cmux_chief_sandbox"

type Sandbox = { id: string; name: string; created_at: number }
type Out = { status: number; json: unknown }
type Req = Record<string, unknown>
type Vm = { id: string; state: string; resources: Resources | null; display_name: string | null; metadata: Record<string, string>; idle_timeout_seconds: number | null; ttl_seconds: number | null }

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

/** The Chief's sandboxes object (one per Chief). */
export const sandboxesOf = (env: Env, agent: string) =>
  env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(`${agent}/sandboxes`)) as unknown as {
    ccSandboxCall(agent: string, req: unknown, legacy: ReadonlyArray<Sandbox>): Promise<Out>
    ccSandboxRetire(): Promise<{ paused: number; revoked: boolean }>
    ccSandboxPurge(): Promise<{ deleted: number; left: number; revoked: boolean }>
  }
/** Sandboxes a conversation brain kept before they moved to the Chief's object. */
export const legacyOf = (b: ChiefBrainDO): Array<Sandbox> => listOf(b)

/** One at a time per object: a create's cap check and save, and every list rewrite (no lost or doubled entry). */
const locks = new WeakMap<object, Promise<unknown>>()
const serial = <T>(b: ChiefBrainDO, fn: () => Promise<T>): Promise<T> => {
  const prev = locks.get(b.sql) ?? Promise.resolve()
  const next = prev.catch(() => undefined).then(fn)
  locks.set(b.sql, next)
  return next
}

/** This Chief's cap on live sandboxes: CHIEF_CC_SANDBOX_CAPS "agent=N,..." first, then CHIEF_CC_SANDBOX_CAP, then 2. */
export const capOf = (b: ChiefBrainDO, agent: string): number => {
  const env = b.doEnv
  const mine = (env.CHIEF_CC_SANDBOX_CAPS ?? "").split(",").map((s) => s.trim().split("=")).find(([a]) => a === agent)?.[1]
  const raw = [mine, env.CHIEF_CC_SANDBOX_CAP].find((x) => x !== undefined && x.trim() !== "")
  const n = Number(raw ?? DEFAULT_CAP)
  return Number.isInteger(n) && n >= 0 ? Math.min(MAX_CAP, n) : DEFAULT_CAP
}

const str = (x: unknown) => (typeof x === "string" ? x : null)
const vmOf = (r: Record<string, unknown>): Vm => ({
  id: String(r.id),
  state: str(r.state) ?? "unknown",
  resources: resourcesOf(r.resources),
  display_name: str(r.displayName),
  metadata: (r.metadata && typeof r.metadata === "object" ? r.metadata : {}) as Record<string, string>,
  idle_timeout_seconds: typeof r.idleTimeoutSeconds === "number" ? r.idleTimeoutSeconds : null,
  ttl_seconds: typeof r.ttlSeconds === "number" ? r.ttlSeconds : null
})
/** The VM at Freestyle: its record, null when it is gone (expired, deleted), "unknown" when Freestyle did not answer. */
const fetchVm = async (b: ChiefBrainDO, id: string): Promise<Vm | null | "unknown"> => {
  const res = await freestyle(b.doEnv, "GET", `/v5/vms/${encodeURIComponent(id)}`, undefined, 10_000).catch(() => null)
  if (!res) return "unknown"
  if (res.status === 404) return void (await res.body?.cancel().catch(() => undefined)), null
  const r = (await res.json().catch(() => null)) as Record<string, unknown> | null
  return res.ok && r ? vmOf(r) : "unknown"
}
/** A sandbox as the Chief sees it: the record plus its size and cost per hour. */
const view = (s: Sandbox, v: Vm | "unknown") => (v === "unknown" ? { ...s, state: "unknown" } : { ...s, state: v.state, display_name: v.display_name, resources: v.resources, cost: costOf(v.resources), idle_timeout_seconds: v.idle_timeout_seconds, ttl_seconds: v.ttl_seconds, metadata: v.metadata })

const liveCount = async (b: ChiefBrainDO) => (await live(b)).length

/** The sandboxes still alive (gone ones are dropped from the list), each with its size and cost. */
const live = async (b: ChiefBrainDO) => {
  const out: Array<ReturnType<typeof view>> = []
  const gone = new Set<string>()
  for (const s of listOf(b)) {
    const v = await fetchVm(b, s.id)
    if (v === null) gone.add(s.id)
    else out.push(view(s, v))
  }
  // Read the list again: a create that finished meanwhile stays; only VMs Freestyle no longer has are dropped.
  if (gone.size) save(b, listOf(b).filter((x) => !gone.has(x.id)))
  return out
}

const NOT_YOURS: Out = { status: 404, json: { error: "not one of your sandboxes (chief-vm list)" } }
/** The owner check: the id is on this brain's list and Freestyle's metadata names this Chief. */
const own = async (b: ChiefBrainDO, agent: string, raw: unknown): Promise<{ s: Sandbox; vm: Vm } | Out> => {
  const id = typeof raw === "string" ? raw : ""
  const s = listOf(b).find((x) => x.id === id)
  if (!s) return NOT_YOURS
  const vm = await fetchVm(b, id)
  if (vm === null) return save(b, listOf(b).filter((x) => x.id !== id)), { status: 404, json: { error: "that sandbox is gone (expired or deleted)" } }
  if (vm === "unknown") return { status: 502, json: { error: "Freestyle did not answer" } }
  if (vm.metadata[OWNER_KEY] !== agent) return NOT_YOURS
  return { s, vm }
}

const errOf = async (res: Response) => {
  const m = ((await res.json().catch(() => null)) as { message?: unknown } | null)?.message
  return typeof m === "string" ? `: ${m.slice(0, 300)}` : ""
}
const passStatus = (n: number) => (n === 400 || n === 409 || n === 429 ? n : 502)

/** Starts a paused or stopped VM. */
const startVm = async (b: ChiefBrainDO, id: string): Promise<Out | null> => {
  const res = await freestyle(b.doEnv, "POST", `/v5/vms/${encodeURIComponent(id)}/start`, {}, 90_000)
  if (!res.ok) return { status: passStatus(res.status), json: { error: `not started (${res.status})${await errOf(res)}` } }
  await res.body?.cancel().catch(() => undefined)
  return null
}

/**
 * Grows sandbox `vm` to `want` (omitted axes stay): refuses a shrink before Freestyle sees it, starts a paused VM
 * when the disk grows, then grows the guest filesystem. The new resources, cost and, after a disk change, df.
 */
const grow = async (b: ChiefBrainDO, vm: Vm, want: Size): Promise<Out> => {
  const now = vm.resources
  if (now) {
    const less = (["cpu", "memory_mb", "disk_gb"] as const).filter((k) => want[k] !== undefined && want[k]! < now[k])
    if (less.length) return { status: 400, json: { error: `sandboxes only grow: ${less.map((k) => `${k} is ${now[k]}`).join(", ")}`, resources: now } }
  }
  const disk = want.disk_gb !== undefined && (!now || want.disk_gb > now.disk_gb)
  if (disk && vm.state !== "running") {
    const bad = await startVm(b, vm.id)
    if (bad) return bad
  }
  const res = await freestyle(b.doEnv, "POST", `/v5/vms/${encodeURIComponent(vm.id)}/resize`, toFreestyle(want), 120_000)
  if (!res.ok) return { status: passStatus(res.status), json: { error: `Freestyle did not resize it (${res.status})${await errOf(res)}` } }
  const after = resourcesOf(((await res.json().catch(() => null)) as { resources?: unknown } | null)?.resources)
  const df = disk ? (await execAs(b, vm.id, { command: GROW_FS, timeout_ms: 120_000, user: "root" }).catch(() => ({ stdout: "" }))).stdout.trim() : undefined
  // CPUs and memory come online in the guest about a second after Freestyle answers: wait for them (at most 15 s).
  let guest: Guest | null = null
  if (vm.state === "running" || disk) {
    for (let i = 0; i < 15; i++) {
      guest = guestOf((await execAs(b, vm.id, { command: GUEST_SIZE, timeout_ms: 10_000, user: "root" }).catch(() => ({ stdout: "" }))).stdout)
      if (!guest || !after || (guest.nproc >= after.cpu && guest.memory_mb >= after.memory_mb * 0.9)) break
      await new Promise((r) => setTimeout(r, 1_000))
    }
  }
  return { status: 200, json: { id: vm.id, resources: after, cost: costOf(after), ...(df !== undefined ? { df } : {}), ...(guest ? { guest } : {}) } }
}

/** Display name, metadata (the owner key is ours), idle timeout and ttl, as create and update take them. */
const settingsOf = (req: Req): Record<string, unknown> | string => {
  const out: Record<string, unknown> = {}
  if (req.name !== undefined) {
    if (typeof req.name !== "string" || req.name.length > 200) return "name must be text (at most 200 characters)"
    out.displayName = req.name
  }
  if (req.metadata !== undefined) {
    const m = req.metadata as Record<string, unknown>
    if (!m || typeof m !== "object" || Array.isArray(m) || Object.keys(m).length > 32 || Object.entries(m).some(([k, v]) => typeof v !== "string" || k.length > 64 || v.length > 512)) return "metadata must be at most 32 text keys and values"
    if (OWNER_KEY in m) return `metadata key ${OWNER_KEY} is reserved`
    out.metadata = m
  }
  for (const [k, field, lo, hi] of [["idle_seconds", "idleTimeoutSeconds", 60, 86_400], ["ttl_seconds", "ttlSeconds", 60, MAX_TTL_S]] as const) {
    const v = req[k]
    if (v === undefined) continue
    if (typeof v !== "number" || !Number.isInteger(v) || v < lo || v > hi) return `${k} must be a whole number from ${lo} to ${hi}`
    out[field] = v
  }
  return out
}

/**
 * Small disks (Lawrence, 2026-10-22: "default new VM disk to the smallest that fits"): a sandbox starts from the
 * smallest Ubuntu base, freestyle/ubuntu-sm (2 vCPU / 4 GiB / 16 GB), and is grown to DEFAULT_SIZE's CPU and memory
 * (the disk stays 16 GB unless asked). `image: "chief"` starts from the Chief's own image (its tools and clones;
 * 32 GB), `snapshot` from a Freestyle base snapshot. A VM starts at its snapshot's size and only grows.
 */
const SMALL = "freestyle/ubuntu-sm"
const BASES: Record<string, Resources> = {
  "freestyle/busybox": { cpu: 1, memory_mb: 128, disk_gb: 1 },
  "freestyle/ubuntu-sm": { cpu: 2, memory_mb: 4096, disk_gb: 16 },
  "freestyle/ubuntu": { cpu: 4, memory_mb: 8192, disk_gb: 32 },
  "freestyle/ubuntu-lg": { cpu: 8, memory_mb: 16384, disk_gb: 64 },
  "freestyle/ubuntu-xl": { cpu: 16, memory_mb: 32768, disk_gb: 128 },
  "freestyle/ubuntu-2xl": { cpu: 32, memory_mb: 65536, disk_gb: 128 }
}
const CHIEF_USER = "id chief >/dev/null 2>&1 || useradd -m -s /bin/bash chief"
const CHIEF_IMAGE: Resources = { cpu: 4, memory_mb: 8192, disk_gb: 32 }
const DEFAULT_SIZE = { cpu: 4, memory_mb: 8192 }

/** The snapshot a sandbox starts from and its size (null when unknown), or a refusal. */
const snapshotOf = (b: ChiefBrainDO, req: Req): { id: string; base: Resources | null; small: boolean } | Out => {
  if (req.image !== undefined && req.image !== "chief" && req.image !== "ubuntu") return { status: 400, json: { error: "image must be ubuntu (the default: Ubuntu 24.04, 16 GB disk) or chief (your machine image: tools and clones, 32 GB)" } }
  if (req.image === "chief") return { id: b.doEnv.CHIEF_CC_SNAPSHOT ?? "", base: CHIEF_IMAGE, small: false }
  if (req.snapshot === undefined) return { id: SMALL, base: BASES[SMALL]!, small: true }
  if (typeof req.snapshot === "string" && /^freestyle\/[a-z0-9._-]{1,64}$/.test(req.snapshot)) return { id: req.snapshot, base: BASES[req.snapshot] ?? null, small: false }
  // One of its own snapshots: the VM starts at the size it was taken at (Freestyle refuses a smaller ask).
  if (typeof req.snapshot === "string" && snapsOf(b).some((s) => s.id === req.snapshot)) return { id: req.snapshot, base: null, small: false }
  return { status: 400, json: { error: "snapshot must be a Freestyle base snapshot (freestyle/NAME, e.g. freestyle/ubuntu) or one of yours (chief-vm snapshots); omit it for the default small Ubuntu, or use image chief" } }
}

const execIn = (req: Req) => {
  if (typeof req.command !== "string" || !req.command.trim() || req.command.length > 100_000) return "exec needs a command"
  const user = req.user ?? "root"
  if (!LINUX_USERS.includes(user as (typeof LINUX_USERS)[number])) return `user must be ${LINUX_USERS.join(" or ")}`
  const env = req.env as Record<string, unknown> | undefined
  if (env !== undefined && (!env || typeof env !== "object" || Array.isArray(env) || Object.entries(env).some(([k, v]) => !/^[A-Za-z_][A-Za-z0-9_]*$/.test(k) || typeof v !== "string"))) return "env must map POSIX names to text"
  // The turn machine's runner takes 200 kB a call: stdin is at most 128 KiB here (larger input: chief-vm fs put).
  if (req.stdin !== undefined && (typeof req.stdin !== "string" || req.stdin.length > 180_000)) return "stdin must be base64, at most 128 KiB (larger input: chief-vm fs put, then read the file)"
  return {
    command: req.command,
    timeout_ms: Math.min(EXEC_MAX_MS, Math.max(1_000, Number(req.timeout_ms) || 120_000)),
    user: user as (typeof LINUX_USERS)[number],
    ...(env ? { env: env as Record<string, string> } : {}),
    ...(typeof req.stdin === "string" && req.stdin ? { stdin: req.stdin } : {})
  }
}

const ACTIONS = "list, get, create, update, resize, pause, start, stop, exec, fs, snapshot, snapshots, snapshot_get, snapshot_rename, snapshot_delete, fork, delete or cap"
const VM_ACTIONS = ["get", "update", "resize", "pause", "start", "stop", "exec", "fs", "snapshot", "fork", "delete"]
const SNAP_ACTIONS = ["snapshots", "snapshot_get", "snapshot_rename", "snapshot_delete"]

/** Makes a sandbox (size, settings, snapshot), grants the Chief's identity on it, then grows it to the size asked. */
const create = async (b: ChiefBrainDO, agent: string, req: Req): Promise<Out> => {
  const env = b.doEnv
    const size = sizeOf(env, req)
    if (typeof size === "string") return { status: 400, json: { error: size } }
    const settings = settingsOf(req)
    if (typeof settings === "string") return { status: 400, json: { error: settings } }
    const from = snapshotOf(b, req)
    if ("status" in from) return from
    const snapshot = from.id
    // Below the image's size is impossible (a VM only grows); the small default grows to the usual CPU and memory.
    const under = from.base ? (["cpu", "memory_mb", "disk_gb"] as const).filter((k) => size[k] !== undefined && size[k]! < from.base![k]) : []
    if (under.length) return { status: 400, json: { error: `that image starts at ${from.base!.cpu} vCPU / ${from.base!.memory_mb / 1024} GiB / ${from.base!.disk_gb} GB; ${under.join(", ")} cannot be smaller` } }
    if (from.small) Object.assign(size, { cpu: size.cpu ?? DEFAULT_SIZE.cpu, memory_mb: size.memory_mb ?? DEFAULT_SIZE.memory_mb })
    const { metadata, ...rest } = settings as { metadata?: Record<string, string>; ttlSeconds?: number; idleTimeoutSeconds?: number }
    const reserved = await serial(b, async (): Promise<Out | Sandbox> => {
    const now = await live(b)
    const cap = capOf(b, agent)
    if (now.length >= cap) return { status: 429, json: { error: `at most ${cap} sandboxes; delete one first (chief-vm delete ID)`, vms: now } }
    const name = vmName(env).replace("-ccb-", "-ccs-")
    const res = await freestyle(env, "POST", "/v5/vms", {
      slug: name,
      snapshotId: snapshot,
      idleTimeoutSeconds: IDLE_S,
      ttlSeconds: TTL_S,
      automaticRestart: false,
      ...rest,
      metadata: { ...(metadata ?? {}), [OWNER_KEY]: agent },
      firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] }
    }, 120_000)
    const body = (await res.json().catch(() => null)) as { id?: string; vmId?: string } | null
    const id = body?.id ?? body?.vmId
    if (!res.ok || !id) return { status: 502, json: { error: `Freestyle did not make the VM (${res.status})` } }
    const s: Sandbox = { id, name, created_at: Date.now() }
    save(b, [...listOf(b), s])
    return s
    })
    if ("status" in reserved) return reserved
    const { id } = reserved
    const s = reserved
    await grant(b, id).catch(() => undefined)
    // Both images have the `chief` user exec --user chief runs as (Freestyle's Ubuntu has only ubuntu).
    await execAs(b, id, { command: CHIEF_USER, timeout_ms: 30_000, user: "root" }).catch(() => undefined)
    const made = { vm: s, ttl_seconds: rest.ttlSeconds ?? TTL_S, idle_pause_seconds: rest.idleTimeoutSeconds ?? IDLE_S }
    const v = await fetchVm(b, id)
    const vm = v && v !== "unknown" ? v : null
    if (!hasSize(size) || !vm) return { status: 200, json: { ...made, resources: vm?.resources ?? null, cost: costOf(vm?.resources ?? null) } }
    // Freestyle makes it at its snapshot's size; grow it now (it is running). The VM stays even when this fails.
    const g = await grow(b, vm, size).catch((e) => ({ status: 502, json: { error: e instanceof CcError ? e.message : "the resize failed" } }))
    const gj = g.json as { resources?: Resources; cost?: unknown; df?: string; error?: string }
    return { status: 200, json: { ...made, ...(g.status === 200 ? { resources: gj.resources, cost: gj.cost, ...(gj.df ? { df: gj.df } : {}) } : { resources: vm.resources, cost: costOf(vm.resources), resize_error: gj.error }) } }
}

export async function ccSandbox(b: ChiefBrainDO, agent: string, raw: unknown, legacy: ReadonlyArray<Sandbox> = []): Promise<Out> {
  const req = (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {}) as Req
  const env = b.doEnv
  if (legacy.length) {
    const have = listOf(b)
    save(b, [...have, ...legacy.filter((x) => typeof x?.id === "string" && !have.some((h) => h.id === x.id))])
  }
  try {
    if (req.action === "list") return { status: 200, json: { vms: await live(b), max: capOf(b, agent), plan: planOf(env) } }
    if (req.action === "cap") return { status: 200, json: { cap: capOf(b, agent), live: (await live(b)).length, plan: planOf(env) } }
    if (req.action === "create") return await create(b, agent, req)
    if (SNAP_ACTIONS.includes(String(req.action))) return await snapshotVerb(b, String(req.action), req)
    if (!VM_ACTIONS.includes(String(req.action))) return { status: 400, json: { error: `action must be ${ACTIONS}` } }
    const o = await own(b, agent, req.id)
    if ("status" in o) return o
    const { s, vm } = o
    const at = `/v5/vms/${encodeURIComponent(vm.id)}`
    switch (req.action) {
      case "get":
        return { status: 200, json: { vm: view(s, vm) } }
      case "update": {
        const settings = settingsOf(req)
        if (typeof settings === "string") return { status: 400, json: { error: settings } }
        if (Object.keys(settings).length === 0) return { status: 400, json: { error: "update needs name, metadata, idle_seconds or ttl_seconds" } }
        if (settings.metadata) settings.metadata = { ...(settings.metadata as object), [OWNER_KEY]: agent }
        const res = await freestyle(env, "PATCH", at, settings)
        if (!res.ok) return { status: passStatus(res.status), json: { error: `not updated (${res.status})${await errOf(res)}` } }
        const r = (await res.json().catch(() => null)) as Record<string, unknown> | null
        return { status: 200, json: { vm: view(s, r ? vmOf({ ...r, id: vm.id }) : vm) } }
      }
      case "resize": {
        const size = sizeOf(env, req)
        if (typeof size === "string") return { status: 400, json: { error: size } }
        if (!hasSize(size)) return { status: 400, json: { error: "resize needs cpu, memory_mb or disk_gb" } }
        return await grow(b, vm, size)
      }
      case "pause": {
        const res = await freestyle(env, "POST", `${at}/pause`, {}, 90_000)
        if (!res.ok) return { status: passStatus(res.status), json: { error: `not paused (${res.status})${await errOf(res)}` } }
        await res.body?.cancel().catch(() => undefined)
        return { status: 200, json: { id: vm.id, state: "paused", cost: costOf(vm.resources) } }
      }
      case "start": {
        const bad = await startVm(b, vm.id)
        return bad ?? { status: 200, json: { id: vm.id, state: "running", cost: costOf(vm.resources) } }
      }
      case "stop": {
        // Freestyle has no stop route: power off in the guest, then wait for `stopped` (its disk stays; memory goes).
        if (vm.state === "stopped") return { status: 200, json: { id: vm.id, state: "stopped", cost: costOf(vm.resources) } }
        if (vm.state !== "running") {
          const bad = await startVm(b, vm.id)
          if (bad) return bad
        }
        const off = await execAs(b, vm.id, { command: "(sleep 1; poweroff) >/dev/null 2>&1 &", timeout_ms: 10_000, user: "root" }).then(() => null, (e: unknown) => (e instanceof CcError ? e.message : "the power-off did not run"))
        if (off) return { status: 502, json: { error: `not stopped: ${off}` } }
        const until = Date.now() + 60_000
        while (Date.now() < until) {
          const v = await fetchVm(b, vm.id)
          if (v && v !== "unknown" && v.state === "stopped") return { status: 200, json: { id: vm.id, state: "stopped", cost: costOf(vm.resources) } }
          await new Promise((r) => setTimeout(r, 1_000))
        }
        return { status: 504, json: { error: "powered off, but Freestyle did not report it stopped within 60 s (chief-vm get ID)" } }
      }
      case "fs":
        return await fileVerb(b, vm.id, String(req.op ?? ""), req)
      case "snapshot": {
        const { snap: _, ...out } = await takeSnapshot(b, vm.id, req)
        return out
      }
      case "fork": {
        // A snapshot of this VM (memory and disk), then a new sandbox from it, with the same create options.
        // The cap is checked here for a fast answer, and again by create inside its lock.
        if ((await liveCount(b)) >= capOf(b, agent)) return { status: 429, json: { error: `at most ${capOf(b, agent)} sandboxes; delete one first (chief-vm delete ID)` } }
        const t = await takeSnapshot(b, vm.id, { name: typeof req.name === "string" ? `fork of ${vm.id}: ${req.name}` : `fork of ${vm.id}` })
        if (!t.snap) return { status: t.status, json: t.json }
        const made = await create(b, agent, { ...req, snapshot: t.snap.id })
        return made.status === 200 ? { status: 200, json: { ...(made.json as object), forked_from: vm.id, snapshot: t.snap.id } } : made
      }
      case "exec": {
        const x = execIn(req)
        if (typeof x === "string") return { status: 400, json: { error: x } }
        const r = await execAs(b, vm.id, x)
        return { status: 200, json: { exit: r.exit, stdout: r.stdout, stderr: r.stderr } }
      }
      case "delete": {
        await revokeGrant(b, vm.id)
        const res = await freestyle(env, "DELETE", at).catch(() => null)
        await res?.body?.cancel().catch(() => undefined)
        if (!res || !(res.ok || res.status === 404)) return { status: 502, json: { error: `not deleted (${res?.status ?? "no answer"})` } }
        save(b, listOf(b).filter((x) => x.id !== vm.id))
        return { status: 200, json: { deleted: vm.id } }
      }
    }
    return { status: 400, json: { error: `action must be ${ACTIONS}` } }
  } catch (e) {
    return { status: 502, json: { error: e instanceof CcError ? e.message : "the sandbox call failed" } }
  }
}

/** The Chief was archived: its sandboxes pause (their disks stay until their TTL; a restored Chief has them) and its identity goes. */
export const ccSandboxRetire = async (b: ChiefBrainDO): Promise<{ paused: number; revoked: boolean }> => {
  let paused = 0
  for (const s of listOf(b)) {
    const res = await freestyle(b.doEnv, "POST", `/v5/vms/${encodeURIComponent(s.id)}/pause`, {}, 90_000).catch(() => null)
    await res?.body?.cancel().catch(() => undefined)
    if (res?.ok) paused++
  }
  return { paused, revoked: await revokeIdentity(b) }
}

/** The Chief was deleted: its sandboxes are deleted (disks and all; nothing can restore them) and its identity goes. A
 * sandbox Freestyle did not delete stays listed, so its TTL still ends it. */
export const ccSandboxPurge = async (b: ChiefBrainDO): Promise<{ deleted: number; left: number; revoked: boolean }> => {
  // One list rewrite under serial (as every rewrite): a sandbox made meanwhile is never dropped from the list.
  const { deleted, left } = await serial(b, async () => {
    const all = listOf(b)
    const gone = new Set<string>()
    for (const s of all) {
      await revokeGrant(b, s.id).catch(() => undefined)
      const res = await freestyle(b.doEnv, "DELETE", `/v5/vms/${encodeURIComponent(s.id)}`).catch(() => null)
      await res?.body?.cancel().catch(() => undefined)
      if (res && (res.ok || res.status === 404)) gone.add(s.id)
    }
    const rest = listOf(b).filter((x) => !gone.has(x.id))
    save(b, rest)
    return { deleted: gone.size, left: rest.length }
  })
  return { deleted, left, revoked: await revokeIdentity(b) }
}
