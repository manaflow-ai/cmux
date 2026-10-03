import type { OutboxItem, Reject } from "@cmux/ownership"
import type { RunRecord, SchedulerState } from "./scheduler.ts"

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

type Cancel = (runs: Readonly<Record<string, RunRecord>>, automation: string) => { runs: Record<string, RunRecord>; outbox: Array<OutboxItem> }

/**
 * `scheduler.run_policy`: the newest push wins. A deny also cancels queued runs that have no
 * Workflow yet (coordinator 2026-10-03); started runs keep running.
 */
export const reduceRunPolicy = (state: SchedulerState, value: RunPolicy, cancelQueued: Cancel) => {
  const next = applyRunPolicy(state.run_policy, value)
  if (!next) return { ok: true as const, state, value: state.run_policy ?? null, changed: false }
  if (next.runs_allowed) return { ok: true as const, state: { ...state, run_policy: next }, value: next }
  let runs: Readonly<Record<string, RunRecord>> = state.runs
  const outbox: Array<OutboxItem> = []
  for (const id of Object.keys(state.automations)) {
    const c = cancelQueued(runs, id)
    runs = c.runs
    outbox.push(...c.outbox)
  }
  return { ok: true as const, state: { ...state, run_policy: next, runs }, value: next, outbox }
}
