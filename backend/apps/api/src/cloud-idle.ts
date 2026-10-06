import type { SqlStore } from "@cmux/ownership"
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

/** Our cost backstop (coordinator, 2026-10-05): every team, 24 h without activity by the VM's own reports. */
export const BACKSTOP_IDLE_SECONDS = 24 * 3600

/** `idleSeconds`: the threshold in force (the machine's idle policy with cloud.idlePause on, else the backstop). */
export const idleFromReport = (row: MachineRow | undefined, activity: ReportedActivity | undefined, now: number, idleSeconds: number): boolean => {
  if (!row || row.status !== "running" || !activity) return false
  if (!(idleSeconds > 0) || activity.active_sessions !== 0) return false
  const times = [activity.last_user_input_at, activity.last_agent_action_at].filter((t): t is number => typeof t === "number")
  if (times.length === 0) return false
  // A start or bind restarts the idle period: a resumed VM keeps its old times in memory (review P2).
  const last = Math.max(Math.min(Math.max(...times), now), row.last_power_at ?? 0)
  return now - last >= idleSeconds * 1000
}

/**
 * The cost backstop for a silent VM (coordinator decision b, 2026-10-05): a running machine with no
 * applied report for 24 h after its last start or bind is paused (pause_reason no_report). This acts
 * on a missing report on purpose; the short idle pause never does.
 */
export const silentSince = (row: MachineRow, lastReportAt: number | null): number => Math.max(lastReportAt ?? 0, row.last_power_at ?? row.created_at)

/**
 * A report speaks for idleness only when its daemon advertises the `activity` capability (it can see
 * sessions). Any other report is unknown activity: no idle pause, and it does not reset the no_report
 * clock (coordinator, 2026-10-05).
 */
export const reportsActivity = (report: unknown): boolean => {
  const caps = (report as { daemon?: { capabilities?: unknown } } | null)?.daemon?.capabilities
  return Array.isArray(caps) && caps.includes("activity")
}

/** Backoff of the cost-backstop pause per machine: 60 s doubling, at most 1 h (durable). */
export class SilentRetry {
  constructor(private readonly sql: SqlStore) {}
  private exists() {
    return Number(this.sql.exec<{ n: number }>(`SELECT count(*) AS n FROM sqlite_master WHERE name = 'cloud_silent_retry'`)[0]?.n ?? 0) > 0
  }
  at(machine: string): number | null {
    if (!this.exists()) return null
    const r = this.sql.exec<{ next_at: number }>(`SELECT next_at FROM cloud_silent_retry WHERE machine = ?`, machine)[0]
    return r ? Number(r.next_at) : null
  }
  tried(machine: string, now: number) {
    this.sql.exec(`CREATE TABLE IF NOT EXISTS cloud_silent_retry (machine TEXT PRIMARY KEY, attempts INTEGER NOT NULL, next_at INTEGER NOT NULL)`)
    const attempts = Number(this.sql.exec<{ attempts: number }>(`SELECT attempts FROM cloud_silent_retry WHERE machine = ?`, machine)[0]?.attempts ?? 0) + 1
    this.sql.exec(`INSERT INTO cloud_silent_retry (machine, attempts, next_at) VALUES (?, ?, ?) ON CONFLICT(machine) DO UPDATE SET attempts = excluded.attempts, next_at = excluded.next_at`, machine, attempts, now + Math.min(3600_000, 60_000 * 2 ** attempts))
  }
  clear(machine: string) {
    if (this.exists()) this.sql.exec(`DELETE FROM cloud_silent_retry WHERE machine = ?`, machine)
  }
}
