import type { OwnerFrame, Principal } from "@cmux/ownership"
import type { SubmitResult } from "./owner-do.ts"
import { asWorkUser } from "./cloud-env-sandbox.ts"
import { DriverError, type GuestExecResult } from "./providers/contract.ts"
import { ledgerKey, PLATFORM_IDENTITY_PREFIX, type LedgerRow, type MachineRow } from "./domains/cloud.ts"
import type { SnapshotRow } from "./domains/cloud-snapshot.ts"
import type { PlatformMachine, PlatformShape, PlatformProviderInfo } from "./platform-machines.ts"
import type { PlatformOperations } from "./cloud-platform-operations.ts"

/**
 * Machines for the platform Worker's environment setups (PlatformMachines, platform-machines.ts):
 * boot, exec, snapshot and delete on the team's CloudDO, as the person who asked for the setup. Boot,
 * snapshot and delete are the person's own ops (cloud.machine.create, cloud.snapshot.restore,
 * cloud.snapshot.create, cloud.machine.delete) through the normal submit path, so plan checks,
 * quotas, the per-team limit and the provider-call ledger apply exactly as for a person's machine.
 *
 * The principal is the named user in the named team, with its own identity (`platform:<user>`) so
 * its idempotency keys never meet the person's. Boot, exec and snapshot first check that the user may
 * use the team's machines (personal team, or a member with team.resources now); find and delete do
 * not, so cleanup outlives a departure. Exec, snapshot, resize and delete reach only machines a platform boot
 * of the same user made (the row's `platform` flag), never a person's own machine. Exec runs as the
 * image's work user, never root.
 */

/** Shown in the team's machine and snapshot lists. */
export const PLATFORM_MACHINE_LABEL = "Environment setup"
/** One exec answers within the provider's own limit (automation steps use the same). */
export const PLATFORM_EXEC_MAX_MS = 300_000

export type PlatformCall =
  | { readonly op: "boot"; readonly name: string; readonly snapshot?: string }
  | { readonly op: "providerInfo" }
  | { readonly op: "create"; readonly name: string; readonly shape: PlatformShape; readonly snapshot?: string; readonly labels: Record<string, string> }
  | { readonly op: "find"; readonly name: string }
  | { readonly op: "get"; readonly machine: string }
  | { readonly op: "shape"; readonly machine: string }
  | { readonly op: "pause"; readonly machine: string }
  | { readonly op: "resume"; readonly machine: string }
  | { readonly op: "resize"; readonly machine: string; readonly shape: PlatformShape }
  | { readonly op: "fork"; readonly machine: string; readonly name: string }
  | { readonly op: "exec"; readonly machine: string; readonly command: string; readonly stdin: string | null; readonly timeoutMs: number }
  | { readonly op: "snapshot"; readonly machine: string; readonly name: string }
  | { readonly op: "destroy"; readonly machine: string }
  | { readonly op: "deleteSnapshot"; readonly snapshot: string }

/** `retryable`: the same call later may succeed (a provider call still running, a machine still binding). */
export type PlatformReply<T = unknown> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly code: string; readonly message: string; readonly retryable: boolean }

/** What a platform call needs of the team's CloudDO. */
export interface PlatformHost {
  readonly team: string
  readonly operations: PlatformOperations
  readonly now: number
  providerInfo(): PlatformProviderInfo
  /** Bind the engine and durably schedule continuation before recording a new operation. */
  arm(at: number): Promise<void>
  /** The user may use this team's machines now (personal team, or a member with team.resources). */
  mayUse(user: string): Promise<boolean>
  submit(principal: Principal, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin: "script" }): Promise<SubmitResult>
  machine(id: string): MachineRow | undefined
  /** A provider call for this machine (any op) is still pending in the team's ledger. */
  changing(id: string): boolean
  /** Authoritative provider resources; null/error never confirms a requested reservation. */
  resources(row: MachineRow): Promise<PlatformShape | null>
  ledger(key: string): LedgerRow | undefined
  snapshot(id: string): SnapshotRow | undefined
  /** Creation evidence: platform, non-platform, or unknown after the ledger was pruned. */
  platformSnapshot(user: string, id: string): boolean | undefined
  /** A completed platform snapshot delete retained in the ledger makes replay idempotent. */
  platformSnapshotDeleted(user: string, id: string): boolean
  tombstoned(machine: string): boolean
  /** One command on the machine's VM as root; null when the provider did not answer. */
  exec(row: MachineRow, command: string, stdin: Uint8Array | null, timeoutMs: number): Promise<GuestExecResult | null>
  audit(entry: Record<string, unknown>): void
}

