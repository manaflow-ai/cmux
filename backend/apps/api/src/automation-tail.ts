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
const INVOCATION_ID = /^inv_[a-z0-9]{20}$/

interface Marker {
  readonly run: string
  readonly automation: string
  readonly invocation: string
}

/**
 * The invocation the harness's first log line names (code-run.ts). Only the first log
 * line of an invocation counts; every field must be one of our id shapes, so a usage
 * key never holds free text. Tenant code shares the isolate and could, at worst, make
 * one of its own invocations reuse another one's marker; the ledger then counts it
 * once, which under-counts and never over-counts.
 */
const markerOf = (message: unknown): Marker | undefined => {
  const m = message as ReadonlyArray<unknown> | undefined
  if (!Array.isArray(m) || m[0] !== RUN_MARKER) return undefined
  const [, run, automation, invocation] = m as ReadonlyArray<unknown>
  if (typeof run !== "string" || typeof automation !== "string" || typeof invocation !== "string") return undefined
  return RUN_ID.test(run) && AUTOMATION_ID.test(automation) && INVOCATION_ID.test(invocation) ? { run, automation, invocation } : undefined
}

const text = (message: unknown): string =>
  (Array.isArray(message) ? message : [message]).map((m) => (typeof m === "string" ? m : JSON.stringify(m))).join(" ").slice(0, MAX_LOG_CHARS)

/**
 * Tail of every tenant Dynamic Worker (automations-billing.md 4.1, 5.2). It runs after
 * each tenant invocation with the runtime's measured CPU time and the tenant's logs and
 * exceptions. Each invocation becomes one `automation.invocations` and one
 * `automation.cpu_ms` record in the team's UsageMeterDO.
 *
 * Billing rule: never over-bill. Usage keys are `<run>:<invocation>` from the harness
 * marker, an id the API Worker chose for exactly this invocation, so a redelivered tail
 * counts once. An invocation without a valid marker is not metered (and is logged). The
 * buffered tail has no runtime invocation id; the streaming tail has one but is
 * experimental for loaded workers, and its id is not a billing key until a staging
 * redelivery proves it stable (automations-plan.md 2a). Usage is recorded before logs
 * are written; logs and exceptions become JSON lines in Workers Logs (slice 6 adds the
 * telemetry store).
 */
export class AutomationTail extends WorkerEntrypoint<Env, AutomationTailProps> {
  override async tail(events: TraceItem[]): Promise<void> {
    const p = this.ctx.props
    const records: Array<UsageRecord> = []
    const lines: Array<string> = []
    for (const ev of events) {
      const marker = markerOf(ev.logs[0]?.message)
      const tag = { source: "automation", team: p.team, run: marker?.run ?? "unattributed", automation: marker?.automation ?? null, commit: p.commit }
      if (marker) {
        const key = `${marker.run}:${marker.invocation}`
        const cpu = Math.max(0, Math.round((ev as TraceItem & { cpuTime?: number }).cpuTime ?? 0))
        const base = { source: "tail" as const, observed_at: ev.eventTimestamp ?? Date.now(), commit: p.commit, run: marker.run, automation: marker.automation }
        records.push({ key: `inv:${key}`, meter: "automation.invocations", quantity: 1, ...base }, { key: `cpu:${key}`, meter: "automation.cpu_ms", quantity: cpu, ...base })
      } else {
        lines.push(JSON.stringify({ ...tag, level: "warn", msg: "invocation without a harness marker: not metered" }))
      }
      for (const log of ev.logs.slice(marker ? 1 : 0, MAX_LOG_LINES)) lines.push(JSON.stringify({ ...tag, level: log.level, ts: log.timestamp, msg: text(log.message) }))
      for (const ex of ev.exceptions.slice(0, MAX_LOG_LINES)) lines.push(JSON.stringify({ ...tag, level: "error", ts: ex.timestamp, msg: `${ex.name}: ${ex.message}`.slice(0, MAX_LOG_CHARS) }))
      if (ev.outcome !== "ok") lines.push(JSON.stringify({ ...tag, level: "warn", msg: `invocation outcome ${ev.outcome}` }))
    }
    if (records.length > 0) {
      const meter = this.env.USAGE_METER_DO.get(this.env.USAGE_METER_DO.idFromName(p.team))
      await meter.record(p.team, records)
    }
    for (const line of lines) console.log(line)
  }
}
