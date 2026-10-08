import type { OwnerFrame } from "@cmux/ownership"
import { currentTaint, pausingRetired, taintBlocks, type TeamVmTaint } from "./domains/team-vm-taint.ts"
import type { TeamVmState } from "./domains/team-vm.ts"
import { DriverError, type TeamVmDriver } from "./team-vm-driver.ts"

/**
 * TeamVmDO's side of the taint (cx-q4f3, domains/team-vm-taint.ts): the owner actions TeamDO
 * forwards after its owner/admin check, and pausing the VMs a rebuild retired.
 */
export interface TaintRunDeps {
  readonly state: () => TeamVmState | undefined
  readonly driver: () => TeamVmDriver | null
  /** Why this deployment may not call the provider (production plan gate), else null. */
  readonly refusal: () => string | null
  readonly submitSystem: (op: string, params: unknown, key: string) => { frames: ReadonlyArray<OwnerFrame> }
  /** The DO's ledger-checked delete (never the current VM). */
  readonly deleteVm: (id: string, by: string) => Promise<{ ok: true } | { ok: false; code: string; message: string }>
  /** Runs the pending provider calls (the rebuild's create). */
  readonly reconcile: () => Promise<void>
}

export type AdminRequest =
  | { readonly action: "accept"; readonly by: string; readonly epoch: number; readonly users: ReadonlyArray<string>; readonly key: string }
  | { readonly action: "rebuild"; readonly by: string; readonly epoch: number; readonly key: string }
  | { readonly action: "delete"; readonly by: string; readonly vm: string; readonly key: string }

export type AdminReply = { ok: true; value: Record<string, unknown>; tainted_by: ReadonlyArray<string>; epoch: number } | { ok: false; code: string; message: string }

/** What TeamDO's certificate issue needs: whether the taint blocks members, and whom it names. */
export interface TaintSummary {
  readonly blocks: boolean
  readonly taint: TeamVmTaint | null
}

export const taintSummary = (s: TeamVmState): TaintSummary => {
  if (taintBlocks(s)) return { blocks: true, taint: currentTaint(s) }
  // A rebuilt VM still running until the provider confirms its pause blocks like its taint did.
  const r = pausingRetired(s)
  return r ? { blocks: true, taint: { epoch: r.epoch, at: r.at, users: r.tainted_by, accepted_by: null, accepted_at: null } } : { blocks: false, taint: currentTaint(s) }
}

const outcome = (frames: ReadonlyArray<OwnerFrame>): { ok: true; value: Record<string, unknown> } | { ok: false; code: string; message: string } => {
  const f = frames.find((x) => x.t === "result" || x.t === "reject")
  if (!f) return { ok: false, code: "owner.unreachable", message: "no answer from the team VM record" }
  if (f.t === "reject") return { ok: false, code: f.code, message: f.message }
  return { ok: true, value: (f.t === "result" ? f.value : {}) as Record<string, unknown> }
}

export const adminAction = async (d: TaintRunDeps, req: AdminRequest): Promise<AdminReply> => {
  const s = d.state()
  if (!s) return { ok: false, code: "owner.unreachable", message: "team VM record not open" }
  const taintedBy = currentTaint(s)?.users ?? []
  if (req.action === "accept") {
    const r = outcome(d.submitSystem("team_vm.taint_accepted", { epoch: req.epoch, users: req.users, by: req.by }, `taint-accept:${req.key}`).frames)
    return r.ok ? { ...r, tainted_by: taintedBy, epoch: req.epoch } : r
  }
  if (req.action === "rebuild") {
    // Without a provider the new VM cannot be made nor the old one paused: refuse before anything changes.
    const refused = d.refusal() ?? (d.driver() ? null : "team_vm.not_configured")
    if (refused) return { ok: false, code: refused, message: "no team VM provider is available on this deployment" }
    const r = outcome(d.submitSystem("team_vm.rebuild_requested", { epoch: req.epoch, by: req.by }, `rebuild:${req.key}`).frames)
    if (!r.ok) return r
    // The new VM is created now; the alarm finishes a slow provider. The old one is paused next.
    await d.reconcile()
    await pauseRetired(d)
    return { ...r, tainted_by: taintedBy, epoch: req.epoch }
  }
  const row = (s.retired ?? []).find((x) => x.vm === req.vm)
  if (!row) return { ok: false, code: "selector.not_found", message: "no retired team VM with this id" }
  const del = await d.deleteVm(row.vm, req.by)
  if (!del.ok) return del
  const r = outcome(d.submitSystem("team_vm.retired_deleted", { vm: row.vm }, `retired-delete:${row.vm}`).frames)
  return r.ok ? { ok: true, value: { vm: row.vm, deleted: true }, tainted_by: row.tainted_by, epoch: row.epoch } : r
}

/** Pauses every retired VM due for a try; a failure is committed and retried by the alarm with backoff. */
export const pauseRetired = async (d: TaintRunDeps, now: number = Date.now()): Promise<void> => {
  const due = (d.state()?.retired ?? []).filter((r) => r.state === "pausing" && (r.pause_retry_at ?? r.at) <= now)
  if (due.length === 0) return
  const driver = d.driver()
  for (const r of due) {
    const attempt = r.pause_attempts ?? 0
    try {
      if (!driver) throw new DriverError("team_vm.not_configured", "no team VM provider", false)
      await driver.pauseVm(r.vm)
    } catch (e) {
      // A VM deleted outside cmux is as good as paused: nothing of it runs.
      if (!(e instanceof DriverError && e.code === "team_vm.vm_missing")) {
        console.warn(JSON.stringify({ msg: "team vm retired pause failed", vm: r.vm, attempt: attempt + 1, error: e instanceof DriverError ? e.code : String(e) }))
        d.submitSystem("team_vm.retired_pause_failed", { vm: r.vm }, `retired-pause-failed:${r.vm}:${attempt}`)
        continue
      }
    }
    d.submitSystem("team_vm.retired_paused", { vm: r.vm }, `retired-paused:${r.vm}`)
  }
}
