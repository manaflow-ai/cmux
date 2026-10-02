import { canonicalJson, type Domain, type OutboxItem, type Principal, type ReduceContext, type ReduceResult } from "@cmux/ownership"
import {
  AutomationCreate,
  AutomationDelete,
  AutomationRunNow,
  AutomationUpdate,
  schedulerInternalOps,
  type Automation,
  type Body,
  type Run,
  type RunState,
  type TriggerInput
} from "@cmux/protocol"
import { checkCron, nextFire } from "../cron.ts"
import { admit, decodeParams, reject } from "./common.ts"

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
}

export interface SchedulerState {
  readonly owner: string | null
  readonly automations: Readonly<Record<string, Automation>>
  readonly runs: Readonly<Record<string, RunRecord>>
  /** Continue triggers: runs fired in the current chain (reset when another trigger starts a run). */
  readonly chains: Readonly<Record<string, number>>
}

export const MAX_AUTOMATIONS = 100
export const MAX_FINISHED_RUNS = 200
export const TERMINAL: ReadonlySet<RunState> = new Set(["succeeded", "failed", "cancelled", "skipped", "dead"])
const ACTIVE_STARTED: ReadonlySet<RunState> = new Set(["running", "sleeping", "waiting"])
/** Trigger types this backend fires today; the rest are stored for the UI and marked. */
export const SUPPORTED_TRIGGERS: ReadonlySet<TriggerInput["type"]> = new Set(["cron", "manual", "continue", "webhook"])

/** Whether this backend fires a trigger: the supported types, plus integration events bound to a connection. */
export const triggerSupported = (spec: TriggerInput) => SUPPORTED_TRIGGERS.has(spec.type) || (spec.type === "event" && spec.source === "integration" && spec.connection !== undefined)

/** Dot path lookup in a provider payload (filters compare the value as a string). */
const pathValue = (payload: unknown, path: string): unknown => {
  let v: unknown = payload
  for (const k of path.split(".")) {
    if (v === null || typeof v !== "object") return undefined
    v = (v as Record<string, unknown>)[k]
  }
  return v
}

/** Event triggers of enabled automations that match a provider event: same connection, event pattern, every filter. */
export const matchingEventTriggers = (
  state: SchedulerState,
  ev: { connection: string; event: string; payload: unknown }
): Array<{ automation: string; trigger: string }> => {
  const out: Array<{ automation: string; trigger: string }> = []
  for (const a of Object.values(state.automations)) {
    if (!a.enabled) continue
    for (const t of a.triggers) {
      const s = t.spec
      if (t.status !== "active" || s.type !== "event" || s.source !== "integration" || s.connection !== ev.connection) continue
      const pattern = s.event
      const eventOk = pattern === "*" || pattern === ev.event || (pattern.endsWith(".*") && ev.event.startsWith(pattern.slice(0, -1)))
      if (!eventOk) continue
      if (s.filter && !Object.entries(s.filter).every(([k, v]) => String(pathValue(ev.payload, k)) === v)) continue
      out.push({ automation: a.id, trigger: t.id })
    }
  }
  return out
}

const internalByName = new Map(schedulerInternalOps.map((d) => [d.name, d]))

export const publicRun = (r: RunRecord): Run => {
  const { dispatched: _d, body: _b, ...run } = r
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
  for (const r of runs) {
    if (r.state !== "queued" || r.dispatched) continue
    const max = state.automations[r.automation]?.concurrency.max ?? 1
    const n = used.get(r.automation) ?? 0
    if (n >= max) continue
    used.set(r.automation, n + 1)
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

const automationOutbox = (a: Automation): OutboxItem => ({ kind: "automation.upsert", entity: a.id, payload: a })
const runOutbox = (r: RunRecord): OutboxItem => ({ kind: "automation_run.upsert", entity: r.id, payload: publicRun(r) })

/** A new run for `a`; `skipped` when the concurrency limit says so (a visible row, never a silent drop). */
const startRun = (
  state: SchedulerState,
  a: Automation,
  trigger: Run["trigger"],
  ctx: ReduceContext
): { state: SchedulerState; run: RunRecord; outbox: Array<OutboxItem> } => {
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
    body: a.body
  }
  // A run from any trigger other than continue starts a new continue chain.
  const continueTrigger = a.triggers.find((t) => t.spec.type === "continue")
  const chains = { ...state.chains }
  if (continueTrigger) chains[continueTrigger.id] = trigger.id === continueTrigger.id ? (chains[continueTrigger.id] ?? 0) + 1 : 0
  return { state: { ...state, runs: prune({ ...state.runs, [run.id]: run }), chains }, run, outbox: [runOutbox(run)] }
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
        return { ok: true, state: { ...state, owner, automations: { ...state.automations, [a.id]: a } }, value: a, outbox: [automationOutbox(a)] }
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
        const next = { ...draft, version: a.version + 1, updated_at: ctx.now }
        return { ok: true, state: { ...state, automations: { ...state.automations, [a.id]: next } }, value: next, outbox: [automationOutbox(next)] }
      }

      case "automation.delete": {
        const d = decodeParams<typeof AutomationDelete.params.Type>(AutomationDelete, params)
        if (!d.ok) return d
        const a = state.automations[d.value.automation]
        if (!a) return reject("selector.not_found", "automation not found")
        const { [a.id]: _gone, ...rest } = state.automations
        const chains = { ...state.chains }
        for (const t of a.triggers) delete chains[t.id]
        return {
          ok: true,
          state: { ...state, automations: rest, chains },
          value: { automation: a.id },
          outbox: [{ kind: "automation.delete", entity: a.id, payload: { id: a.id } }]
        }
      }

      case "automation.run": {
        const d = decodeParams<typeof AutomationRunNow.params.Type>(AutomationRunNow, params)
        if (!d.ok) return d
        const a = state.automations[d.value.automation]
        if (!a) return reject("selector.not_found", "automation not found")
        const manual = a.triggers.find((t) => t.spec.type === "manual")
        const r = startRun(state, a, { id: manual?.id ?? null, type: "manual" }, ctx)
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
        const r = startRun(base, updated, { id: t.id, type: spec.type, scheduled_at: d.value.scheduled_at }, ctx)
        return { ok: true, state: r.state, value: publicRun(r.run), outbox: [automationOutbox(updated), ...r.outbox] }
      }

      case "automation.deliver": {
        const d = decodeParams<{ automation: string; trigger: string; delivery_id: string }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const a = state.automations[d.value.automation]
        const t = a?.triggers.find((x) => x.id === d.value.trigger)
        if (!a || !t || !a.enabled || t.status !== "active") return { ok: true, state, value: { stale: true }, changed: false }
        const r = startRun(state, a, { id: t.id, type: t.spec.type, delivery_id: d.value.delivery_id }, ctx)
        return { ok: true, state: r.state, value: publicRun(r.run), outbox: r.outbox }
      }

      case "run.dispatched": {
        const d = decodeParams<{ run: string }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const r = state.runs[d.value.run]
        if (!r || r.dispatched) return { ok: true, state, value: { run: d.value.run }, changed: false }
        const next = { ...r, dispatched: true }
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
          dispatched: true
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

      default:
        return reject("validation.invalid", `unknown op ${op}`)
    }
  }
}
