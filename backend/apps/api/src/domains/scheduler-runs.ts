import type { OutboxItem, ReduceContext, RowReader } from "@cmux/ownership"
import type { Automation, Body, Run, RunState } from "@cmux/protocol"
import { automationOutbox } from "./scheduler-code.ts"
import { MAX_ACTIVE_RUNS_PER_TEAM, MAX_OPEN_RUNS_PER_TEAM, queueFull, rateLimited, takeRunToken } from "./scheduler-limits.ts"
import { runPolicyRefusal } from "./scheduler-policy.ts"
import { allAutomations, automationRowOf, openRuns, publicRun, type RunRow } from "./scheduler-rows.ts"
import type { SchedulerStore } from "./scheduler-store.ts"
import type { RunRecord, SchedulerState } from "./scheduler.ts"

/**
 * Run lifecycle of the SchedulerDO reducer: start, concurrency, continue chains, cancel and
 * prune. Pure: rows come from the reduction's SchedulerStore, time from `ctx.now`.
 */

export const MAX_AUTOMATIONS = 100
export const MAX_FINISHED_RUNS = 200
export const TERMINAL: ReadonlySet<RunState> = new Set(["succeeded", "failed", "cancelled", "skipped", "dead"])
const ACTIVE_STARTED: ReadonlySet<RunState> = new Set(["running", "sleeping", "waiting"])

/** Slack added to a steps body's sleeps for its steps and reports. */
export const RUN_GRACE_MS = 60 * 60_000
/** Default limit of an agent_prompt run without a wall-clock budget (agents may work for hours). */
export const AGENT_RUN_DEFAULT_MS = 24 * 3600_000

/** Longest a run may take (ms): the budget when set, else the body's sleeps plus grace (agent runs: 24 h). */
export const runLimitMs = (body: Body, wallClockSeconds: number | undefined): number => {
  if (wallClockSeconds !== undefined) return wallClockSeconds * 1000
  // Agent and code runs may sleep and wait for hours; the 24 h default is the abuse limit (A18).
  if (body.type === "agent_prompt" || body.type === "code") return AGENT_RUN_DEFAULT_MS
  return body.steps.reduce((n, s) => n + (s.type === "sleep" ? s.seconds * 1000 : 0), 0) + RUN_GRACE_MS
}

/** A run's deadline; runs from before deadlines existed fall back to created_at (the body is read only then). */
export const deadlineOf = (r: RunRow | RunRecord, body: () => Body): number | undefined =>
  r.deadline_at ?? (r.dispatched ? r.created_at + runLimitMs(body(), r.wall_clock_seconds) : undefined)

/** The earliest active trigger time of an enabled automation. */
export const withNextRun = <A extends Pick<Automation, "enabled" | "triggers" | "next_run_at">>(a: A): A => {
  let next: number | null = null
  if (a.enabled) for (const t of a.triggers) if (t.status === "active" && t.next_at !== null && (next === null || t.next_at < next)) next = t.next_at
  return { ...a, next_run_at: next }
}

/** Runs that hold a concurrency slot: started, or queued with a Workflow instance. */
const holdsSlot = (r: RunRow) => ACTIVE_STARTED.has(r.state) || (r.state === "queued" && r.dispatched)

/** Queued runs whose Workflow may start now, oldest first, within each automation's concurrency. `open`: the open runs when the caller read them already. */
export const dispatchable = (state: Pick<SchedulerState, "open_runs">, rows: RowReader | undefined, open: ReadonlyArray<RunRow> = openRuns(state, rows)): Array<RunRow> => {
  const runs = [...open].sort((a, b) => a.created_at - b.created_at || (a.id < b.id ? -1 : 1))
  const used = new Map<string, number>()
  for (const r of runs) if (holdsSlot(r)) used.set(r.automation, (used.get(r.automation) ?? 0) + 1)
  const out: Array<RunRow> = []
  // Team-wide cap: past it, runs stay visibly queued until a slot frees.
  let team = [...used.values()].reduce((n, x) => n + x, 0)
  for (const r of runs) {
    if (team >= MAX_ACTIVE_RUNS_PER_TEAM) break
    if (r.state !== "queued" || r.dispatched) continue
    const max = automationRowOf(rows, r.automation)?.concurrency.max ?? 1
    const n = used.get(r.automation) ?? 0
    if (n >= max) continue
    used.set(r.automation, n + 1)
    team++
    out.push(r)
  }
  return out
}

