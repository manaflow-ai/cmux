import type { SqlStore } from "@cmux/ownership"
import { ledgerKey } from "./domains/cloud.ts"
import { platformPrincipal, refused, platformMetadata, PLATFORM_MACHINE_LABEL, type PlatformHost, type PlatformReply } from "./cloud-platform.ts"
import type { PlatformMachine, PlatformShape } from "./platform-machines.ts"

/** Durable continuations above the ordinary Cloud ledger: no provider calls bypass submit.
 * Terminal records are retained as idempotency fences even after the ordinary ledger is pruned.
 * A fork's temporary snapshot is retired only after the child's create ledger has settled.
 */
interface Operation {
  key: string
  user: string
  name: string
  source?: string
  image?: string
  target: PlatformShape
  labels: Record<string, string>
  confirmedShape?: PlatformShape
  phase: "capture" | "create" | "size" | "cleanup" | "done" | "failed"
  snapshot?: string
  child?: string
  deadline: number
  due: number
  error?: string
}
type Request = { name: string; shape?: PlatformShape; snapshot?: string; machine?: string; labels?: Record<string, string> }
const matchesRequest = (o: Operation, input: Request) => o.source === input.machine && o.image === input.snapshot && (!input.shape || sameShape(o.target, input.shape)) && labelKey(o.labels) === labelKey(input.labels)
const RETRY_MS = 5_000
const DEADLINE_MS = 15 * 60_000
const opKey = (user: string, name: string) => `${user}:${name}`
const sameShape = (a: PlatformShape, b: PlatformShape) => a.vcpu === b.vcpu && a.memGiB === b.memGiB && a.diskGiB === b.diskGiB
const larger = (a: PlatformShape, b: PlatformShape) => a.vcpu > b.vcpu || a.memGiB > b.memGiB || a.diskGiB > b.diskGiB
const labelKey = (labels: Record<string, string> = {}) => JSON.stringify(Object.entries(labels).sort(([a], [b]) => a.localeCompare(b)))
const terminal = (o: Operation) => o.phase === "done" || o.phase === "failed"

