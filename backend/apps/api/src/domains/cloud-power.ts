import type { ReduceContext, ReduceResult, RowWrite, StoredRow } from "@cmux/ownership"
import { CloudMachinePause, CloudMachineStart, planRequiredDetails, type CloudDriverResultParams } from "@cmux/protocol"
import { decodeParams, reject } from "./common.ts"
import { limitDetails, teamPlan, type CloudConfig } from "./cloud-plan.ts"
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
export const powerIntent = (config: CloudConfig, state: CloudState, op: "cloud.machine.pause" | "cloud.machine.start", params: unknown, ctx: ReduceContext): ReduceResult<CloudState> => {
  const pause = op === "cloud.machine.pause"
  const d = decodeParams<{ machine: string }>(pause ? CloudMachinePause : CloudMachineStart, params)
  if (!d.ok) return d
  const stored = machineRow(ctx.rows, d.value.machine)
  if (!stored) return reject("cloud.machine.not_found", "no such machine in this team")
  const m = stored.row
  if (!mayManage(ctx.principal, m)) return reject("auth.forbidden", "only the machine's creator or a team admin may pause or start it")
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
  const row: MachineRow = { ...m, status: pause ? "pausing" : "starting", error: null, revision: String(rev) }
  const writes: Array<RowWrite> = [upsertLedger(ledger, rev), upsertMachine(row, stored.n)]
  const active = state.active - countedRow(m) + countedRow(row)
  const s = next(state, { active, pending: { ...state.pending, [key]: { machine: m.id, due_at: ctx.now + PENDING_SAFETY_MS } } }, { machine: m.id, removed: false })
  return { ok: true, state: s, value: { machine: publicMachine(row) }, writes }
}

/** The outcome of a pause or start call: success lands the new status; a final failure returns the machine to its old status. */
export const powerResult = (state: CloudState, stored: StoredRow<LedgerRow>, machine: StoredRow<MachineRow> | undefined, r: typeof CloudDriverResultParams.Type, ctx: ReduceContext): ReduceResult<CloudState> => {
  const l = stored.row
  const pending = withoutPending(state, l.key)
  const error = r.ok ? null : { code: r.error?.code ?? "cloud.provider.unavailable", message: r.error?.message ?? "provider call failed" }
  const writes: Array<RowWrite> = [upsertLedger({ ...l, state: r.ok ? "done" : "failed", attempts: l.attempts + 1, error, updated_at: ctx.now }, stored.n)]
  // The machine moved on meanwhile (a delete): the call is settled, the machine stays as it is.
  const expected = l.op === "pause" ? "pausing" : "starting"
  if (!machine || machine.row.status !== expected) return { ok: true, state: next(state, { pending }), value: { applied: true }, writes }
  const status = r.ok ? (l.op === "pause" ? "paused" : "running") : l.op === "pause" ? "running" : "paused"
  const rev = state.rev + 1
  const row: MachineRow = { ...machine.row, status, error: error ? { ...error, at: ctx.now } : null, revision: String(rev) }
  writes.push(upsertMachine(row, machine.n))
  const active = state.active - countedRow(machine.row) + countedRow(row)
  return { ok: true, state: next(state, { pending, active }, { machine: row.id, removed: false }), value: { applied: true, final: true }, writes }
}
