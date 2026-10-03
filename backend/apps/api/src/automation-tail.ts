import { WorkerEntrypoint } from "cloudflare:workers"
import type { UsageRecord } from "@cmux/protocol"
import type { Env } from "./env.ts"

/** What the loader attaches to each tenant Dynamic Worker's tail (code-run.ts). */
export interface AutomationTailProps {
  readonly team: string
  readonly run: string
  readonly automation: string
  readonly commit: string
}

/** Longest log message forwarded (the rest is cut; logs are diagnostics, not data). */
const MAX_LOG_CHARS = 2_000

/**
 * Tail of every tenant Dynamic Worker (automations-billing.md 4.1, 5.2). It
 * runs after each tenant invocation with the runtime's measured CPU time and
 * the tenant's logs and exceptions. CPU goes into the team's UsageMeterDO
 * (`automation.cpu_ms`, one record per invocation, keyed so a redelivered tail
 * counts once); logs and exceptions become structured JSON lines in Workers
 * Logs tagged with team, run and commit (the telemetry store comes in slice 6).
 */
export class AutomationTail extends WorkerEntrypoint<Env, AutomationTailProps> {
  override async tail(events: TraceItem[]): Promise<void> {
    const p = this.ctx.props
    const records: Array<UsageRecord> = []
    events.forEach((ev, i) => {
      const at = ev.eventTimestamp ?? Date.now()
      const cpu = Math.max(0, Math.round((ev as TraceItem & { cpuTime?: number }).cpuTime ?? 0))
      records.push({ key: `tail:${p.run}:${at}:${i}:${ev.entrypoint ?? ""}`, meter: "automation.cpu_ms", quantity: cpu, source: "tail", observed_at: at, run: p.run, automation: p.automation, commit: p.commit })
      for (const log of ev.logs) {
        const msg = (log.message as ReadonlyArray<unknown>).map((m) => (typeof m === "string" ? m : JSON.stringify(m))).join(" ").slice(0, MAX_LOG_CHARS)
        console.log(JSON.stringify({ source: "automation", team: p.team, run: p.run, automation: p.automation, commit: p.commit, level: log.level, ts: log.timestamp, msg }))
      }
      for (const ex of ev.exceptions) {
        console.log(JSON.stringify({ source: "automation", team: p.team, run: p.run, automation: p.automation, commit: p.commit, level: "error", ts: ex.timestamp, msg: `${ex.name}: ${ex.message}`.slice(0, MAX_LOG_CHARS) }))
      }
      if (ev.outcome !== "ok") console.log(JSON.stringify({ source: "automation", team: p.team, run: p.run, level: "warn", msg: `invocation outcome ${ev.outcome}` }))
    })
    if (records.length === 0) return
    const meter = this.env.USAGE_METER_DO.get(this.env.USAGE_METER_DO.idFromName(p.team))
    await meter.record(p.team, records)
  }
}
