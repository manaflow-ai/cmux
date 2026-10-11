import { CloudCore } from "./cloud-do-core.ts"
import { BACKSTOP_IDLE_SECONDS, idleFromReport, reportsActivity, SilentRetry, silentSince, StaleAlerts, type ReportedActivity } from "./cloud-idle.ts"
import { TABLE_MACHINE, type MachineRow } from "./domains/cloud.ts"

/**
 * The idle rules of CloudDO (split from cloud-do-core.ts at the 500-line limit): the short idle pause
 * from capable VM reports (team policy cloud.idlePause), the 24 h idle backstop, and the no_report cost
 * backstop with its per-machine backoff. All pauses go through the internal cloud.machine.idle_pause.
 */
export abstract class CloudIdle extends CloudCore {
  /** The team's Cloud policy from its TeamDO (fail closed: a failed RPC fails the caller). */
  protected teamCloudPolicy(entity: string): Promise<{ connect_services: ReadonlyArray<string>; idle_pause: boolean }> {
    const stub = this.env.TEAM_DO.get(this.env.TEAM_DO.idFromName(entity)) as unknown as { cloudPolicy(e: string): Promise<{ connect_services: ReadonlyArray<string>; idle_pause: boolean }> }
    return stub.cloudPolicy(entity)
  }

  /**
   * After a VM status report was applied: pause the machine when the report shows it idle past its
   * idle policy and the team policy cloud.idlePause is on (cloud-idle.ts). The money-op path: the
   * per-team limit, the ledger (cloud.machine.idle_pause), the guarded provider call.
   */
  protected async considerIdlePause(entity: string, machine: string, report: unknown, now: number): Promise<void> {
    const engine = this.boundEngine
    const row = engine?.rows.get<MachineRow>(TABLE_MACHINE, machine)?.row
    // Only a daemon that can see sessions (capability "activity") reports idleness; any other report is unknown (coordinator, 2026-10-05).
    if (!reportsActivity(report)) return
    const activity = (report as { activity?: ReportedActivity } | null)?.activity
    // The 24 h backstop applies to every team; it is also the longest threshold, so a report not idle by it needs no policy read.
    if (!engine || !row || !idleFromReport(row, activity, now, Math.min(BACKSTOP_IDLE_SECONDS, row.idle_policy.idle_seconds > 0 ? row.idle_policy.idle_seconds : BACKSTOP_IDLE_SECONDS))) return
    if (!idleFromReport(row, activity, now, BACKSTOP_IDLE_SECONDS)) {
      // Shorter than the backstop: only with the team's cloud.idlePause on (fail closed: a failed read means off).
      if (!(await this.teamCloudPolicy(entity).catch(() => ({ idle_pause: false }))).idle_pause) return
    }
    const limit = this.env.CLOUD_MUTATION_LIMIT
    // Per machine (review P3): a VM whose pauses keep failing cannot use up the team's create/delete budget.
    if (limit && !(await limit.limit({ key: `cloud-idle:${machine}` })).success) return
    const r = this.submitSystem("cloud.machine.idle_pause", { machine, reason: "idle" }, `idle-pause:${machine}:${engine.currentSeq}`)
    if (r.frames.some((f) => f.t === "result")) await this.runMachine(machine, null)
  }

  /** Backoff of the cost-backstop pause per machine (cloud-idle.ts SilentRetry; durable). */
  protected readonly silentRetry = new SilentRetry(this.sqlStore)
  protected silentRetryAt(machine: string): number | null {
    return this.silentRetry.at(machine)
  }

  /** Running machines that sent no applied report for 24 h after their last start or bind (the cost backstop). */
  protected silentMachines(now: number): Array<string> {
    return (this.boundEngine?.rows.range<MachineRow>(TABLE_MACHINE, { limit: 1000 }) ?? []).filter((r) => (r.row.status === "running" || r.row.status === "provisioning") && now - silentSince(r.row, this.vmStatus.lastActivityAt(r.row.id)) >= BACKSTOP_IDLE_SECONDS * 1000).map((r) => r.row.id)
  }

  /** The cost backstop pass (alarm): pause each silent machine on the money-op path, pause_reason no_report. */
  protected async pauseSilent(now: number): Promise<void> {
    const engine = this.boundEngine
    if (!engine) return
    for (const machine of this.silentMachines(now)) {
      // A pause the provider keeps refusing backs off: 60 s, 2 min, 4 min ... at most 1 h (coordinator, 2026-10-05).
      if ((this.silentRetryAt(machine) ?? 0) > now) continue
      const limit = this.env.CLOUD_MUTATION_LIMIT
      if (limit && !(await limit.limit({ key: `cloud-idle:${machine}` })).success) continue
      const r = this.submitSystem("cloud.machine.idle_pause", { machine, reason: "no_report" }, `silent-pause:${machine}:${engine.currentSeq}`)
      this.silentRetry.tried(machine, now)
      if (r.frames.some((f) => f.t === "result")) await this.runMachine(machine, null)
    }
  }


  private readonly staleAlerts = new StaleAlerts(this.sqlStore)

  /**
   * After the cost backstop ran: a machine still running or provisioning with no applied report
   * for 24 h means its pause failed or never happened (provider refusals, a limit, a bug). One
   * error-level event per machine per hour, ids and times only, so the alert path sees it.
   */
  protected alertStale(now: number): void {
    const engine = this.boundEngine
    if (!engine) return
    const stale = this.silentMachines(now)
    for (const machine of this.staleAlerts.due(stale, now)) {
      const row = engine.rows.get<MachineRow>(TABLE_MACHINE, machine)?.row
      if (!row) continue
      const since = silentSince(row, this.vmStatus.lastActivityAt(machine))
      console.error(JSON.stringify({ level: "error", event: "cloud.machine.stale_running", stream: engine.stream, team: engine.currentState.team, machine, status: row.status, silent_since: since, silent_hours: Math.floor((now - since) / 360_000) / 10, next_pause_try_at: this.silentRetryAt(machine) }))
    }
  }

}
