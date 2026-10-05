import type { MachineRow } from "./domains/cloud.ts"

/**
 * Idle pause decision (coordinator, 2026-10-05). Idle counts only from the VM's own activity report,
 * applied now: a running machine, an idle policy above 0, no open sessions, and the newest of the reported
 * input or agent action (never later than now) and the last start or bind older than the idle policy. A report without activity
 * times, or no report at all, is unknown and never idle. Off unless the team policy cloud.idlePause is on.
 */
export interface ReportedActivity {
  readonly active_sessions: number
  readonly last_user_input_at?: number
  readonly last_agent_action_at?: number
}

export const idleFromReport = (row: MachineRow | undefined, activity: ReportedActivity | undefined, now: number): boolean => {
  if (!row || row.status !== "running" || !activity) return false
  const idleSeconds = row.idle_policy.idle_seconds
  if (!(idleSeconds > 0) || activity.active_sessions !== 0) return false
  const times = [activity.last_user_input_at, activity.last_agent_action_at].filter((t): t is number => typeof t === "number")
  if (times.length === 0) return false
  // A start or bind restarts the idle period: a resumed VM keeps its old times in memory (review P2).
  const last = Math.max(Math.min(Math.max(...times), now), row.last_power_at ?? 0)
  return now - last >= idleSeconds * 1000
}
