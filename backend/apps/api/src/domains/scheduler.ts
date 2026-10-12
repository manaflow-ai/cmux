import { canonicalJson, type Domain, type Principal, type ReduceResult } from "@cmux/ownership"
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
  type RunState
} from "@cmux/protocol"
import { nextFire } from "../cron.ts"
import { admit, decodeParams, reject, requirePersonalTeamAdmin } from "./common.ts"
import { automationTrigger, isAutomationPrincipal } from "./scheduler-chain.ts"
import { automationOutbox, countDeploy, invalidBody, reduceDeploy } from "./scheduler-code.ts"
import type { RunBucket } from "./scheduler-limits.ts"
import { reduceRowsMigrate } from "./scheduler-migrate.ts"
import { reduceRunPolicy, runPolicyRefusal, type RunPolicy } from "./scheduler-policy.ts"
import { isLegacyHead, publicRun, type RunRow } from "./scheduler-rows.ts"
import { cancelQueued, continueAfter, MAX_AUTOMATIONS, MAX_FINISHED_RUNS, runLimitMs, runOutbox, startRun, TERMINAL, withNextRun } from "./scheduler-runs.ts"
import { SchedulerStore } from "./scheduler-store.ts"
import { storeTriggers, validateTriggers } from "./scheduler-triggers.ts"
import { personalTeamIdFor } from "./user.ts"

/**
 * SchedulerDO's reducer (spec cloud-and-automations.md, decision D13): the
 * automation definitions of one owner team, their schedules and the recent
 * runs. Pure and deterministic: time comes from `ctx.now` or the op params,
 * ids from `ctx.newId`. Automations, runs and bodies are rows ((g1),
 * scheduler-rows.ts); the head keeps settings, counters and counts.
 */

/** A run as the owner uses it: the public shape plus what dispatch needs. Stored without its body (RunRow). */
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

export interface SchedulerState {
  readonly owner: string | null
  /** Continue triggers: runs fired in the current chain (reset when another trigger starts a run). */
  readonly chains: Readonly<Record<string, number>>
  /** Team automation settings; absent in objects created before settings. */
  readonly settings?: { readonly agent_run_default_seconds: number | null }
  /** Code changes (create, update or deploy of a code body) in the current UTC day (abuse limit, A18). */
  readonly deploys?: { readonly day: string; readonly count: number }
  /** Run-creation token bucket (abuse limit, scheduler-limits.ts). */
  readonly rate?: RunBucket
  /** Runs started per automation-run tree (scheduler-chain.ts), keyed by root run. */
  readonly automation_trees?: Readonly<Record<string, number>>
  /** TeamDO's push of the run class of agents.allowedClasses (scheduler-policy.ts); absent = not synced, no runs. */
  readonly run_policy?: RunPolicy
  /** Automation rows (at most MAX_AUTOMATIONS). */
  readonly automation_count?: number
  /** Ids of the open (not terminal) runs, oldest first (at most MAX_OPEN_RUNS_PER_TEAM). */
  readonly open_runs?: ReadonlyArray<string>
  /** Finished run rows kept (MAX_FINISHED_RUNS after each prune). */
  readonly finished_count?: number
  /** Row order of the newest automation or run row (keyset paging, prune order). */
  readonly row_seq?: number
  /** Before (g1): the maps an old head holds until scheduler.rows_migrate moves them to rows. */
  readonly automations?: Readonly<Record<string, Automation>>
  readonly runs?: Readonly<Record<string, RunRecord>>
}

export { MAX_AUTOMATIONS, MAX_FINISHED_RUNS, TERMINAL, runLimitMs, deadlineOf, dispatchable, dueFires, RUN_GRACE_MS, AGENT_RUN_DEFAULT_MS } from "./scheduler-runs.ts"
export { SUPPORTED_TRIGGERS, triggerSupported } from "./scheduler-triggers.ts"
export { matchingEventTriggers } from "./scheduler-events.ts"
export { publicRun } from "./scheduler-rows.ts"

const internalByName = new Map(schedulerInternalOps.map((d) => [d.name, d]))

const ownerOf = (state: SchedulerState, p: Principal) => state.owner ?? p.team ?? null