/** Scheduled fires that are due across enabled automations, oldest first. */
export const dueFires = (rows: RowReader | undefined, now: number): Array<{ automation: string; trigger: string; scheduled_at: number }> => {
  const out: Array<{ automation: string; trigger: string; scheduled_at: number }> = []
  for (const a of allAutomations(rows)) {
    if (!a.enabled) continue
    for (const t of a.triggers) if (t.status === "active" && t.next_at !== null && t.next_at <= now) out.push({ automation: a.id, trigger: t.id, scheduled_at: t.next_at })
  }
  return out.sort((x, y) => x.scheduled_at - y.scheduled_at)
}

export const runOutbox = (r: RunRecord | RunRow): OutboxItem => ({ kind: "automation_run.upsert", entity: r.id, payload: publicRun(r) })

/** A new run for `a`; `skipped` when the concurrency limit says so (a visible row, never a silent drop). */
export const startRun = (
  st: SchedulerStore,
  state: SchedulerState,
  a: Automation,
  trigger: Run["trigger"],
  ctx: ReduceContext
): { state: SchedulerState; run: RunRecord; outbox: Array<OutboxItem> } | { rejected: ReturnType<typeof rateLimited> } => {
  const refused = runPolicyRefusal(state.run_policy)
  if (refused) return { rejected: refused }
  const rate = takeRunToken(state.rate, ctx.now)
  if (!rate) return { rejected: rateLimited() }
  const open = st.openRuns()
  if (open.length >= MAX_OPEN_RUNS_PER_TEAM) return { rejected: queueFull() }
  const active = open.filter((r) => r.automation === a.id).length
  const skip = active >= a.concurrency.max && a.concurrency.on_limit === "skip"
  const run: RunRecord = {
    id: ctx.newId("run"),
    automation: a.id,
    automation_version: a.version,
    owner: a.owner,
    trigger,
    state: skip ? "skipped" : "queued",
    step: -1,
    created_at: ctx.now,
    started_at: null,
    finished_at: skip ? ctx.now : null,
    error: skip ? { code: "concurrency.limit", message: `${active} runs active (max ${a.concurrency.max}, on_limit skip)` } : null,
    outcome: null,
    dispatched: false,
    body: a.body,
    // The run's limit: the automation's own budget, else (agent runs) the team default, else the built-in default.
    ...(a.budget.wall_clock_seconds !== undefined
      ? { wall_clock_seconds: a.budget.wall_clock_seconds }
      : a.body.type === "agent_prompt" && state.settings?.agent_run_default_seconds
        ? { wall_clock_seconds: state.settings.agent_run_default_seconds }
        : {})
  }
  // A run from any trigger other than continue starts a new continue chain.
  const continueTrigger = a.triggers.find((t) => t.spec.type === "continue")
  const chains = { ...state.chains }
  if (continueTrigger && trigger.type !== "automation") chains[continueTrigger.id] = trigger.id === continueTrigger.id ? (chains[continueTrigger.id] ?? 0) + 1 : 0
  st.addRun(run)
  // Drops the oldest finished runs beyond the cap; active runs always stay.
  st.pruneFinished(MAX_FINISHED_RUNS)
  return { state: { ...state, chains, rate }, run, outbox: [runOutbox(run)] }
}

/** After a run ends: the continue trigger schedules the next run unless a stop condition holds. */
export const continueAfter = (st: SchedulerStore, state: SchedulerState, run: RunRow, now: number): Array<OutboxItem> => {
  const a = st.automation(run.automation)
  const t = a?.triggers.find((x) => x.spec.type === "continue" && x.status === "active")
  if (!a || !a.enabled || !t || t.spec.type !== "continue" || run.state === "skipped") return []
  const spec = t.spec
  const count = state.chains[t.id] ?? 0
  const goalMet = run.outcome?.goal_met === true && spec.until.includes("goal_met")
  const atMax = spec.max_runs !== undefined && count >= spec.max_runs
  if (goalMet || atMax || run.state === "cancelled") return []
  const triggers = a.triggers.map((x) => (x.id === t.id ? { ...x, next_at: now + spec.cooldown_seconds * 1000 } : x))
  st.putAutomationRow(withNextRun({ ...a, triggers }))
  return [automationOutbox(st.automationFull(a.id)!)]
}

/** Disabling or deleting stops runs that have not started: queued runs without a Workflow become cancelled. */
export const cancelQueued = (st: SchedulerStore, automation: string, now: number, why: string): Array<OutboxItem> => {
  const outbox: Array<OutboxItem> = []
  for (const r of st.openRuns()) {
    if (r.automation !== automation || r.state !== "queued" || r.dispatched) continue
    const next: RunRow = { ...r, state: "cancelled", finished_at: now, error: { code: "automation.stopped", message: why } }
    st.putRun(next)
    outbox.push(runOutbox(next))
  }
  return outbox
}
