import type { Reject } from "@cmux/ownership"
import { currentPolicy, type PolicyState } from "./team-policy.ts"

/**
 * TeamDO -> SchedulerDO projection of the run class of agents.allowedClasses (enterprise
 * P17-4). Runs start inside SchedulerDO (alarms, webhooks, manual runs), which has no copy of
 * the team policy, so TeamDO pushes whether runs are allowed, with its policy version, and
 * records what SchedulerDO acknowledged. It pushes only when the allowed bit differs from the
 * acknowledged one; the default (no push yet) is allowed, matching the product default.
 */
export interface RunSyncState extends PolicyState {
  readonly runs_synced?: { readonly version: number; readonly runs_allowed: boolean }
}

/** Whether the current policy allows automation runs (absent key = product default = allowed). */
export const policyAllowsRuns = (state: PolicyState): boolean => {
  const classes = (currentPolicy(state).values as Record<string, { value: unknown } | undefined>)["agents.allowedClasses"]?.value
  return !Array.isArray(classes) || classes.includes("run")
}

/** True when SchedulerDO's copy may differ from the policy. */
export const runSyncPending = (state: RunSyncState): boolean => (state.runs_synced?.runs_allowed ?? true) !== policyAllowsRuns(state)

/** The push TeamDO owes SchedulerDO now. */
export const runSyncPush = (state: RunSyncState) => ({ version: currentPolicy(state).version, runs_allowed: policyAllowsRuns(state) })

type Result<S> = { ok: true; state: S; value: unknown; changed?: boolean } | ({ ok: false } & Reject)

/** System op `team.policy.runs_synced {version, runs_allowed}`: SchedulerDO acknowledged; newest version wins. */
export const reduceRunsSynced = <S extends RunSyncState>(state: S, params: unknown): Result<S> => {
  const p = params as { version?: unknown; runs_allowed?: unknown }
  if (typeof p?.version !== "number" || !Number.isInteger(p.version) || typeof p.runs_allowed !== "boolean") {
    return { ok: false, code: "validation.invalid", message: "version and runs_allowed required" }
  }
  const cur = state.runs_synced
  if (cur && (p.version < cur.version || (p.version === cur.version && p.runs_allowed === cur.runs_allowed))) return { ok: true, state, value: cur, changed: false }
  const next = { version: p.version, runs_allowed: p.runs_allowed }
  return { ok: true, state: { ...state, runs_synced: next }, value: next }
}
