import type { ReduceContext, ReduceResult, RowWrite, StoredRow } from "@cmux/ownership"
import { CloudMachinePause, CloudMachineResize, CloudMachineStart, planRequiredDetails, type CloudDriverResultParams } from "@cmux/protocol"
import { decodeParams, reject } from "./common.ts"
import { DEFAULT_SIZE, limitDetails, sizeLocked, teamPlan, type CloudConfig, DEFAULT_MEMORY_MB } from "./cloud-plan.ts"
import {
  countedRow,
  ledgerKey,
  machineRow,
  mayManage,
  next,
  noChangePower,
  PENDING_SAFETY_MS,
  publicMachine,
  unavailable,
  upsertLedger,
  upsertMachine,
  withoutPending,
  type CloudState,
  type LedgerRow,
  type MachineRow
} from "./cloud.ts"

/**
 * cloud.machine.pause and cloud.machine.start (state-placement.md 7 item 4; CLOUDDO-MONEY-OPS: a
 * signed-in person, the team allowlist and plan, the environment's name prefix, ledger first, the
 * per-team rate limit). The intent commits its ledger row and the transient status (pausing,
 * starting); CloudDO runs the provider call (Freestyle POST /v5/vms/{id}/pause or /start) and commits
 * the outcome. Pause frees an active slot when it lands; start takes one at once (quota at intent).
 * A final failure returns the machine to where it was, with the error.
 */
export const powerIntent = (config: CloudConfig, state: CloudState, op: "cloud.machine.pause" | "cloud.machine.start", params: unknown, ctx: ReduceContext, system = false, reason: "idle" | "no_report" | null = null): ReduceResult<CloudState> => {
  const pause = op === "cloud.machine.pause"
  const d = decodeParams<{ machine: string }>(pause ? CloudMachinePause : CloudMachineStart, params)
  if (!d.ok) return d
  const stored = machineRow(ctx.rows, d.value.machine)
  if (!stored) return reject("cloud.machine.not_found", "no such machine in this team")
  const m = stored.row
  // The idle pause (system, cloud.machine.idle_pause) acts for the team policy, not for a person.
  if (!system && !mayManage(ctx.principal, m)) return reject("auth.forbidden", "only the machine's creator or a team admin may pause or start it")
  // A call already running for this machine answers the machine as it is (no second ledger row).
  if ((pause && m.status === "pausing") || (!pause && m.status === "starting")) return noChangePower(state, { machine: publicMachine(m) })
  if (pause && m.status !== "running") return reject("cloud.machine.not_running", "only a running machine can be paused", { machine: m.id, state: m.status })
  if (!pause && m.status !== "paused") return reject("cloud.machine.not_paused", "only a paused machine can be started", { machine: m.id, state: m.status })
  if (!config.prefix || !ctx.idempotencyKey) return unavailable()
  if (!pause) {
    const plan = teamPlan(config, state.team ?? ctx.principal.team)
    if (!plan) return reject("cloud.plan.required", "Cloud machines need a paid plan", planRequiredDetails())
    if (state.active >= plan.max_active) return reject("cloud.quota.exceeded", `this plan allows ${plan.max_active} active machines`, limitDetails(plan, { limit: plan.max_active, used: state.active, resource: "active" }))
  }
  const rev = state.rev + 1
  const key = ledgerKey(ctx.principal.identity, ctx.idempotencyKey)
  const ledger: LedgerRow = { key, op: pause ? "pause" : "start", machine: m.id, provider_name: m.provider_name, state: "pending", provider_id: null, attempts: 0, error: null, created_at: ctx.now, updated_at: ctx.now }
  // pause_reason: why cmux paused it by itself (for the app); a person's pause or a start clears it.
  const row: MachineRow = { ...m, status: pause ? "pausing" : "starting", error: null, revision: String(rev), pause_reason: pause && system ? reason : null, ...(pause ? {} : { last_power_at: ctx.now }) }
  const writes: Array<RowWrite> = [upsertLedger(ledger, rev), upsertMachine(row, stored.n)]
  const active = state.active - countedRow(m) + countedRow(row)
  const s = next(state, { active, pending: { ...state.pending, [key]: { machine: m.id, due_at: ctx.now + PENDING_SAFETY_MS } } }, { machine: m.id, removed: false })
  return { ok: true, state: s, value: { machine: publicMachine(row) }, writes }
}

