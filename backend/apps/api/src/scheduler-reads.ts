import type { Principal, RowReader } from "@cmux/ownership"
import type { RunState } from "@cmux/protocol"
import type { SchedulerState } from "./domains/scheduler.ts"
import { automationOf, automationRowOf, cursorOf, listAutomations, listRuns, publicRun, runOf } from "./domains/scheduler-rows.ts"
import type { ReadResult } from "./owner-do.ts"

/** SchedulerDO reads ((g1)): automations, runs and bodies come from rows; lists page by keyset. */

const RUN_STATES: ReadonlySet<string> = new Set(["queued", "running", "sleeping", "waiting", "succeeded", "failed", "cancelled", "skipped", "dead"])
const MAX_AUTOMATION_PAGE = 100
const MAX_RUN_PAGE = 100

const intIn = (raw: unknown, min: number, max: number, fallback: number) => (typeof raw === "number" && Number.isInteger(raw) ? Math.min(max, Math.max(min, raw)) : fallback)
const notFound = (message: string): ReadResult => ({ ok: false, code: "selector.not_found", message })

export const schedulerRead = (state: SchedulerState, op: string, params: unknown, principal: Principal, rows: RowReader | undefined): ReadResult => {
  if (!principal.team || (state.owner !== null && state.owner !== principal.team)) return { ok: false, code: "auth.forbidden", message: "not this team's scheduler" }
  const p = (params ?? {}) as { automation?: unknown; trigger?: unknown; run?: unknown; state?: unknown; cursor?: unknown; limit?: unknown }
  const automation = typeof p.automation === "string" ? p.automation : undefined
  switch (op) {
    case "automation.list": {
      // Without params: the first page is every automation (at most MAX_AUTOMATIONS), as the live UI reads it.
      const page = listAutomations(rows, cursorOf(p.cursor), intIn(p.limit, 1, MAX_AUTOMATION_PAGE, MAX_AUTOMATION_PAGE))
      return { ok: true, value: { owner: state.owner, automations: page.items, automation_count: state.automation_count ?? 0, next_cursor: page.next }, revision: "" }
    }
    case "automation.get": {
      const a = automation === undefined ? undefined : automationOf(rows, automation)
      return a ? { ok: true, value: a, revision: "" } : notFound("automation not found")
    }
    case "automation.runs.list": {
      const page = listRuns(rows, { ...(automation === undefined ? {} : { automation }), limit: intIn(p.limit, 1, 200, 50) })
      return { ok: true, value: { runs: page.items.map(publicRun) }, revision: "" }
    }
    case "run.list": {
      const runState = typeof p.state === "string" && RUN_STATES.has(p.state) ? (p.state as RunState) : undefined
      if (p.state !== undefined && runState === undefined) return { ok: false, code: "validation.invalid", message: "unknown run state" }
      const before = cursorOf(p.cursor)
      const page = listRuns(rows, { ...(automation === undefined ? {} : { automation }), ...(runState ? { state: runState } : {}), ...(before === undefined ? {} : { before }), limit: intIn(p.limit, 1, MAX_RUN_PAGE, 50) })
      return { ok: true, value: { runs: page.items.map(publicRun), next_cursor: page.next }, revision: "" }
    }
    case "run.get": {
      const r = typeof p.run === "string" ? runOf(rows, p.run) : undefined
      return r ? { ok: true, value: { ...publicRun(r), body: r.body }, revision: "" } : notFound("run not found (pruned or unknown)")
    }
    case "automation.settings.get":
      return { ok: true, value: state.settings ?? { agent_run_default_seconds: null }, revision: "" }
    case "automation.webhook.get": {
      const a = automation === undefined ? undefined : automationRowOf(rows, automation)
      const t = a?.triggers.find((x) => x.id === p.trigger)
      if (!a || !t || t.spec.type !== "webhook") return notFound("webhook trigger not found")
      // The Worker adds the path and the derived secret; the DO only proves the trigger exists in this team.
      return { ok: true, value: { owner: a.owner, automation: a.id, trigger: t.id }, revision: "" }
    }
    default:
      return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
  }
}
