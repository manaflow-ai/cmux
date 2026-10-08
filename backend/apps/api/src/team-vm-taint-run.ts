import type { OwnerFrame } from "@cmux/ownership"
import { currentTaint, taintBlocks, type TeamVmTaint } from "./domains/team-vm-taint.ts"
import type { TeamVmState } from "./domains/team-vm.ts"
import { DriverError, type TeamVmDriver } from "./team-vm-driver.ts"

/**
 * TeamVmDO's side of the taint (cx-q4f3, domains/team-vm-taint.ts): the owner actions TeamDO
 * forwards after its owner/admin check, and pausing the VMs a rebuild retired.
 */
export interface TaintRunDeps {
  readonly state: () => TeamVmState | undefined
  readonly driver: () => TeamVmDriver | null
  readonly submitSystem: (op: string, params: unknown, key: string) => { frames: ReadonlyArray<OwnerFrame> }
  /** The DO's ledger-checked delete (never the current VM). */
  readonly deleteVm: (id: string, by: string) => Promise<{ ok: true } | { ok: false; code: string; message: string }>
  /** Runs the pending provider calls (the rebuild's create). */
  readonly reconcile: () => Promise<void>
}

export type AdminRequest =
  | { readonly action: "accept"; readonly by: string; readonly epoch: number; readonly key: string }
  | { readonly action: "rebuild"; readonly by: string; readonly epoch: number; readonly key: string }
  | { readonly action: "delete"; readonly by: string; readonly vm: string; readonly key: string }

export type AdminReply = { ok: true; value: Record<string, unknown>; tainted_by: ReadonlyArray<string>; epoch: number } | { ok: false; code: string; message: string }

/** What TeamDO's certificate issue needs: whether the taint blocks members, and whom it names. */
export interface TaintSummary {
  readonly blocks: boolean
  readonly taint: TeamVmTaint | null
}

export const taintSummary = (s: TeamVmState): TaintSummary => ({ blocks: taintBlocks(s), taint: currentTaint(s) })

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
    const r = outcome(d.submitSystem("team_vm.taint_accepted", { epoch: req.epoch, by: req.by }, `taint-accept:${req.key}`).frames)
    return r.ok ? { ...r, tainted_by: taintedBy, epoch: req.epoch } : r
  }
  if (req.action === "rebuild") {
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

/** Pauses every retired VM the provider has not paused yet; a failure is retried by the alarm. */
export const pauseRetired = async (d: TaintRunDeps): Promise<void> => {
  const pausing = (d.state()?.retired ?? []).filter((r) => r.state === "pausing")
  if (pausing.length === 0) return
  const driver = d.driver()
  if (!driver) return
  for (const r of pausing) {
    try {
      await driver.pauseVm(r.vm)
    } catch (e) {
      // A VM deleted outside cmux is as good as paused: nothing of it runs.
      if (!(e instanceof DriverError && e.code === "team_vm.vm_missing")) {
        console.warn(JSON.stringify({ msg: "team vm retired pause failed", vm: r.vm, error: String(e) }))
        continue
      }
    }
    d.submitSystem("team_vm.retired_paused", { vm: r.vm }, `retired-paused:${r.vm}`)
  }
}