/**
 * cloud.machine.resize: grow only on every axis (Freestyle grows vCPU and memory live or on resume,
 * the disk only on a running VM), within the plan. The answer carries the target size; the ledger
 * row keeps the old size, restored after a final failure. One resize at a time per machine.
 */
export const resizeIntent = (config: CloudConfig, state: CloudState, params: unknown, ctx: ReduceContext): ReduceResult<CloudState> => {
  const d = decodeParams<typeof CloudMachineResize.params.Type>(CloudMachineResize, params)
  if (!d.ok) return d
  const stored = machineRow(ctx.rows, d.value.machine)
  if (!stored) return reject("cloud.machine.not_found", "no such machine in this team")
  const m = stored.row
  if (!mayManage(ctx.principal, m)) return reject("auth.forbidden", "only the machine's creator or a team admin may resize it")
  if (m.status !== "running" && m.status !== "paused") return reject("cloud.machine.not_running", "only a running or paused machine can be resized", { machine: m.id, state: m.status })
  const busy = Object.entries(state.pending).some(([, e]) => e.machine === m.id)
  if (busy) return reject("cloud.machine.busy", "another change of this machine is still running; retry when it lands", { machine: m.id })
  const cur = { cpu: m.size.cpu ?? DEFAULT_SIZE.cpu, memory_mb: m.size.memory_mb ?? DEFAULT_MEMORY_MB, disk_mb: m.size.disk_mb ?? DEFAULT_SIZE.disk_mb }
  const target = { cpu: d.value.size.cpu ?? cur.cpu, memory_mb: d.value.size.memory_mb ?? cur.memory_mb, disk_mb: d.value.size.disk_mb ?? cur.disk_mb }
  if (target.cpu < cur.cpu || target.memory_mb < cur.memory_mb || target.disk_mb < cur.disk_mb) return reject("cloud.size.grow_only", "a machine can only grow (vCPU, memory and disk)", { size: cur })
  if (target.disk_mb > cur.disk_mb && m.status !== "running") return reject("cloud.machine.not_running", "the disk grows only on a running machine", { machine: m.id, state: m.status })
  const plan = teamPlan(config, state.team ?? ctx.principal.team)
  if (!plan) return reject("cloud.plan.required", "Cloud machines need a paid plan", planRequiredDetails())
  if (sizeLocked(plan, target.memory_mb)) return reject("cloud.size.locked", "this size needs another plan", limitDetails(plan, { memory_mb: target.memory_mb }))
  if (target.cpu > plan.max_cpu) return reject("cloud.size.locked", "this size needs another plan", limitDetails(plan, { cpu: target.cpu }))
  if (target.disk_mb > plan.max_disk_mb) return reject("cloud.size.locked", "this size needs another plan", limitDetails(plan, { disk_mb: target.disk_mb }))
  if (!config.prefix || !ctx.idempotencyKey) return unavailable()
  const rev = state.rev + 1
  const key = ledgerKey(ctx.principal.identity, ctx.idempotencyKey)
  const ledger: LedgerRow = { key, op: "resize", machine: m.id, provider_name: m.provider_name, state: "pending", provider_id: null, attempts: 0, error: null, created_at: ctx.now, updated_at: ctx.now, size: target, size_before: cur }
  const row: MachineRow = { ...m, size: target, error: null, revision: String(rev) }
  const s = next(state, { pending: { ...state.pending, [key]: { machine: m.id, due_at: ctx.now + PENDING_SAFETY_MS } } }, { machine: m.id, removed: false })
  return { ok: true, state: s, value: { machine: publicMachine(row) }, writes: [upsertLedger(ledger, rev), upsertMachine(row, stored.n)] }
}

