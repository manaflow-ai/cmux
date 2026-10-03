import { canonicalJson, type Domain, type OutboxItem, type Principal, type ReduceContext, type ReduceResult } from "@cmux/ownership"
import {
  AutomationCreate,
  AutomationDelete,
  AutomationRunNow,
  AutomationSettingsSet,
  AutomationUpdate,
  schedulerInternalOps,
  type Automation,
  type Body,
  type Run,
  type RunState,
  type TriggerInput
} from "@cmux/protocol"
import { checkCron, nextFire } from "../cron.ts"
import { admit, decodeParams, reject, requirePersonalTeamAdmin } from "./common.ts"
import { automationOutbox, countDeploy, reduceDeploy } from "./scheduler-code.ts"
import { MAX_ACTIVE_RUNS_PER_TEAM, MAX_OPEN_RUNS_PER_TEAM, queueFull, rateLimited, takeRunToken, type RunBucket } from "./scheduler-limits.ts"
import { applyRunPolicy, policyDenied, runsAllowed, type RunPolicy } from "./scheduler-policy.ts"
import { personalTeamIdFor } from "./user.ts"

/**
 * SchedulerDO's reducer (spec cloud-and-automations.md, decision D13): the
 * automation definitions of one owner team, their schedules and the recent
 * runs. Pure and deterministic: time comes from `ctx.now` or the op params,
 * ids from `ctx.newId`, so mirror replay reproduces every state.
 */

/** A run as the owner stores it: the public shape plus what dispatch needs. */
export interface RunRecord extends Run {
  /** The Workflow instance exists (run.dispatched committed). */
  readonly dispatched: boolean
  /** The body of the automation version that fired; later edits never change a started run. */
  readonly body: Body
  /**
   * When the run must have ended (set at dispatch): the wall-clock budget, else
   * the body's sleeps plus RUN_GRACE_MS. The owner's alarm fires once at this
   * instant for a run still open; a run that reports its end never wakes it.
   */
  readonly deadline_at?: number
  /** The wall-clock budget of the automation version that fired (seconds), like `body`. */
  readonly wall_clock_seconds?: number
}

/** A run's deadline; runs from before deadlines existed fall back to created_at. */
export const deadlineOf = (r: RunRecord): number | undefined =>
  r.deadline_at ?? (r.dispatched ? r.created_at + runLimitMs(r.body, r.wall_clock_seconds) : undefined)

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

export interface SchedulerState {
  readonly owner: string | null
  readonly automations: Readonly<Record<string, Automation>>
  readonly runs: Readonly<Record<string, RunRecord>>
  /** Continue triggers: runs fired in the current chain (reset when another trigger starts a run). */
  readonly chains: Readonly<Record<string, number>>
  /** Team automation settings; absent in objects created before settings. */
  readonly settings?: { readonly agent_run_default_seconds: number | null }
  /** Code changes (create, update or deploy of a code body) in the current UTC day (abuse limit, A18). */
  readonly deploys?: { readonly day: string; readonly count: number }
  /** Run-creation token bucket (abuse limit, scheduler-limits.ts). */
  readonly rate?: RunBucket
  /** TeamDO's push of the run class of agents.allowedClasses (scheduler-policy.ts); absent = allowed. */
  readonly run_policy?: RunPolicy
}


export const MAX_AUTOMATIONS = 100
export const MAX_FINISHED_RUNS = 200
export const TERMINAL: ReadonlySet<RunState> = new Set(["succeeded", "failed", "cancelled", "skipped", "dead"])
const ACTIVE_STARTED: ReadonlySet<RunState> = new Set(["running", "sleeping", "waiting"])
/** Trigger types this backend fires today; the rest are stored for the UI and marked. */
export const SUPPORTED_TRIGGERS: ReadonlySet<TriggerInput["type"]> = new Set(["cron", "manual", "continue", "webhook"])

/** Whether this backend fires a trigger: the supported types, plus integration events bound to a connection. */
export const triggerSupported = (spec: TriggerInput) => SUPPORTED_TRIGGERS.has(spec.type) || (spec.type === "event" && spec.source === "integration" && spec.connection !== undefined)

