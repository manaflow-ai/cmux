import { WorkerEntrypoint } from "cloudflare:workers"
import type { UsageRecord } from "@cmux/protocol"
import { RUN_MARKER } from "./code-run.ts"
import type { Env } from "./env.ts"

/** What the loader attaches to each tenant Dynamic Worker's tail (code-run.ts). One warm worker serves many runs. */
export interface AutomationTailProps {
  readonly team: string
  readonly commit: string
}

/** Longest log message forwarded, and log lines per invocation (logs are diagnostics, not data). */
const MAX_LOG_CHARS = 2_000
const MAX_LOG_LINES = 100

const RUN_ID = /^run_[a-z0-9]{20}$/
const AUTOMATION_ID = /^auto_[a-z0-9]{20}$/

/**
 * The run an invocation served, from the harness's marker line. Best effort: tenant code
 * shares the isolate and can forge or hide the marker, which moves usage between runs of
 * its own team only (the team comes from the loader props). Billing keys never use it.
 */
const runOf = (ev: TraceItem): { run: string; automation: string } | undefined => {
  const first = ev.logs[0]?.message as ReadonlyArray<unknown> | undefined
  if (!first || first[0] !== RUN_MARKER || typeof first[1] !== "string" || typeof first[2] !== "string") return undefined
  return RUN_ID.test(first[1]) && AUTOMATION_ID.test(first[2]) ? { run: first[1], automation: first[2] } : undefined
}

/**
 * Tail of every tenant Dynamic Worker (automations-billing.md 4.1, 5.2). It
 * runs after each tenant invocation with the runtime's measured CPU time and
 * the tenant's logs and exceptions. Each invocation becomes one
 * `automation.invocations` and one `automation.cpu_ms` record in the team's
 * UsageMeterDO, keyed by run and event time so a redelivered tail counts once.
 * Usage is recorded before logs are written. Logs and exceptions become JSON
 * lines in Workers Logs tagged with team, run and commit (the telemetry store
 * comes in slice 6).
 */
export class AutomationTail extends WorkerEntrypoint<Env, AutomationTailProps> {
  override async tail(events: TraceItem[]): Promise<void> {
    const p = this.ctx.props
    const records: Array<UsageRecord> = []
    const lines: Array<string> = []
    // Usage keys use only runtime values and a per-call nonce, never tenant-influenced text, so
    // tenant code cannot make records invalid or make two invocations share a key. The price is
    // a possible double count if the runtime ever delivers the same tail call twice.
    const nonce = crypto.randomUUID()
    events.forEach((ev, i) => {
      const r = runOf(ev)
      const run = r?.run ?? "unattributed"
      const at = ev.eventTimestamp ?? Date.now()
      const key = `${nonce}:${i}`
      const cpu = Math.max(0, Math.round((ev as TraceItem & { cpuTime?: number }).cpuTime ?? 0))
      const base = { source: "tail" as const, observed_at: at, commit: p.commit, ...(r ? { run: r.run, automation: r.automation } : {}) }
      records.push({ key: `inv:${key}`, meter: "automation.invocations", quantity: 1, ...base }, { key: `cpu:${key}`, meter: "automation.cpu_ms", quantity: cpu, ...base })
      const tag = { source: "automation", team: p.team, run, automation: r?.automation ?? null, commit: p.commit }
      for (const log of ev.logs.slice(r ? 1 : 0, MAX_LOG_LINES)) {
        const msg = (log.message as ReadonlyArray<unknown>).map((m) => (typeof m === "string" ? m : JSON.stringify(m))).join(" ").slice(0, MAX_LOG_CHARS)
        lines.push(JSON.stringify({ ...tag, level: log.level, ts: log.timestamp, msg }))
      }
      for (const ex of ev.exceptions.slice(0, MAX_LOG_LINES)) lines.push(JSON.stringify({ ...tag, level: "error", ts: ex.timestamp, msg: `${ex.name}: ${ex.message}`.slice(0, MAX_LOG_CHARS) }))
      if (ev.outcome !== "ok") lines.push(JSON.stringify({ ...tag, level: "warn", msg: `invocation outcome ${ev.outcome}` }))
    })
    if (records.length > 0) {
      const meter = this.env.USAGE_METER_DO.get(this.env.USAGE_METER_DO.idFromName(p.team))
      await meter.record(p.team, records)
    }
    for (const line of lines) console.log(line)
  }
}