export class PlatformOperations {
  private readonly flights = new Map<string, Promise<void>>()
  constructor(private readonly sql: SqlStore) {}
  private exists() { return Number(this.sql.exec<{ n: number }>("SELECT count(*) AS n FROM sqlite_master WHERE name = 'cloud_platform_operations'")[0]?.n ?? 0) > 0 }
  private read(key: string): Operation | undefined {
    if (!this.exists()) return undefined
    const row = this.sql.exec<{ data: string }>("SELECT data FROM cloud_platform_operations WHERE key = ?", key)[0]
    return row ? JSON.parse(row.data) as Operation : undefined
  }
  private put(o: Operation) {
    // A destroy may arrive while a provider call is awaited. Its cancellation wins over the
    // older continuation; retain newly discovered resource IDs so that cleanup can reach them.
    const prior = this.read(o.key)
    if (prior?.error && !o.error) { o.error = prior.error; o.phase = "cleanup" }

    this.sql.exec("CREATE TABLE IF NOT EXISTS cloud_platform_operations (key TEXT PRIMARY KEY, child TEXT, due INTEGER, data TEXT NOT NULL)")
    this.sql.exec("INSERT INTO cloud_platform_operations (key, child, due, data) VALUES (?, ?, ?, ?) ON CONFLICT(key) DO UPDATE SET child = excluded.child, due = excluded.due, data = excluded.data", o.key, o.child ?? null, terminal(o) ? null : o.due, JSON.stringify(o))
  }
  dueAt(): number | null {
    if (!this.exists()) return null
    const due = this.sql.exec<{ due: number | null }>("SELECT min(due) AS due FROM cloud_platform_operations")[0]?.due
    return due == null ? null : Number(due)
  }
  private forMachine(host: PlatformHost, id: string): Operation | undefined {
    if (!this.exists()) return undefined
    const row = this.sql.exec<{ data: string }>("SELECT data FROM cloud_platform_operations WHERE child = ?", id)[0]
    if (row) return JSON.parse(row.data) as Operation
    // submit commits the ordinary ledger before awaiting its provider call. Reads and destroy
    // may interleave in that await, before the continuation has copied the child's ID here.
    const pending = this.sql.exec<{ data: string }>("SELECT data FROM cloud_platform_operations WHERE child IS NULL AND due IS NOT NULL")
    for (const { data } of pending) {
      const o = JSON.parse(data) as Operation
      const identity = platformPrincipal(host.team, o.user).identity
      if (host.ledger(ledgerKey(identity, this.stepKey(o, "create")))?.machine !== id) continue
      o.child = id
      this.put(o)
      return o
    }
    return undefined
  }
  async metadata(host: PlatformHost, id: string): Promise<PlatformReply<PlatformMachine>> {
    const m = host.machine(id)
    if (!m) return refused("cloud.machine.not_found", "no such setup machine in this team", false)
    const o = this.forMachine(host, id)
    if (o && o.phase !== "done") return { ok: true, value: { id, region: "global", state: o.error ? "failed" : "starting", shape: o.confirmedShape ?? o.target, targetShape: o.target } }
    const metadata = platformMetadata(m)
    if (!metadata.ok || (m.status !== "running" && m.status !== "paused")) return metadata
    // Legacy create can retain the requested size when its best-effort resource read failed.
    // Running/paused answers never present that reservation as confirmed provider capacity.
    const actual = await host.resources(m).catch(() => null)
    if (!actual) return refused("cloud.machine.shape_unknown", "the provider has not confirmed this machine's resources", true)
    const current = host.machine(id)
    if (!current) return refused("cloud.machine.not_found", "no such setup machine in this team", false)
    const fresh = platformMetadata(current)
    return fresh.ok ? { ok: true, value: { ...fresh.value, shape: actual } } : fresh
  }
  busy(host: PlatformHost, id: string): boolean {
    const o = this.forMachine(host, id)
    return o !== undefined && !terminal(o)
  }
  cancel(host: PlatformHost, id: string, now: number) {
    const o = this.forMachine(host, id)
    if (!o || terminal(o)) return
    o.error = "the machine was deleted before provisioning completed"
    o.phase = "cleanup"
    o.due = now
    this.put(o)
  }
  /** Recovery only: no writes, provider reads, continuation, or membership dependency. The user
   * owns the journal key and child. Conservative starting metadata carries the ID needed for cleanup
   * even when credentials are gone and the current provider size cannot be confirmed. */
  recover(host: PlatformHost, user: string, input: Request): PlatformReply<PlatformMachine> {
    const o = this.read(opKey(user, input.name))
    if (!o) return refused("cloud.provider.unavailable", "no existing machine request can be recovered while this provider is unavailable", false)
    if (!matchesRequest(o, input)) return refused("idempotency.conflict", "this name belongs to another machine request", false)
    const id = o.child ?? host.ledger(ledgerKey(platformPrincipal(host.team, user).identity, this.stepKey(o, "create")))?.machine
    const m = id ? host.machine(id) : undefined
    if (m && m.platform === true && m.creator === user) return { ok: true, value: { id: m.id, region: "global", state: o.error || m.status === "failed" ? "failed" : m.status === "deleting" ? "stopped" : "starting", shape: o.confirmedShape ?? o.target, targetShape: o.target } }
    if (terminal(o)) return refused("cloud.machine.not_found", "the machine for this request is gone", false)
    return refused("mutation.indeterminate", "the recorded request is awaiting cleanup; no new work was started", true)
  }

  /** Fence every pending child BEFORE CloudCore retries its ledger. A failed delete admission
   * must abort the wake: running the base pass without its cancellation could create a new VM.
   * Captures retain their journal until the ordinary capture ledger settles; no restore follows. */
  async stopAllocations(host: PlatformHost, now: number): Promise<void> {
    if (!this.exists()) return
    const candidates = this.sql.exec<{ data: string }>("SELECT data FROM cloud_platform_operations WHERE due IS NOT NULL").map(({ data }) => JSON.parse(data) as Operation)
    const pending: Operation[] = []
    for (const candidate of candidates) {
      const member = await host.mayUse(candidate.user).catch(() => false)
      // A concurrent continuation can finish while membership is read; completed machines are
      // retained. Only unfinished work is revoked or expired, before the provider retries it.
      const o = this.read(candidate.key)
      if (!o || terminal(o)) continue
      if (!o.error && member && host.providerInfo().available && host.now < o.deadline) continue
      pending.push(o)
      const identity = platformPrincipal(host.team, o.user).identity
      o.child ??= host.ledger(ledgerKey(identity, this.stepKey(o, "create")))?.machine
      o.snapshot ??= host.ledger(ledgerKey(identity, this.stepKey(o, "capture")))?.snapshot
      o.error ??= "provisioning expired, the provider was disabled, or the creator lost access"
      o.phase = "cleanup"
      o.due = now
      this.put(o)
    }
    for (const o of pending) {
      const m = o.child ? host.machine(o.child) : undefined
      const p = platformPrincipal(host.team, o.user)
      if (m && m.status !== "deleting") await host.submit(p, { t: "op", op: "cloud.machine.delete", params: { machine: m.id }, idempotency_key: this.stepKey(o, `delete:${m.revision}`), origin: "script" })
      const create = host.ledger(ledgerKey(p.identity, this.stepKey(o, "create")))
      if (create?.state === "pending" && !create.cancel) throw new Error("platform create cancellation has not committed")
      const resize = host.ledger(ledgerKey(p.identity, this.stepKey(o, "resize")))
      if (resize?.state === "pending") throw new Error("platform resize cancellation has not committed")
    }
  }