export { matchingEventTriggers } from "./scheduler-events.ts"

const internalByName = new Map(schedulerInternalOps.map((d) => [d.name, d]))

export const publicRun = (r: RunRecord): Run => {
  const { dispatched: _d, body: _b, deadline_at: _dl, wall_clock_seconds: _w, ...run } = r
  return run
}

/** Runs that hold a concurrency slot: started, or queued with a Workflow instance. */
const holdsSlot = (r: RunRecord) => ACTIVE_STARTED.has(r.state) || (r.state === "queued" && r.dispatched)

/** Queued runs whose Workflow may start now, oldest first, within each automation's concurrency. */
export const dispatchable = (state: SchedulerState): Array<RunRecord> => {
  const runs = Object.values(state.runs).sort((a, b) => a.created_at - b.created_at || (a.id < b.id ? -1 : 1))
  const used = new Map<string, number>()
  for (const r of runs) if (holdsSlot(r)) used.set(r.automation, (used.get(r.automation) ?? 0) + 1)
  const out: Array<RunRecord> = []
  // Team-wide cap: past it, runs stay visibly queued until a slot frees.
  let team = [...used.values()].reduce((n, x) => n + x, 0)
  for (const r of runs) {
    if (team >= MAX_ACTIVE_RUNS_PER_TEAM) break
    if (r.state !== "queued" || r.dispatched) continue
    const max = state.automations[r.automation]?.concurrency.max ?? 1
    const n = used.get(r.automation) ?? 0
    if (n >= max) continue
    used.set(r.automation, n + 1)
    team++
    out.push(r)
  }
  return out
}

/** The earliest scheduled fire across enabled automations, with what to submit for it. */
export const dueFires = (state: SchedulerState, now: number): Array<{ automation: string; trigger: string; scheduled_at: number }> => {
  const out: Array<{ automation: string; trigger: string; scheduled_at: number }> = []
  for (const a of Object.values(state.automations)) {
    if (!a.enabled) continue
    for (const t of a.triggers) if (t.status === "active" && t.next_at !== null && t.next_at <= now) out.push({ automation: a.id, trigger: t.id, scheduled_at: t.next_at })
  }
  return out.sort((x, y) => x.scheduled_at - y.scheduled_at)
}

export const nextScheduled = (state: SchedulerState): number | null => {
  let min: number | null = null
  for (const a of Object.values(state.automations)) if (a.next_run_at !== null && (min === null || a.next_run_at < min)) min = a.next_run_at
  return min
}

const withNextRun = (a: Automation): Automation => {
  let next: number | null = null
  if (a.enabled) for (const t of a.triggers) if (t.status === "active" && t.next_at !== null && (next === null || t.next_at < next)) next = t.next_at
  return { ...a, next_run_at: next }
}

const validateTriggers = (triggers: ReadonlyArray<TriggerInput>) => {
  for (const t of triggers) {
    if (t.type === "cron") {
      const c = checkCron(t.expr, t.tz)
      if (!c.ok) return reject("trigger.invalid", c.message)
    }
    if (t.type === "presence" && t.earliest) {
      const c = checkCron(t.earliest.expr, t.earliest.tz)
      if (!c.ok) return reject("trigger.invalid", `presence earliest: ${c.message}`)
    }
  }
  if (triggers.filter((t) => t.type === "continue").length > 1) return reject("trigger.invalid", "at most one continue trigger")
  return undefined
}

/**
 * Stored triggers for a new list. A trigger whose spec is unchanged keeps its id
 * (webhook endpoints embed it) and its schedule; `rescheduleFrom` recomputes
 * every cron schedule (on enable, so slots missed while disabled do not fire).
 */