/** The outcome of a pause or start call: success lands the new status; a final failure returns the machine to its old status. */
export const powerResult = (state: CloudState, stored: StoredRow<LedgerRow>, machine: StoredRow<MachineRow> | undefined, r: typeof CloudDriverResultParams.Type, ctx: ReduceContext): ReduceResult<CloudState> => {
  const l = stored.row
  const pending = withoutPending(state, l.key)
  const error = r.ok ? null : { code: r.error?.code ?? "cloud.provider.unavailable", message: r.error?.message ?? "provider call failed" }
  const writes: Array<RowWrite> = [upsertLedger({ ...l, state: r.ok ? "done" : "failed", attempts: l.attempts + 1, error, updated_at: ctx.now }, stored.n)]
  if (l.op === "resize") {
    // Success: the size is already the target. A final failure restores the old size (unless the machine is gone or deleting).
    if (r.ok || !machine || machine.row.status === "deleting" || !l.size_before) return { ok: true, state: next(state, { pending }), value: { applied: true }, writes }
    // The VM's real size after the failure (a partial resize), else the old size (review P3).
    const restored: MachineRow = { ...machine.row, size: r.resources ?? l.size_before, error: error ? { ...error, at: ctx.now } : null, revision: String(state.rev + 1) }
    writes.push(upsertMachine(restored, machine.n))
    return { ok: true, state: next(state, { pending }, { machine: restored.id, removed: false }), value: { applied: true, final: true }, writes }
  }
  // The machine moved on meanwhile (a delete): the call is settled, the machine stays as it is.
  const expected = l.op === "pause" ? "pausing" : "starting"
  if (!machine || machine.row.status !== expected) return { ok: true, state: next(state, { pending }), value: { applied: true }, writes }
  // The VM is gone (review P3): the machine is failed (its VM install is revoked), never paused forever.
  const status = r.ok ? (l.op === "pause" ? "paused" : "running") : error?.code === "cloud.provider.vm_missing" ? "failed" : l.op === "pause" ? "running" : "paused"
  const rev = state.rev + 1
  const row: MachineRow = { ...machine.row, status, error: error ? { ...error, at: ctx.now } : null, revision: String(rev) }
  writes.push(upsertMachine(row, machine.n))
  const active = state.active - countedRow(machine.row) + countedRow(row)
  return { ok: true, state: next(state, { pending, active }, { machine: row.id, removed: false }), value: { applied: true, final: true }, writes }
}

/**
 * `cloud.machine.provider_state` (internal): connect_info or link_token read the VM's real state and it
 * is not what a running record says. A stopped or paused VM is recorded paused (the person starts it);
 * a VM that is gone is recorded failed (its VM install is then revoked).
 */
export const providerStateResult = (state: CloudState, params: unknown, ctx: ReduceContext): ReduceResult<CloudState> => {
  const p = (params ?? {}) as { machine?: unknown; state?: unknown }
  if (typeof p.machine !== "string") return reject("validation.invalid", "invalid provider state")
  const stored = machineRow(ctx.rows, p.machine)
  if (!stored || stored.row.status !== "running") return noChangePower(state, { applied: false })
  const vm = typeof p.state === "string" ? p.state : null
  if (vm === "running" || vm === "starting") return noChangePower(state, { applied: false })
  const rev = state.rev + 1
  const row: MachineRow =
    vm === null
      ? { ...stored.row, status: "failed", error: { code: "cloud.provider.vm_missing", message: "the VM is gone", at: ctx.now }, revision: String(rev) }
      : { ...stored.row, status: "paused", pause_reason: vm === "stopped" ? "provider_stopped" : "provider_paused", revision: String(rev) }
  const active = state.active - countedRow(stored.row) + countedRow(row)
  return { ok: true, state: next(state, { active }, { machine: row.id, removed: false }), value: { applied: true }, writes: [upsertMachine(row, stored.n)] }
}
