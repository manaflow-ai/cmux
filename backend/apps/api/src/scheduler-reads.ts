import type { Principal, RowReader } from "@cmux/ownership"
import type { RunState } from "@cmux/protocol"
import type { SchedulerState } from "./domains/scheduler.ts"
import { allAudit, isTeamAdminOf } from "./scheduler-reads-audit.ts"
import { mayEdit, mayView } from "./domains/scheduler-access.ts"
import { allMoved, automationOf, automationRowOf, cursorOf, isLegacyHead, listAutomations, listRuns, movedOf, MOVED_RETENTION_MS, publicRun, runOf } from "./domains/scheduler-rows.ts"
import type { ReadResult } from "./owner-do.ts"

/** SchedulerDO reads ((g1)): automations, runs and bodies come from rows; lists page by keyset. */

const RUN_STATES: ReadonlySet<string> = new Set(["queued", "running", "sleeping", "waiting", "succeeded", "failed", "cancelled", "skipped", "dead"])
const MAX_AUTOMATION_PAGE = 100
const MAX_RUN_PAGE = 100

const intIn = (raw: unknown, min: number, max: number, fallback: number) => (typeof raw === "number" && Number.isInteger(raw) ? Math.min(max, Math.max(min, raw)) : fallback)
const notFound = (message: string): ReadResult => ({ ok: false, code: "selector.not_found", message })

export const schedulerRead = (state: SchedulerState, op: string, params: unknown, principal: Principal, rows: RowReader | undefined): ReadResult => {
  if (!principal.team || (state.owner !== null && state.owner !== principal.team)) return { ok: false, code: "auth.forbidden", message: "not this team's scheduler" }
  // A head from before (g1) has no rows yet: answer like the reducer until scheduler.rows_migrate commits.
  if (isLegacyHead(state)) return { ok: false, code: "owner.migrating", message: "the scheduler is moving to rows; retry shortly", retryable: true }
  const p = (params ?? {}) as { automation?: unknown; trigger?: unknown; run?: unknown; state?: unknown; cursor?: unknown; limit?: unknown }
  const automation = typeof p.automation === "string" ? p.automation : undefined
  // Inside the team: a private automation, its runs and its audit entries exist only for who may view it
  // (domains/scheduler-access.ts). A run of a deleted automation is the admins' to read.
  const owner = state.owner ?? principal.team
  const sees = (id: string) => {
    const row = automationRowOf(rows, id)
    return row ? mayView(principal, owner, row) : isTeamAdminOf(principal, owner)
  }
  if (automation !== undefined && automationRowOf(rows, automation) && !sees(automation)) {
    return op === "automation.runs.list" ? { ok: true, value: { runs: [] }, revision: "" } : notFound("automation not found")
  }
  switch (op) {
    case "automation.list": {
      // Without params: the first page is every automation (at most MAX_AUTOMATIONS), as the live UI reads it.
      const page = listAutomations(rows, cursorOf(p.cursor), intIn(p.limit, 1, MAX_AUTOMATION_PAGE, MAX_AUTOMATION_PAGE))
      const now = Date.now()
      const moved = allMoved(rows).filter((m) => now - m.moved_at < MOVED_RETENTION_MS)
      return { ok: true, value: { owner: state.owner, automations: page.items.filter((a) => mayView(principal, owner, a)), automation_count: state.automation_count ?? 0, next_cursor: page.next, moved }, revision: "" }
    }
    case "automation.get": {
      const a = automation === undefined ? undefined : automationOf(rows, automation)
      if (!a && automation !== undefined) {
        const m = movedOf(rows, automation)
        if (m) return { ok: false, code: "automation.moved", message: `this automation moved to ${m.moved_to} (${m.moved_id})` }
      }
      return a ? { ok: true, value: a, revision: "" } : notFound("automation not found")
    }
    case "automation.runs.list": {
      const page = listRuns(rows, { ...(automation === undefined ? {} : { automation }), limit: intIn(p.limit, 1, 200, 50) })
      return { ok: true, value: { runs: page.items.filter((r) => sees(r.automation)).map(publicRun) }, revision: "" }
    }
    case "automation.audit.list": {
      const limit = intIn(p.limit, 1, 500, 500)
      const entries = allAudit(rows).filter((e) => (automation === undefined || e.automation === automation) && sees(e.automation))
      return { ok: true, value: { entries: entries.slice(-limit) }, revision: "" }
    }
    case "run.list": {
      const runState = typeof p.state === "string" && RUN_STATES.has(p.state) ? (p.state as RunState) : undefined
      if (p.state !== undefined && runState === undefined) return { ok: false, code: "validation.invalid", message: "unknown run state" }
      const before = cursorOf(p.cursor)
      const page = listRuns(rows, { ...(automation === undefined ? {} : { automation }), ...(runState ? { state: runState } : {}), ...(before === undefined ? {} : { before }), limit: intIn(p.limit, 1, MAX_RUN_PAGE, 50) })
      return { ok: true, value: { runs: page.items.filter((r) => sees(r.automation)).map(publicRun), next_cursor: page.next }, revision: "" }
    }
    case "run.get": {
      const r = typeof p.run === "string" ? runOf(rows, p.run) : undefined
      return r && sees(r.automation) ? { ok: true, value: { ...publicRun(r), body: r.body }, revision: "" } : notFound("run not found (pruned or unknown)")
    }
    case "automation.settings.get":
      return { ok: true, value: state.settings ?? { agent_run_default_seconds: null }, revision: "" }
    case "automation.webhook.get": {
      const a = automation === undefined ? undefined : automationRowOf(rows, automation)
      const t = a?.triggers.find((x) => x.id === p.trigger)
      // The webhook secret lets anyone start runs: only who may change the automation reads it.
      if (!a || !t || t.spec.type !== "webhook" || !mayEdit(principal, owner, a)) return notFound("webhook trigger not found")
      // The Worker adds the path and the derived secret; the DO only proves the trigger exists in this team.
      return { ok: true, value: { owner: a.owner, automation: a.id, trigger: t.id }, revision: "" }
    }
    default:
      return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
  }
}