const storeTriggers = (inputs: ReadonlyArray<TriggerInput>, previous: Automation["triggers"], ctx: ReduceContext, rescheduleFrom?: number): Automation["triggers"] => {
  const pool = [...previous]
  return inputs.map((spec) => {
    const key = canonicalJson(spec)
    const i = pool.findIndex((t) => canonicalJson(t.spec) === key)
    const kept = i >= 0 ? pool.splice(i, 1)[0] : undefined
    const status = triggerSupported(spec) ? ("active" as const) : ("not_yet_supported" as const)
    let next_at: number | null = kept?.next_at ?? null
    if (spec.type === "cron" && (!kept || rescheduleFrom !== undefined)) next_at = nextFire(spec.expr, spec.tz, rescheduleFrom ?? ctx.now)
    if (spec.type !== "cron" && spec.type !== "continue") next_at = null
    // Re-enabling never resumes a continue chain stopped by disabling; the next run starts one.
    if (spec.type === "continue" && rescheduleFrom !== undefined) next_at = null
    return { id: kept?.id ?? ctx.newId("trg"), status, spec, next_at }
  })
}

/** Drops the oldest finished runs beyond the cap; active runs always stay. */
const prune = (runs: Record<string, RunRecord>): Record<string, RunRecord> => {
  const finished = Object.values(runs)
    .filter((r) => TERMINAL.has(r.state))
    .sort((a, b) => b.created_at - a.created_at || (a.id < b.id ? 1 : -1))
  if (finished.length <= MAX_FINISHED_RUNS) return runs
  const out = { ...runs }
  for (const r of finished.slice(MAX_FINISHED_RUNS)) delete out[r.id]
  return out
}

const runOutbox = (r: RunRecord): OutboxItem => ({ kind: "automation_run.upsert", entity: r.id, payload: publicRun(r) })

/** A new run for `a`; `skipped` when the concurrency limit says so (a visible row, never a silent drop). */
const startRun = (
  state: SchedulerState,
  a: Automation,
  trigger: Run["trigger"],
  ctx: ReduceContext
): { state: SchedulerState; run: RunRecord; outbox: Array<OutboxItem> } | { rejected: ReturnType<typeof rateLimited> } => {
  if (!runsAllowed(state.run_policy)) return { rejected: policyDenied() }
  const rate = takeRunToken(state.rate, ctx.now)
  if (!rate) return { rejected: rateLimited() }
  if (Object.values(state.runs).filter((r) => !TERMINAL.has(r.state)).length >= MAX_OPEN_RUNS_PER_TEAM) return { rejected: queueFull() }
  const active = Object.values(state.runs).filter((r) => r.automation === a.id && !TERMINAL.has(r.state)).length
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
  if (continueTrigger) chains[continueTrigger.id] = trigger.id === continueTrigger.id ? (chains[continueTrigger.id] ?? 0) + 1 : 0
  return { state: { ...state, runs: prune({ ...state.runs, [run.id]: run }), chains, rate }, run, outbox: [runOutbox(run)] }
}

/** After a run ends: the continue trigger schedules the next run unless a stop condition holds. */
const continueAfter = (state: SchedulerState, run: RunRecord, now: number): { state: SchedulerState; outbox: Array<OutboxItem> } => {
  const a = state.automations[run.automation]
  const t = a?.triggers.find((x) => x.spec.type === "continue" && x.status === "active")
  if (!a || !a.enabled || !t || t.spec.type !== "continue" || run.state === "skipped") return { state, outbox: [] }
  const spec = t.spec
  const count = state.chains[t.id] ?? 0
  const goalMet = run.outcome?.goal_met === true && spec.until.includes("goal_met")
  const atMax = spec.max_runs !== undefined && count >= spec.max_runs
  if (goalMet || atMax || run.state === "cancelled") return { state, outbox: [] }
  const triggers = a.triggers.map((x) => (x.id === t.id ? { ...x, next_at: now + spec.cooldown_seconds * 1000 } : x))
  const next = withNextRun({ ...a, triggers })
  return { state: { ...state, automations: { ...state.automations, [a.id]: next } }, outbox: [automationOutbox(next)] }
}

const ownerOf = (state: SchedulerState, p: Principal) => state.owner ?? p.team ?? null