  async request(host: PlatformHost, user: string, input: Request, now: number): Promise<PlatformReply<PlatformMachine>> {
    const key = opKey(user, input.name)
    let o = this.read(key)
    if (o) {
      if (!matchesRequest(o, input)) return refused("idempotency.conflict", "this name belongs to another machine request", false)
    } else {
      if (input.snapshot) {
        const image = host.snapshot(input.snapshot)
        if (!image) return refused("cloud.snapshot.not_found", "no such snapshot in this team", false)
        if (image.transport === "vm-api") return refused("cloud.provider.unsupported", "this snapshot belongs to another provider transport", false)
      }
      let target = input.shape
      if (input.machine) {
        const source = host.machine(input.machine)
        if (!source || source.platform !== true || source.creator !== user) return refused("cloud.machine.not_found", "no such setup machine in this team", false)
        if (source.transport === "vm-api") return refused("cloud.provider.unsupported", "this machine belongs to another provider transport", false)
        if (this.busy(host, source.id) || (source.status !== "running" && source.status !== "paused")) return refused("cloud.machine.not_running", "the source must finish starting before forking", true)
        target = await host.resources(source).catch(() => null) ?? undefined
      }
      if (!target) return refused("cloud.machine.shape_unknown", "the machine's resources are not known yet", true)
      // Install the alarm before recording any work; a crash can leave a harmless alarm, never an
      // unserviced allocating intent. The host binds its engine so OwnerDO's alarm will run.
      await host.arm(now + RETRY_MS)
      // Another request may have installed this name while arm awaited storage. Re-enter the
      // synchronous identity check before doing any work; the final absent read and put never await.
      if (this.read(key)) return this.request(host, user, input, now)
      o = { key, user, name: input.name, ...(input.machine ? { source: input.machine } : {}), ...(input.snapshot ? { image: input.snapshot } : {}), target, labels: input.labels ?? {}, phase: input.machine ? "capture" : "create", due: now, deadline: now + DEADLINE_MS }
      this.put(o)
    }
    await this.run(host, key, now)
    o = this.read(key)!
    if (o.phase === "failed") return refused("cloud.platform.provision_failed", o.error ?? "machine provisioning failed", false)
    if (o.child && host.machine(o.child)) return this.metadata(host, o.child)
    if (o.phase === "done") return refused("cloud.machine.not_found", "the machine created under this name is gone", false)
    return refused("mutation.indeterminate", "the machine request is recorded and still starting; retry with the same name", true)
  }
  async wake(host: PlatformHost, now: number) {
    if (!this.exists()) return
    const keys = this.sql.exec<{ key: string }>("SELECT key FROM cloud_platform_operations WHERE due <= ? ORDER BY due LIMIT 32", now)
    for (const { key } of keys) await this.run(host, key, now)
  }
  private stepKey(o: Operation, step: string) { return `platform-machine:${o.name}:${step}` }
  private async run(host: PlatformHost, key: string, now: number): Promise<void> {
    const active = this.flights.get(key)
    if (active) return active
    const work = this.advance(host, key, now)
    this.flights.set(key, work)
    try { await work } finally { this.flights.delete(key) }
  }
  private async advance(host: PlatformHost, key: string, now: number): Promise<void> {
    const o = this.read(key)
    if (!o || terminal(o)) return
    o.due = now + RETRY_MS
    this.put(o)
    const p = platformPrincipal(host.team, o.user)
    const ledger = (step: string) => host.ledger(ledgerKey(p.identity, this.stepKey(o, step)))
    const submit = async (op: string, params: unknown, step: string) => {
      const r = await host.submit(p, { t: "op", op, params, idempotency_key: this.stepKey(o, step), origin: "script" })
      return r.frames.find(f => f.t === "reject") as { t: "reject"; code: string; message: string; retryable?: boolean } | undefined
    }
    const fail = (message: string) => { o.error = message; o.phase = "cleanup"; this.put(o) }
    const authorized = async () => {
      const member = await host.mayUse(o.user).catch(() => false)
      if (!member || host.now >= o.deadline || !host.providerInfo().available) fail("machine provisioning expired, the provider changed, or the creator lost team access")
      // Merge cancellation that may have arrived while membership was awaited.
      this.put(o)
      return !o.error
    }
    // Recover IDs BEFORE membership/deadline cleanup: submit can have committed while its answer
    // was lost. Skipping this recovery would forget the very resources cleanup must remove.
    o.child ??= ledger("create")?.machine
    o.snapshot ??= ledger("capture")?.snapshot
    this.put(o)
    if (o.phase !== "cleanup") await authorized()
    if (o.phase === "capture") {
      const existing = ledger("capture")
      if (!existing) {
        const r = await submit("cloud.snapshot.create", { machine: o.source, name: PLATFORM_MACHINE_LABEL }, "capture")
        o.snapshot = ledger("capture")?.snapshot
        this.put(o)
        if (r && !r.retryable) fail(r.message)
      }
      const l = ledger("capture")
      const snap = o.snapshot ? host.snapshot(o.snapshot) : undefined
      if (l && l.state !== "pending" && l.state !== "done") fail(l.error?.message ?? "snapshot capture failed")
      if (o.phase === "capture" && snap?.status === "ready") { o.phase = "create"; this.put(o) }
    }
    if (o.phase === "create") await authorized()
    if (o.phase === "create") {
      if (!ledger("create")) {
        const image = o.snapshot ?? o.image
        const r = await submit(image ? "cloud.snapshot.restore" : "cloud.machine.create", image ? { snapshot: image, name: PLATFORM_MACHINE_LABEL } : { name: PLATFORM_MACHINE_LABEL, size: { cpu: o.target.vcpu, memory_mb: o.target.memGiB * 1024, disk_mb: o.target.diskGiB * 1024 } }, "create")
        o.child = ledger("create")?.machine
        this.put(o)
        if (r && !r.retryable) fail(r.message)
      }
      const l = ledger("create")
      if (o.phase === "create" && l?.state === "done") { o.phase = "size"; this.put(o) }
      else if (l && l.state !== "pending") fail(l.error?.message ?? "machine creation failed")
    }
    if (o.phase === "size") {
      const m = o.child ? host.machine(o.child) : undefined
      const resize = ledger("resize")
      if (!m || m.status === "failed" || m.status === "deleting") fail("the new machine failed or was deleted")
      else if (resize?.state === "pending") return
      else if (resize && resize.state !== "done") fail(resize.error?.message ?? "machine resize failed")
      else {
        const actual = await host.resources(m).catch(() => null)
        if (!actual) return
        o.confirmedShape = actual
        this.put(o)
        // A destroy may have arrived while the resource lookup was awaited.
        if (o.phase === "size" && await authorized()) {
          if (larger(actual, o.target)) fail("the image is larger than the requested shape; Freestyle only supports growing")
          else if (sameShape(actual, o.target)) { o.phase = "cleanup"; this.put(o) }
          else if (m.status === "running" && !resize) {
            const r = await submit("cloud.machine.resize", { machine: m.id, size: { cpu: o.target.vcpu, memory_mb: o.target.memGiB * 1024, disk_mb: o.target.diskGiB * 1024 } }, "resize")
            if (r && !r.retryable) fail(r.message)
            if (ledger("resize")?.state === "done") {
              const confirmed = await host.resources(m).catch(() => null)
              if (confirmed) {
                o.confirmedShape = confirmed
                if (larger(confirmed, o.target)) fail("the resized machine exceeds the requested shape")
                else if (sameShape(confirmed, o.target)) o.phase = "cleanup"
                this.put(o)
              }
            }
          }
        }
      }
    }

    if (o.phase !== "cleanup") return
    if (o.error && o.child) {
      const m = host.machine(o.child)
      if (m) {
        if (m.status !== "deleting") await submit("cloud.machine.delete", { machine: m.id }, `delete:${m.revision}`)
        if (host.machine(o.child)) return
      }
    }
    // A child can still depend on the capture while create is uncertain; ordinary Cloud's
    // cancelled-create reconciliation owns late VMs. Keep the capture until it has settled.
    if (ledger("create")?.state === "pending" || ledger("capture")?.state === "pending") return
    if (o.snapshot) {
      const s = host.snapshot(o.snapshot)
      if (s) {
        if (s.status !== "deleting") await submit("cloud.snapshot.delete", { snapshot: s.id }, `retire:${s.revision}`)
        if (host.snapshot(o.snapshot)) return
      }
    }
    if (!o.error && !(await authorized())) return
    o.phase = o.error ? "failed" : "done"
    this.put(o)
  }
}
