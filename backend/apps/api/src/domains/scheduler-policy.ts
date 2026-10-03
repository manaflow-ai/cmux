import type { Reject } from "@cmux/ownership"

/**
 * The run class of the team policy's agents.allowedClasses (enterprise P17-4), as SchedulerDO
 * holds it. TeamDO is the single writer of the policy; it pushes this projection with its
 * policy version (team-run-sync.ts), and SchedulerDO keeps the newest version only, so a late
 * or repeated push changes nothing. Absent = the product default, which allows runs.
 */
export interface RunPolicy {
  readonly version: number
  readonly runs_allowed: boolean
}

export const runsAllowed = (policy: RunPolicy | undefined) => policy?.runs_allowed !== false

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