/** Disabling or deleting stops runs that have not started: queued runs without a Workflow become cancelled. */
const cancelQueued = (runs: Readonly<Record<string, RunRecord>>, automation: string, now: number, why: string): { runs: Record<string, RunRecord>; outbox: Array<OutboxItem> } => {
  const out: Record<string, RunRecord> = { ...runs }
  const outbox: Array<OutboxItem> = []
  for (const r of Object.values(runs)) {
    if (r.automation !== automation || r.state !== "queued" || r.dispatched) continue
    const next: RunRecord = { ...r, state: "cancelled", finished_at: now, error: { code: "automation.stopped", message: why } }
    out[r.id] = next
    outbox.push(runOutbox(next))
  }
  return { runs: out, outbox }
}

export const schedulerDomain: Domain<SchedulerState> = {
  initial: () => ({ owner: null, automations: {}, runs: {}, chains: {} }),

  authorize: (state, op, _params, principal) => {
    if (principal.kind === "system") {
      if (!internalByName.has(op)) return { code: "auth.forbidden", message: `${op} is not an internal op` }
      return admit("cloud:SchedulerDO", op, principal, () => undefined, Date.now())
    }
    if (!principal.team) return { code: "auth.forbidden", message: "needs a team" }
    if (state.owner && state.owner !== principal.team) return { code: "auth.forbidden", message: "not this team's scheduler" }
    return admit("cloud:SchedulerDO", op, principal, (p) => (p.grant_classes ? { op_classes: p.grant_classes, revoked_at: null, expires_at: null } : undefined), Date.now())
  },

  reduce: (state, op, params, ctx): ReduceResult<SchedulerState> => {
    const p = ctx.principal
    switch (op) {
      case "automation.create": {
        const d = decodeParams<typeof AutomationCreate.params.Type>(AutomationCreate, params)
        if (!d.ok) return d
        const owner = ownerOf(state, p)
        if (!owner || !p.user) return reject("auth.forbidden", "automation.create needs a user in a team")
        if (Object.keys(state.automations).length >= MAX_AUTOMATIONS) return reject("automation.limit", `at most ${MAX_AUTOMATIONS} automations per team`)
        const bad = validateTriggers(d.value.triggers)
        if (bad) return bad
        const v = d.value
        const counted = countDeploy(state, undefined, v.body, ctx.now)
        if (!counted.ok) return counted.result
        const a = withNextRun({
          id: ctx.newId("auto"),
          owner,
          name: v.name,
          description: v.description ?? "",
          enabled: v.enabled ?? true,
          version: 1,
          triggers: storeTriggers(v.triggers, [], ctx),
          body: v.body,
          target: v.target ?? { kind: "cloud_vm" },
          concurrency: v.concurrency ?? { max: 1, on_limit: "queue" },
          budget: v.budget ?? {},
          created_by: p.user,
          created_at: ctx.now,
          updated_at: ctx.now,
          next_run_at: null
        })
        return { ok: true, state: { ...state, owner, automations: { ...state.automations, [a.id]: a }, ...(counted.deploys ? { deploys: counted.deploys } : {}) }, value: a, outbox: [automationOutbox(a)] }
      }

      case "automation.update": {
        const d = decodeParams<typeof AutomationUpdate.params.Type>(AutomationUpdate, params)
        if (!d.ok) return d
        const v = d.value
        const a = state.automations[v.automation]
        if (!a) return reject("selector.not_found", "automation not found")
        if (v.expected_version !== undefined && v.expected_version !== a.version) {
          return reject("version.conflict", "expected_version does not match", { expected: v.expected_version, actual: a.version })
        }
        if (v.triggers) {
          const bad = validateTriggers(v.triggers)
          if (bad) return bad
        }
        const enabled = v.enabled ?? a.enabled
        const reenabled = enabled && !a.enabled
        const triggers = storeTriggers(
          v.triggers ?? a.triggers.map((t) => t.spec),
          a.triggers,
          ctx,
          reenabled ? ctx.now : undefined
        )
        const draft = withNextRun({
          ...a,
          name: v.name ?? a.name,
          description: v.description ?? a.description,
          enabled,
          triggers,
          body: v.body ?? a.body,
          target: v.target ?? a.target,
          concurrency: v.concurrency ?? a.concurrency,
          budget: v.budget ?? a.budget
        })
        const { version: _v, updated_at: _u, ...cmpDraft } = draft
        const { version: _v2, updated_at: _u2, ...cmpOld } = a
        if (canonicalJson(cmpDraft) === canonicalJson(cmpOld)) return { ok: true, state, value: a, changed: false }
        const counted = countDeploy(state, a.body, draft.body, ctx.now)
        if (!counted.ok) return counted.result
        const next = { ...draft, version: a.version + 1, updated_at: ctx.now }
        const stopped = !enabled && a.enabled ? cancelQueued(state.runs, a.id, ctx.now, "the automation was disabled") : { runs: state.runs, outbox: [] }
        return {
          ok: true,
          state: { ...state, automations: { ...state.automations, [a.id]: next }, runs: stopped.runs, ...(counted.deploys ? { deploys: counted.deploys } : {}) },
          value: next,
          outbox: [automationOutbox(next), ...stopped.outbox]
        }
      }

      case "automation.delete": {
        const d = decodeParams<typeof AutomationDelete.params.Type>(AutomationDelete, params)
        if (!d.ok) return d
        const a = state.automations[d.value.automation]
        if (!a) return reject("selector.not_found", "automation not found")
        const { [a.id]: _gone, ...rest } = state.automations
        const chains = { ...state.chains }
        for (const t of a.triggers) delete chains[t.id]
        const stopped = cancelQueued(state.runs, a.id, ctx.now, "the automation was deleted")
        return {
          ok: true,
          state: { ...state, automations: rest, chains, runs: stopped.runs },
          value: { automation: a.id },
          outbox: [{ kind: "automation.delete", entity: a.id, payload: { id: a.id } }, ...stopped.outbox]
        }
      }

      case "automation.deploy":
        return reduceDeploy(state, params, ctx)

      case "automation.run": {
        const d = decodeParams<typeof AutomationRunNow.params.Type>(AutomationRunNow, params)
        if (!d.ok) return d
        const a = state.automations[d.value.automation]
        if (!a) return reject("selector.not_found", "automation not found")
        const manual = a.triggers.find((t) => t.spec.type === "manual")
        const r = startRun(state, a, { id: manual?.id ?? null, type: "manual" }, ctx)
        if ("rejected" in r) return r.rejected
        return { ok: true, state: r.state, value: publicRun(r.run), outbox: r.outbox }
      }

      case "automation.fire": {
        const d = decodeParams<{ automation: string; trigger: string; scheduled_at: number }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const a = state.automations[d.value.automation]
        const t = a?.triggers.find((x) => x.id === d.value.trigger)
        // Stale: deleted, disabled, edited, or already advanced. A replayed alarm lands here.
        if (!a || !t || !a.enabled || t.status !== "active" || t.next_at !== d.value.scheduled_at) return { ok: true, state, value: { stale: true }, changed: false }
        const spec = t.spec
        // Missed slots (an alarm late by hours) fire once, then the schedule resumes after now.
        const next_at = spec.type === "cron" ? nextFire(spec.expr, spec.tz, Math.max(d.value.scheduled_at, ctx.now)) : null
        const updated = withNextRun({ ...a, triggers: a.triggers.map((x) => (x.id === t.id ? { ...x, next_at } : x)) })
        const base = { ...state, automations: { ...state.automations, [a.id]: updated } }
        // Runs not allowed by team policy: the schedule moves on and no run starts (a retry would loop).
        if (!runsAllowed(state.run_policy)) return { ok: true, state: base, value: { skipped: "policy.denied" }, outbox: [automationOutbox(updated)] }
        const r = startRun(base, updated, { id: t.id, type: spec.type, scheduled_at: d.value.scheduled_at }, ctx)
        if ("rejected" in r) return r.rejected
        return { ok: true, state: r.state, value: publicRun(r.run), outbox: [automationOutbox(updated), ...r.outbox] }
      }

      case "automation.deliver": {
        const d = decodeParams<{ automation: string; trigger: string; delivery_id: string }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const a = state.automations[d.value.automation]
        const t = a?.triggers.find((x) => x.id === d.value.trigger)
        if (!a || !t || !a.enabled || t.status !== "active") return { ok: true, state, value: { stale: true }, changed: false }
        const r = startRun(state, a, { id: t.id, type: t.spec.type, delivery_id: d.value.delivery_id }, ctx)
        if ("rejected" in r) return r.rejected
        return { ok: true, state: r.state, value: publicRun(r.run), outbox: r.outbox }
      }

      case "run.dispatched": {
        const d = decodeParams<{ run: string }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const r = state.runs[d.value.run]
        // A report may have marked the run dispatched first (it raced the create, or a create retry
        // found the instance); the deadline is still set exactly once here or in run.report.
        if (!r || TERMINAL.has(r.state) || (r.dispatched && r.deadline_at !== undefined)) return { ok: true, state, value: { run: d.value.run }, changed: false }
        const next: RunRecord = { ...r, dispatched: true, deadline_at: r.deadline_at ?? ctx.now + runLimitMs(r.body, r.wall_clock_seconds) }
        return { ok: true, state: { ...state, runs: { ...state.runs, [r.id]: next } }, value: { run: r.id } }
      }

      case "run.report": {
        const d = decodeParams<{ run: string; state: RunState; step: number; error?: { code: string; message: string }; outcome?: { goal_met: boolean; summary?: string } }>(
          internalByName.get(op)!,
          params
        )
        if (!d.ok) return d
        const v = d.value
        const r = state.runs[v.run]
        if (!r) return reject("selector.not_found", "run not found (pruned or unknown)")
        // Terminal states are final: a late or duplicated report never reopens a run.
        if (TERMINAL.has(r.state)) return { ok: true, state, value: publicRun(r), changed: false }
        const terminal = TERMINAL.has(v.state)
        const next: RunRecord = {
          ...r,
          state: v.state,
          step: Math.max(r.step, v.step),
          started_at: r.started_at ?? (v.state === "queued" ? null : ctx.now),
          finished_at: terminal ? ctx.now : null,
          error: v.error ?? (terminal ? r.error : null),
          outcome: v.outcome ?? r.outcome,
          dispatched: true,
          deadline_at: r.deadline_at ?? ctx.now + runLimitMs(r.body, r.wall_clock_seconds)
        }
        if (canonicalJson(next) === canonicalJson(r)) return { ok: true, state, value: publicRun(r), changed: false }
        let s: SchedulerState = { ...state, runs: { ...state.runs, [r.id]: next } }
        const outbox: Array<OutboxItem> = [runOutbox(next)]
        if (terminal) {
          const c = continueAfter(s, next, ctx.now)
          s = { ...c.state, runs: prune({ ...c.state.runs }) }
          outbox.push(...c.outbox)
        }
        return { ok: true, state: s, value: publicRun(next), outbox }
      }

      case "scheduler.run_policy": {
        const d = decodeParams<RunPolicy>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const next = applyRunPolicy(state.run_policy, d.value)
        if (!next) return { ok: true, state, value: state.run_policy ?? null, changed: false }
        return { ok: true, state: { ...state, run_policy: next }, value: next }
      }

      case "automation.settings.set": {
        const d = decodeParams<{ agent_run_default_seconds: number | null }>(AutomationSettingsSet, params)
        if (!d.ok) return d
        const notAdmin = requirePersonalTeamAdmin(p, personalTeamIdFor)
        if (notAdmin) return { ok: false, ...notAdmin }
        const owner = ownerOf(state, p)
        const next = { agent_run_default_seconds: d.value.agent_run_default_seconds }
        if (canonicalJson(next) === canonicalJson(state.settings ?? { agent_run_default_seconds: null })) return { ok: true, state, value: next, changed: false }
        return { ok: true, state: { ...state, owner, settings: next }, value: next }
      }

      default:
        return reject("validation.invalid", `unknown op ${op}`)
    }
  }
}
