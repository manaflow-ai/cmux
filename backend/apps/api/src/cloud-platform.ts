import type { OwnerFrame, Principal } from "@cmux/ownership"
import type { SubmitResult } from "./owner-do.ts"
import { asWorkUser } from "./cloud-env-sandbox.ts"
import type { GuestExecResult } from "./providers/contract.ts"
import { ledgerKey, PLATFORM_IDENTITY_PREFIX, type LedgerRow, type MachineRow } from "./domains/cloud.ts"
import type { SnapshotRow } from "./domains/cloud-snapshot.ts"

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
 * not, so cleanup outlives a departure. Exec, snapshot and delete reach only machines a platform boot
 * of the same user made (the row's `platform` flag), never a person's own machine. Exec runs as the
 * image's work user, never root.
 */

/** Shown in the team's machine and snapshot lists. */
export const PLATFORM_MACHINE_LABEL = "Environment setup"
/** One exec answers within the provider's own limit (automation steps use the same). */
export const PLATFORM_EXEC_MAX_MS = 300_000

export type PlatformCall =
  | { readonly op: "boot"; readonly name: string; readonly snapshot?: string; readonly shape?: { readonly vcpu: number; readonly memGiB: number; readonly diskGiB: number } }
  | { readonly op: "find"; readonly name: string }
  | { readonly op: "get"; readonly machine: string }
  | { readonly op: "shape"; readonly machine: string }
  | { readonly op: "pause"; readonly machine: string }
  | { readonly op: "resume"; readonly machine: string }
  | { readonly op: "fork"; readonly machine: string; readonly name: string }
  | { readonly op: "exec"; readonly machine: string; readonly command: string; readonly stdin: string | null; readonly timeoutMs: number }
  | { readonly op: "snapshot"; readonly machine: string; readonly name: string }
  | { readonly op: "destroy"; readonly machine: string }

/** `retryable`: the same call later may succeed (a provider call still running, a machine still binding). */
export type PlatformReply<T = unknown> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly code: string; readonly message: string; readonly retryable: boolean }

/** What a platform call needs of the team's CloudDO. */
export interface PlatformHost {
  readonly team: string
  /** The user may use this team's machines now (personal team, or a member with team.resources). */
  mayUse(user: string): Promise<boolean>
  submit(principal: Principal, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin: "script" }): Promise<SubmitResult>
  machine(id: string): MachineRow | undefined
  ledger(key: string): LedgerRow | undefined
  snapshot(id: string): SnapshotRow | undefined
  tombstoned(machine: string): boolean
  /** One command on the machine's VM as root; null when the provider did not answer. */
  exec(row: MachineRow, command: string, stdin: Uint8Array | null, timeoutMs: number): Promise<GuestExecResult | null>
  audit(entry: Record<string, unknown>): void
}

export const platformPrincipal = (team: string, user: string): Principal => ({ identity: `${PLATFORM_IDENTITY_PREFIX}${user}`, kind: "session", user, team })
const key = (kind: "boot" | "snapshot" | "destroy", name: string) => `platform-env:${kind}:${name}`
const machineKey = (kind: "pause" | "resume", machine: string, revision: string) => `platform-env:${kind}:${machine}:${revision}`
const forkKey = (kind: "snapshot" | "restore" | "cleanup", name: string) => `platform-env:fork:${kind}:${name}`
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