export const schedulerDomain: Domain<SchedulerState> = {
  initial: () => ({ owner: null, chains: {}, automation_count: 0, open_runs: [], finished_count: 0, row_seq: 0 }),

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
    if (op === "scheduler.rows_migrate") return p.kind === "system" ? reduceRowsMigrate(state, ctx.rows) : reject("auth.forbidden", "internal op")
    // An old head moves to rows on the first bind; until then nothing reads or writes the maps (fail closed, retryable).
    if (isLegacyHead(state)) return { ok: false, code: "owner.migrating", message: "the scheduler is moving to rows; retry shortly", retryable: true }
    const st = new SchedulerStore(state, ctx.rows)
    switch (op) {
      case "automation.create": {
        const d = decodeParams<typeof AutomationCreate.params.Type>(AutomationCreate, params)
        if (!d.ok) return d
        const owner = ownerOf(state, p)
        if (!owner || !p.user) return reject("auth.forbidden", "automation.create needs a user in a team")
        if ((state.automation_count ?? 0) >= MAX_AUTOMATIONS) return reject("automation.limit", `at most ${MAX_AUTOMATIONS} automations per team`)
        const bad = validateTriggers(d.value.triggers) ?? invalidBody(d.value.body)
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
        st.putAutomation(a)
        return { ok: true, state: st.head({ ...state, owner, ...(counted.deploys ? { deploys: counted.deploys } : {}) }), value: a, outbox: [automationOutbox(a)], writes: st.writes() }
      }

      case "automation.update": {
        const d = decodeParams<typeof AutomationUpdate.params.Type>(AutomationUpdate, params)
        if (!d.ok) return d
        const v = d.value
        const a = st.automationFull(v.automation)
        if (!a) return reject("selector.not_found", "automation not found")
        if (v.expected_version !== undefined && v.expected_version !== a.version) {
          return reject("version.conflict", "expected_version does not match", { expected: v.expected_version, actual: a.version })
        }
        const badBody = v.body ? invalidBody(v.body) : undefined
        if (badBody) return badBody
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
        st.putAutomation(next)
        const stopped = !enabled && a.enabled ? cancelQueued(st, a.id, ctx.now, "the automation was disabled") : []
        return {
          ok: true,
          state: st.head({ ...state, ...(counted.deploys ? { deploys: counted.deploys } : {}) }),
          value: next,
          outbox: [automationOutbox(next), ...stopped],
          writes: st.writes()
        }
      }

      case "automation.delete": {
        const d = decodeParams<typeof AutomationDelete.params.Type>(AutomationDelete, params)
        if (!d.ok) return d
        const a = st.automation(d.value.automation)
        if (!a) return reject("selector.not_found", "automation not found")
        const chains = { ...state.chains }
        for (const t of a.triggers) delete chains[t.id]
        const stopped = cancelQueued(st, a.id, ctx.now, "the automation was deleted")
        st.deleteAutomation(a.id)
        return {
          ok: true,
          state: st.head({ ...state, chains }),
          value: { automation: a.id },
          outbox: [{ kind: "automation.delete", entity: a.id, payload: { id: a.id } }, ...stopped],
          writes: st.writes()
        }
      }

      case "automation.deploy":
        return reduceDeploy(state, st, params, ctx)

      case "automation.run": {
        const d = decodeParams<typeof AutomationRunNow.params.Type>(AutomationRunNow, params)
        if (!d.ok) return d
        const a = st.automationFull(d.value.automation)
        if (!a) return reject("selector.not_found", "automation not found")
        const chained = isAutomationPrincipal(p) ? automationTrigger(state, st.rows, p, a) : undefined
        if (chained && "ok" in chained) return chained
        const r = startRun(st, chained ? { ...state, automation_trees: chained.trees } : state, a, chained?.trigger ?? { id: a.triggers.find((t) => t.spec.type === "manual")?.id ?? null, type: "manual" }, ctx)
        if ("rejected" in r) return r.rejected
        return { ok: true, state: st.head(r.state), value: publicRun(r.run), outbox: r.outbox, writes: st.writes() }
      }

      case "automation.fire": {
        const d = decodeParams<{ automation: string; trigger: string; scheduled_at: number }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const a = st.automation(d.value.automation)
        const t = a?.triggers.find((x) => x.id === d.value.trigger)
        // Stale: deleted, disabled, edited, or already advanced. A replayed alarm lands here.
        if (!a || !t || !a.enabled || t.status !== "active" || t.next_at !== d.value.scheduled_at) return { ok: true, state, value: { stale: true }, changed: false }
        const spec = t.spec
        // Missed slots (an alarm late by hours) fire once, then the schedule resumes after now.
        const next_at = spec.type === "cron" ? nextFire(spec.expr, spec.tz, Math.max(d.value.scheduled_at, ctx.now)) : null
        st.putAutomationRow(withNextRun({ ...a, triggers: a.triggers.map((x) => (x.id === t.id ? { ...x, next_at } : x)) }))
        const updated = st.automationFull(a.id)!
        // Runs denied by team policy: the schedule moves on and no run starts (a retry would loop).
        // Not synced yet: a retryable refusal, the alarm retries after SchedulerDO pulls the policy.
        const refused = runPolicyRefusal(state.run_policy)
        if (refused?.code === "policy.denied") return { ok: true, state: st.head(state), value: { skipped: "policy.denied" }, outbox: [automationOutbox(updated)], writes: st.writes() }
        if (refused) return refused
        const r = startRun(st, state, updated, { id: t.id, type: spec.type, scheduled_at: d.value.scheduled_at }, ctx)
        if ("rejected" in r) return r.rejected
        return { ok: true, state: st.head(r.state), value: publicRun(r.run), outbox: [automationOutbox(updated), ...r.outbox], writes: st.writes() }
      }

      case "automation.deliver": {
        const d = decodeParams<{ automation: string; trigger: string; delivery_id: string }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const row = st.automation(d.value.automation)
        const t = row?.triggers.find((x) => x.id === d.value.trigger)
        if (!row || !t || !row.enabled || t.status !== "active") return { ok: true, state, value: { stale: true }, changed: false }
        const r = startRun(st, state, st.automationFull(row.id)!, { id: t.id, type: t.spec.type, delivery_id: d.value.delivery_id }, ctx)
        if ("rejected" in r) return r.rejected
        return { ok: true, state: st.head(r.state), value: publicRun(r.run), outbox: r.outbox, writes: st.writes() }
      }

      case "run.dispatched": {
        const d = decodeParams<{ run: string }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const r = st.run(d.value.run)
        // A report may have marked the run dispatched first (it raced the create, or a create retry
        // found the instance); the deadline is still set exactly once here or in run.report.
        if (!r || TERMINAL.has(r.state) || (r.dispatched && r.deadline_at !== undefined)) return { ok: true, state, value: { run: d.value.run }, changed: false }
        st.putRun({ ...r, dispatched: true, deadline_at: r.deadline_at ?? ctx.now + runLimitMs(st.runBody(r), r.wall_clock_seconds) })
        return { ok: true, state: st.head(state), value: { run: r.id }, writes: st.writes() }
      }

      case "run.report": {
        const d = decodeParams<{ run: string; state: RunState; step: number; error?: { code: string; message: string }; outcome?: { goal_met: boolean; summary?: string } }>(
          internalByName.get(op)!,
          params
        )
        if (!d.ok) return d
        const v = d.value
        const r = st.run(v.run)
        if (!r) return reject("selector.not_found", "run not found (pruned or unknown)")
        // Terminal states are final: a late or duplicated report never reopens a run.
        if (TERMINAL.has(r.state)) return { ok: true, state, value: publicRun(r), changed: false }
        const terminal = TERMINAL.has(v.state)
        const next: RunRow = {
          ...r,
          state: v.state,
          step: Math.max(r.step, v.step),
          started_at: r.started_at ?? (v.state === "queued" ? null : ctx.now),
          finished_at: terminal ? ctx.now : null,
          error: v.error ?? (terminal ? r.error : null),
          outcome: v.outcome ?? r.outcome,
          dispatched: true,
          deadline_at: r.deadline_at ?? ctx.now + runLimitMs(st.runBody(r), r.wall_clock_seconds)
        }
        if (canonicalJson(next) === canonicalJson(r)) return { ok: true, state, value: publicRun(r), changed: false }
        st.putRun(next)
        const outbox = [runOutbox(next)]
        if (terminal) {
          outbox.push(...continueAfter(st, state, next, ctx.now))
          st.pruneFinished(MAX_FINISHED_RUNS)
        }
        return { ok: true, state: st.head(state), value: publicRun(next), outbox, writes: st.writes() }
      }

      case "scheduler.run_policy": {
        const d = decodeParams<RunPolicy>(internalByName.get(op)!, params)
        if (!d.ok) return d
        return reduceRunPolicy(state, st, d.value, (automation) => cancelQueued(st, automation, ctx.now, "your team no longer allows automation runs (agents.allowedClasses)"))
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