export const platformPrincipal = (team: string, user: string): Principal => ({ identity: `${PLATFORM_IDENTITY_PREFIX}${user}`, kind: "session", user, team })
const key = (kind: "boot" | "snapshot" | "destroy" | "deleteSnapshot", name: string) => `platform-env:${kind}:${name}`
const machineKey = (kind: "pause" | "resume", machine: string, revision: string) => `platform-env:${kind}:${machine}:${revision}`
const sameShape = (a: PlatformShape, b: PlatformShape) => a.vcpu === b.vcpu && a.memGiB === b.memGiB && a.diskGiB === b.diskGiB
const ok = <T>(value: T): PlatformReply<T> => ({ ok: true, value })
export const refused = (code: string, message: string, retryable: boolean): PlatformReply<never> => ({ ok: false, code, message, retryable })
type Reply = { t: "result"; value?: any } | { t: "reject"; code: string; message: string; retryable?: boolean }
const replyOf = (r: SubmitResult) => r.frames.find((f: OwnerFrame) => f.t === "result" || f.t === "reject") as Reply | undefined
const fromReject = (r: Reply | undefined): PlatformReply<never> =>
  r?.t === "reject" ? refused(r.code, r.message, r.retryable === true) : refused("owner.unreachable", "no answer from the team's machines", true)

/** A failed or deleted machine never runs again; one still binding (or resuming) will. */
const notRunning = (m: MachineRow): PlatformReply<never> =>
  m.status === "failed" || m.status === "deleting"
    ? refused("cloud.machine.failed", m.error?.message ?? `the machine is ${m.status}`, false)
    : refused("cloud.machine.not_running", `the machine is ${m.status}`, true)

const snapshotReply = (s: SnapshotRow | undefined): PlatformReply<{ id: string }> =>
  s?.status === "ready"
    ? ok({ id: s.id })
    : s?.status === "creating"
      ? refused("mutation.indeterminate", "the snapshot is still being taken; retry with the same name", true)
      : refused("cloud.snapshot.failed", "the snapshot failed", false)

/** Resources are optional until the provider answers. Never turn an absent size into NaN. */
export const platformShape = (size: MachineRow["size"]): PlatformShape | null => {
  const { cpu, memory_mb, disk_mb } = size
  return typeof cpu === "number" && Number.isFinite(cpu) && cpu > 0 && typeof memory_mb === "number" && Number.isFinite(memory_mb) && memory_mb > 0 && typeof disk_mb === "number" && Number.isFinite(disk_mb) && disk_mb > 0
    ? { vcpu: cpu, memGiB: memory_mb / 1024, diskGiB: disk_mb / 1024 } : null
}
export const platformMetadata = (m: MachineRow): PlatformReply<PlatformMachine> => {
  if (m.transport === "vm-api") return refused("cloud.provider.unsupported", "this machine belongs to another provider transport", false)
  const shape = platformShape(m.size)
  if (!shape) return refused("cloud.machine.shape_unknown", "the provider has not reported the machine's resources yet", true)
  const state = m.status === "provisioning" || m.status === "starting" || m.status === "pausing" ? "starting" : m.status === "deleting" ? "stopped" : m.status
  return ok({ id: m.id, region: "global", state, shape })
}