export const platformCall = async (host: PlatformHost, user: string, call: PlatformCall): Promise<PlatformReply> => {
  // Find and delete reach only this user's own platform boots, and a delete only stops cost: both work
  // after the user lost access to the team, so a setup's cleanup always deletes its builder.
  const cleanup = call.op === "find" || call.op === "destroy"
  if (!cleanup && !(await host.mayUse(user).catch(() => false))) return refused("auth.forbidden", "this user may not use the team's machines", false)
  const p = platformPrincipal(host.team, user)
  const submit = (op: string, params: unknown, k: string) => host.submit(p, { t: "op", op, params, idempotency_key: k, origin: "script" }).then(replyOf)
  /** A machine this user's platform boots made, or a refusal (another person's machine is not found). */
  const own = (id: string): MachineRow | PlatformReply<never> => {
    const m = host.machine(id)
    return m && m.platform === true && m.creator === user ? m : refused("cloud.machine.not_found", "no such setup machine in this team", false)
  }
  switch (call.op) {
    case "boot": {
      const k = key("boot", call.name)
      const size = call.shape ? { cpu: call.shape.vcpu, memory_mb: call.shape.memGiB * 1024, disk_mb: call.shape.diskGiB * 1024 } : {}
      const r = await (call.snapshot ? submit("cloud.snapshot.restore", { snapshot: call.snapshot, name: PLATFORM_MACHINE_LABEL }, k) : submit("cloud.machine.create", { name: PLATFORM_MACHINE_LABEL, size }, k))
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
      if (m.status === "failed" || m.status === "deleting") return notRunning(m)
      return ok({ id: m.id, state: m.status, region: "global" })
    }
    case "shape": {
      const m = own(call.machine)
      if ("ok" in m) return m
      return ok({ vcpu: m.size.cpu, memGiB: m.size.memory_mb / 1024, diskGiB: m.size.disk_mb / 1024 })
    }
    case "pause":
    case "resume": {
      const m = own(call.machine)
      if ("ok" in m) return m
      const wantPause = call.op === "pause"
      if (wantPause && m.status === "paused") return ok({ id: m.id })
      if (!wantPause && m.status === "running") return ok({ id: m.id })
      if ((wantPause && m.status === "pausing") || (!wantPause && m.status === "starting")) return refused("mutation.indeterminate", "the machine power change is still running; retry", true)
      const op = wantPause ? "cloud.machine.pause" : "cloud.machine.start"
      const k = machineKey(call.op, m.id, m.revision)
      const r = await submit(op, { machine: m.id }, k)
      const now = host.machine(m.id)
      if (now?.status === (wantPause ? "paused" : "running")) return ok({ id: m.id })
      if (now?.status === (wantPause ? "pausing" : "starting")) return refused("mutation.indeterminate", "the machine power change is still running; retry", true)
      return r?.t === "reject" ? fromReject(r) : refused("cloud.provider.unavailable", "the machine power change did not settle", true)
    }
    case "fork": {
      const source = own(call.machine)
      if ("ok" in source) return source
      if (source.status !== "running" && source.status !== "paused") return notRunning(source)
      const sk = ledgerKey(p.identity, forkKey("snapshot", call.name))
      let snapshot = host.ledger(sk)?.row.snapshot ? host.snapshot(host.ledger(sk)!.row.snapshot!) : undefined
      if (!snapshot) {
        const created = await submit("cloud.snapshot.create", { machine: source.id, name: PLATFORM_MACHINE_LABEL }, forkKey("snapshot", call.name))
        const l = host.ledger(sk)
        snapshot = l?.row.snapshot ? host.snapshot(l.row.snapshot) : undefined
        if (created?.t !== "result" && !snapshot) return fromReject(created)
      }
      if (snapshot && snapshot.machine !== source.id) return refused("idempotency.conflict", "this fork name already belongs to another source machine", false)
      if (!snapshot || snapshot.status !== "ready") return refused("mutation.indeterminate", "the fork snapshot is still being taken; retry", true)
      const childKey = ledgerKey(p.identity, forkKey("restore", call.name))
      const existing = host.ledger(childKey)?.row
      if (!existing) {
        const restored = await submit("cloud.snapshot.restore", { snapshot: snapshot.id, name: PLATFORM_MACHINE_LABEL }, forkKey("restore", call.name))
        if (restored?.t !== "result") return fromReject(restored)
      }
      const child = host.ledger(childKey)?.row
      const childMachine = child ? host.machine(child.machine) : undefined
      if (!childMachine) return refused("mutation.indeterminate", "the fork machine is still starting; retry", true)
      const deleted = await submit("cloud.snapshot.delete", { snapshot: snapshot.id }, forkKey("cleanup", `${call.name}:${snapshot.revision}`))
      if (host.snapshot(snapshot.id)) return refused("mutation.indeterminate", "the fork snapshot cleanup is still running; retry", true)
      if (deleted?.t !== "result") return fromReject(deleted)
      return ok({ id: childMachine.id })
    }
    case "find": {
      const l = host.ledger(ledgerKey(p.identity, key("boot", call.name)))
      const m = l?.op === "create" ? host.machine(l.machine) : undefined
      return ok(m ? { id: m.id } : null)
    }
    case "exec": {
      const m = own(call.machine)
      if ("ok" in m) return m
      if (m.status !== "running") return notRunning(m)
      const stdin = call.stdin ? new TextEncoder().encode(call.stdin) : null
      const r = await host.exec(m, asWorkUser(call.command), stdin, Math.min(Math.max(1, call.timeoutMs), PLATFORM_EXEC_MAX_MS))
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
  }
}
