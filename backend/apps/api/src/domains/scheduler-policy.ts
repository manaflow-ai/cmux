import type { OutboxItem, Reject, RowReader } from "@cmux/ownership"
import { runRowOf } from "./scheduler-rows.ts"
import type { SchedulerStore } from "./scheduler-store.ts"
import type { SchedulerState } from "./scheduler.ts"

/**
 * The run class of the team policy's agents.allowedClasses (enterprise P17-4), as SchedulerDO
 * holds it. TeamDO is the single writer of the policy; it pushes this projection with its
 * policy version (team-run-sync.ts), and SchedulerDO keeps the newest version only, so a late
 * or repeated push changes nothing. FAIL CLOSED (backend lead review): absent = not synced yet,
 * and no run starts; SchedulerDO pulls the policy from TeamDO before it creates runs.
 */
export interface RunPolicy {
  readonly version: number
  readonly runs_allowed: boolean
}

export const runsAllowed = (policy: RunPolicy | undefined) => policy?.runs_allowed === true

/** The refusal for a run while runs are not allowed: denied, or (retryable) not synced yet. */
export const runPolicyRefusal = (policy: RunPolicy | undefined): ({ ok: false } & Reject) | undefined =>
  policy === undefined ? policyPending() : policy.runs_allowed ? undefined : policyDenied()

/** Retryable: SchedulerDO has not received the team's run policy yet (it asks TeamDO). */
export const policyPending = (): { ok: false } & Reject => ({
  ok: false,
  code: "policy.pending",
  message: "the team's automation policy is not loaded yet; retry shortly",
  retryable: true
})

/** Not retryable: the run waits for a policy change, not for time. */
export const policyDenied = (): { ok: false } & Reject => ({
  ok: false,
  code: "policy.denied",
  message: "your team does not allow automation runs (agents.allowedClasses has no run)"
})

/** System op `scheduler.run_policy {version, runs_allowed}`: newest version wins. */
export const applyRunPolicy = (current: RunPolicy | undefined, next: RunPolicy): RunPolicy | undefined => {
  if (current && next.version < current.version) return undefined
  if (current && next.version === current.version && next.runs_allowed === current.runs_allowed) return undefined
  return { version: next.version, runs_allowed: next.runs_allowed }
}

type Cancel = (automation: string) => Array<OutboxItem>

/**
 * `scheduler.run_policy`: the newest push wins. A deny also cancels queued runs that have no
 * Workflow yet (coordinator 2026-10-03); started runs keep running.
 */
export const reduceRunPolicy = (state: SchedulerState, st: SchedulerStore, value: RunPolicy, cancelQueued: Cancel) => {
  const next = applyRunPolicy(state.run_policy, value)
  if (!next) return { ok: true as const, state, value: state.run_policy ?? null, changed: false }
  if (next.runs_allowed) return { ok: true as const, state: { ...state, run_policy: next }, value: next }
  // Every automation's queued runs (an open run's automation always exists: delete cancels them).
  const automations = [...new Set(st.openRuns().map((r) => r.automation))].filter((id) => st.automation(id) !== undefined)
  const outbox = automations.flatMap((id) => cancelQueued(id))
  return { ok: true as const, state: st.head({ ...state, run_policy: next }), value: next, outbox, writes: st.writes() }
}

/**
 * After AUTOMATION_RUN.create resolved (the create awaited, so other ops ran meanwhile): a run
 * that is terminal now (cancelled by a deny, disable or delete), or gone, must have its new
 * Workflow instance terminated instead of being marked dispatched.
 */
export const afterCreate = (rows: RowReader | undefined, run: string): "terminate" | "dispatched" => {
  const r = runRowOf(rows, run)
  return !r || TERMINAL_STATES.has(r.state) ? "terminate" : "dispatched"
}

const TERMINAL_STATES: ReadonlySet<string> = new Set(["succeeded", "failed", "cancelled", "skipped", "dead"])