export const platformCall = async (host: PlatformHost, user: string, call: PlatformCall, recoveryOnly = false): Promise<PlatformReply> => {
  // Find and delete reach only this user's own platform boots, and a delete only stops cost: both work
  // after the user lost access to the team, so a setup's cleanup always deletes its builder.
  const cleanup = call.op === "find" || call.op === "destroy" || call.op === "providerInfo" || call.op === "deleteSnapshot"
  if ((call.op === "create" || call.op === "fork") && (recoveryOnly || !host.providerInfo().available)) return host.operations.recover(host, user, call)
  if (!cleanup && !(await host.mayUse(user).catch(() => false))) {
    if (call.op === "create" || call.op === "fork") return host.operations.recover(host, user, call)
    return refused("auth.forbidden", "this user may not use the team's machines", false)
  }
  const p = platformPrincipal(host.team, user)
  const submit = (op: string, params: unknown, k: string) => host.submit(p, { t: "op", op, params, idempotency_key: k, origin: "script" }).then(replyOf)
  /** A machine this user's platform boots made, or a refusal (another person's machine is not found). */
  const own = (id: string): MachineRow | PlatformReply<never> => {
    const m = host.machine(id)
    return m && m.platform === true && m.creator === user ? m : refused("cloud.machine.not_found", "no such setup machine in this team", false)
  }
  switch (call.op) {
    case "providerInfo": return ok({ ...host.providerInfo(), ...(recoveryOnly ? { available: false } : {}) })
    case "create":
    case "fork": {
      if (!host.providerInfo().available) return refused("cloud.provider.unavailable", "the Freestyle provider is not configured on this deployment", false)
      return host.operations.request(host, user, call, host.now)
    }
    case "boot": {
      const k = key("boot", call.name)
      const r = await (call.snapshot ? submit("cloud.snapshot.restore", { snapshot: call.snapshot, name: PLATFORM_MACHINE_LABEL }, k) : submit("cloud.machine.create", { name: PLATFORM_MACHINE_LABEL, size: {} }, k))
      if (r?.t !== "result") return fromReject(r)
      const id = r.value?.machine?.id as string | undefined
      const m = id ? host.machine(id) : undefined
      // A replayed key answers its first result: the machine may have failed since.
      if (m && m.status === "failed") return notRunning(m)
      return id ? ok({ id }) : refused("owner.unreachable", "the boot answered no machine", true)
    }
    case "get": {
      const m = own(call.machine)
      if ("ok" in m) return m
      return host.operations.metadata(host, m.id)
    }
    case "shape": {
      const m = own(call.machine)
      if ("ok" in m) return m
      const metadata = await host.operations.metadata(host, m.id)
      return metadata.ok ? ok(metadata.value.shape) : metadata
    }
    case "pause":
    case "resume": {
      const m = own(call.machine)
      if ("ok" in m) return m
      if (host.operations.busy(host, m.id)) return refused("mutation.indeterminate", "the machine is still provisioning", true)
      if (m.transport === "vm-api") return refused("cloud.provider.unsupported", "this machine belongs to another provider transport", false)
      const wantPause = call.op === "pause"
      if (wantPause && m.status === "paused") return host.operations.metadata(host, m.id)
      if (!wantPause && m.status === "running") return host.operations.metadata(host, m.id)
      if ((wantPause && m.status === "pausing") || (!wantPause && m.status === "starting")) return refused("mutation.indeterminate", "the machine power change is still running; retry", true)
      const op = wantPause ? "cloud.machine.pause" : "cloud.machine.start"
      const k = machineKey(call.op, m.id, m.revision)
      const r = await submit(op, { machine: m.id }, k)
      const now = host.machine(m.id)
      if (now?.status === (wantPause ? "paused" : "running")) return host.operations.metadata(host, m.id)
      if (now?.status === (wantPause ? "pausing" : "starting")) return refused("mutation.indeterminate", "the machine power change is still running; retry", true)
      return r?.t === "reject" ? fromReject(r) : refused("cloud.provider.unavailable", "the machine power change did not settle", true)
    }
    case "resize": {
      const m = own(call.machine)
      if ("ok" in m) return m
      if (host.operations.busy(host, m.id)) return refused("mutation.indeterminate", "the machine is still provisioning", true)
      if (m.transport === "vm-api") return refused("cloud.provider.unsupported", "this machine belongs to another provider transport", false)
      // A boot's machine has no journal: it is provisioning, with nothing pending, until its VM binds.
      if (m.status === "provisioning") return refused("mutation.indeterminate", "the machine is still provisioning", true)
      // The provider's own answer decides "already there": the row takes the target size as soon as a
      // resize is accepted, so it cannot tell a finished grow from one still running.
      const actual = await host.resources(m).catch(() => null)
      if (actual && sameShape(actual, call.shape)) return host.operations.metadata(host, m.id)
      // A change still running answers here, before any intent: CloudDO runs one change per machine.
      const indeterminate = refused("mutation.indeterminate", "the machine change is still running; retry", true)
      if (host.changing(m.id)) return indeterminate
      // A fresh key per call, never one per revision: a refusal (grow_only, size.locked, not_running) is
      // recorded under its key, and a later call for another size or after a plan change must be decided
      // again. A duplicate grow cannot follow: the provider's shape and the one-change-per-machine rule
      // above answer every retry of an accepted resize.
      const k = `platform-env:resize:${m.id}:${crypto.randomUUID()}`
      const r = await submit("cloud.machine.resize", { machine: m.id, size: { cpu: call.shape.vcpu, memory_mb: call.shape.memGiB * 1024, disk_mb: call.shape.diskGiB * 1024 } }, k)
      // The ledger first: submit answers a failed provider call with a generic cloud.provider.unavailable,
      // while the ledger keeps the provider's own code (cloud.provider.refused, say).
      const l = host.ledger(ledgerKey(p.identity, k))
      if (l?.state === "pending") return indeterminate
      if (l?.state === "done") return host.operations.metadata(host, m.id)
      if (l) return refused(l.error?.code ?? "cloud.provider.unavailable", l.error?.message ?? "the machine resize failed", false)
      if (r?.t === "reject") return r.code === "cloud.machine.busy" ? indeterminate : fromReject(r)
      return r?.t === "result" ? indeterminate : fromReject(r)
    }
    case "find": {
      const l = host.ledger(ledgerKey(p.identity, key("boot", call.name)))
      const m = l?.op === "create" ? host.machine(l.machine) : undefined
      return ok(m ? { id: m.id } : null)
    }
    case "exec": {
      const m = own(call.machine)
      if ("ok" in m) return m
      if (host.operations.busy(host, m.id)) return refused("mutation.indeterminate", "the machine is still provisioning", true)
      if (m.status !== "running") return notRunning(m)
      const stdin = call.stdin ? new TextEncoder().encode(call.stdin) : null
      let r: GuestExecResult | null
      try {
        r = await host.exec(m, asWorkUser(call.command), stdin, Math.min(Math.max(1, call.timeoutMs), PLATFORM_EXEC_MAX_MS))
      } catch (error) {
        if (!(error instanceof DriverError) || error.code !== "cloud.exec.output_limit") throw error
        host.audit({ action: "platform.exec", machine: m.id, who: p.identity, at: Date.now(), outcome: "output_limit" })
        return refused("cloud.exec.output_limit", "the command's output exceeded the response limit; its output was discarded", false)
      }
      // Never the command or its stdin (a repository token may be on it).
      host.audit({ action: "platform.exec", machine: m.id, who: p.identity, at: Date.now(), outcome: r ? `exit ${r.exitCode}` : "provider_failed" })
      return r ? ok({ exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr }) : refused("cloud.provider.unavailable", "the machine did not answer", true)
    }
    case "snapshot": {
      const k = key("snapshot", call.name)
      const m = own(call.machine)
      if ("ok" in m) {
        // Its machine may be gone since the snapshot was taken: the snapshot's own ledger row still answers.
        const l = host.ledger(ledgerKey(p.identity, k))
        return l?.op === "snapshot" && l.machine === call.machine && l.snapshot ? snapshotReply(host.snapshot(l.snapshot)) : m
      }
      const r = await submit("cloud.snapshot.create", { machine: m.id, name: PLATFORM_MACHINE_LABEL }, k)
      if (r?.t !== "result") return fromReject(r)
      const id = r.value?.snapshot?.id as string | undefined
      // The answer is the intent's (creating); the row says where the provider call got to.
      return snapshotReply(id ? host.snapshot(id) : undefined)
    }
    case "destroy": {
      if (host.tombstoned(call.machine)) return ok({ deleted: true })
      const m = host.machine(call.machine)
      if (!m) return ok({ deleted: true })
      const mine = own(call.machine)
      if ("ok" in mine) return mine
      host.operations.cancel(host, m.id, host.now)
      // Deleted only once the machine is gone (its tombstone): a delete still running is asked again.
      const deleting = refused("mutation.indeterminate", "the machine is still being deleted; retry", true)
      if (m.status === "deleting") return deleting
      // One intent per machine revision: a delete that failed for good changed the row, so the next call
      // starts a new delete instead of replaying the failed one (the builder must not keep running).
      const r = await submit("cloud.machine.delete", { machine: m.id }, key("destroy", `${m.id}:${m.revision}`))
      if (host.tombstoned(m.id) || !host.machine(m.id)) return ok({ deleted: true })
      if (r?.t === "result") return deleting
      return r?.t === "reject" ? refused(r.code, r.message, true) : fromReject(r)
    }
    case "deleteSnapshot": {
      const snap = host.snapshot(call.snapshot)
      if (!snap && host.platformSnapshotDeleted(user, call.snapshot)) return ok({ deleted: true })
      // A missing row is either a successful prior delete or a snapshot this team cannot see.
      // cmux-platform treats cloud.snapshot.not_found as successful cleanup.
      if (!snap || snap.creator !== user) return refused("cloud.snapshot.not_found", "no such platform snapshot in this team", false)
      if (snap.platform !== true) {
        const platform = host.platformSnapshot(user, snap.id)
        if (platform === false) return refused("cloud.snapshot.not_found", "no such platform snapshot in this team", false)
        // Old pruning may have removed the creation evidence before the marker existed. The row
        // still reserves a snapshot: never report cleanup complete without proving its origin.
        if (platform === undefined) return refused("cloud.snapshot.ownership_unknown", "platform snapshot ownership needs reconciliation; retry later", true)
      }
      const deleting = refused("mutation.indeterminate", "the snapshot is still being deleted; retry", true)
      if (snap.status === "deleting") return deleting
      // Like destroy, a terminal failure restores the row at a new revision. The next request
      // starts a new intent, while concurrent requests for this revision share the same one.
      const r = await submit("cloud.snapshot.delete", { snapshot: snap.id }, key("deleteSnapshot", `${snap.id}:${snap.revision}`))
      if (!host.snapshot(snap.id)) return ok({ deleted: true })
      return r?.t === "result" ? deleting : r?.t === "reject" ? refused(r.code, r.message, true) : fromReject(r)
    }
  }
}
