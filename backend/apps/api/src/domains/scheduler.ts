import { canonicalJson, type Domain, type Principal, type ReduceResult } from "@cmux/ownership"
import {
  AutomationCreate,
  AutomationDelete,
  AutomationImport,
  AutomationTeleportAbort,
  AutomationTeleportBegin,
  AutomationTeleportComplete,
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
import { automationDestinationError } from "../teleport-destination.ts"
import { actorOf, appendAudit, AUDITED_OPS, automationOfOp, summaryOf } from "./scheduler-audit.ts"
import { refusal, type Need } from "./scheduler-access.ts"
import { planFire } from "./scheduler-catchup.ts"
import { admit, decodeParams, reject, requirePersonalTeamAdmin } from "./common.ts"
import { automationTrigger, isAutomationPrincipal } from "./scheduler-chain.ts"
import { automationOutbox, chargeTo, countDeploy, invalidBody, reduceDeploy } from "./scheduler-code.ts"
import type { RunBucket } from "./scheduler-limits.ts"
import { reduceRowsMigrate } from "./scheduler-migrate.ts"
import { reduceRunPolicy, runPolicyRefusal, type RunPolicy } from "./scheduler-policy.ts"
import { isLegacyHead, movedOf, publicRun, type RunRow } from "./scheduler-rows.ts"
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
  /** The member this run's AI cost counts against (cx-ds09i): who started it, else who last deployed or enabled the automation. */
  readonly charged_user?: string
}

/** A change that alters what runs or when (not the name or description): its editor pays for the automation's runs. */
const effective = (a: Automation, b: Automation) =>
  (["triggers", "enabled", "budget", "target", "concurrency", "body"] as const).some((k) => canonicalJson(k === "triggers" ? a.triggers.map((t) => t.spec) : a[k]) !== canonicalJson(k === "triggers" ? b.triggers.map((t) => t.spec) : b[k]))

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
  /** Per automation, the member who last created, deployed or enabled it: scheduled and delivered runs are charged to them (cx-ds09i). */
  readonly charged_to?: Readonly<Record<string, string>>
  /** Automation rows (at most MAX_AUTOMATIONS). */
  readonly automation_count?: number
  /** Ids of the open (not terminal) runs, oldest first (at most MAX_OPEN_RUNS_PER_TEAM). */
  readonly open_runs?: ReadonlyArray<string>
  /** Finished run rows kept (MAX_FINISHED_RUNS after each prune). */
  readonly finished_count?: number
  /** Row order of the newest automation or run row (keyset paging, prune order). */
  readonly row_seq?: number
  /** Audit rows kept (scheduler-audit.ts, at most MAX_AUDIT). */
  readonly audit_count?: number
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

  reduce: (state, op, params, ctx): ReduceResult<SchedulerState> => withAudit(op, params, ctx, reduceOp(state, op, params, ctx))
}

/**
 * Appends the audit entry of a change a person, install or agent made (scheduler-audit.ts) to
 * the op's own commit, so an op and its entry land together or not at all.
 */
const withAudit = (op: string, params: unknown, ctx: Parameters<Domain<SchedulerState>["reduce"]>[3], r: ReduceResult<SchedulerState>): ReduceResult<SchedulerState> => {
  if (!r.ok || r.changed === false || !AUDITED_OPS.has(op) || ctx.principal.kind === "system") return r
  const automation = automationOfOp(params, r.value)
  if (!automation) return r
  const a = appendAudit(r.state, ctx.rows, { at: ctx.now, actor: actorOf(ctx.principal), op, automation, summary: summaryOf(op, params, r.value) })
  return { ...r, state: a.state, writes: [...(r.writes ?? []), ...a.writes] }
}

/** A run row for slots the catch-up policy will never run: visible, never a silent drop. */
const missedRun = (st: SchedulerStore, a: Automation, trigger: string, scheduledAt: number, count: number, policy: string, ctx: { newId(p: string): string; now: number }): RunRecord => {
  const run: RunRecord = {
    id: ctx.newId("run"),
    automation: a.id,
    automation_version: a.version,
    owner: a.owner,
    trigger: { id: trigger, type: "cron", scheduled_at: scheduledAt },
    state: "skipped",
    step: -1,
    created_at: ctx.now,
    started_at: null,
    finished_at: ctx.now,
    error: { code: "run.missed", message: `${count} scheduled ${count === 1 ? "time" : "times"} missed (catch-up ${policy})` },
    outcome: null,
    dispatched: false,
    body: a.body
  }
  st.addRun(run)
  st.pruneFinished(MAX_FINISHED_RUNS)
  return run
}

/** The access refusal for `need` on automation `id` (scheduler-access.ts), or undefined. */
const denied = (state: SchedulerState, st: SchedulerStore, p: Principal, id: unknown, need: Need) =>
  refusal(p, ownerOf(state, p), typeof id === "string" ? st.automation(id) : undefined, need)

const handoffPending = () => reject("automation.handoff_pending", "this automation is moving to another place; wait for the move to finish or abort it")

const reduceOp = (state: SchedulerState, op: string, params: unknown, ctx: Parameters<Domain<SchedulerState>["reduce"]>[3]): ReduceResult<SchedulerState> => {
  {
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
          next_run_at: null,
          sharing: v.sharing ?? "team",
          ...(v.editors?.length ? { editors: [...new Set(v.editors)] } : {}),
          catch_up: v.catch_up ?? "latest",
          home: "cloud" as const,
          epoch: 1,
          last_slot: null
        })
        st.putAutomation(a)
        return { ok: true, state: st.head({ ...chargeTo(state, a.id, p.user), owner, ...(counted.deploys ? { deploys: counted.deploys } : {}) }), value: a, outbox: [automationOutbox(a)], writes: st.writes() }
      }

      case "automation.update": {
        const d = decodeParams<typeof AutomationUpdate.params.Type>(AutomationUpdate, params)
        if (!d.ok) return d
        const v = d.value
        const blocked = denied(state, st, p, v.automation, v.sharing !== undefined || v.editors !== undefined ? "share" : "edit")
        if (blocked) return { ok: false, ...blocked }
        const a = st.automationFull(v.automation)
        if (!a) return reject("selector.not_found", "automation not found")
        if (a.handoff) return handoffPending()
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
          budget: v.budget ?? a.budget,
          ...(v.sharing !== undefined ? { sharing: v.sharing } : {}),
          ...(v.editors !== undefined ? { editors: [...new Set(v.editors)] } : {}),
          ...(v.catch_up !== undefined ? { catch_up: v.catch_up } : {})
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
          // Any effective change (triggers, enabled, budget, target, concurrency, body) makes the editor the member scheduled runs are charged to (review P2).
          state: st.head({ ...(p.user && effective(a, draft) ? chargeTo(state, a.id, p.user) : state), ...(counted.deploys ? { deploys: counted.deploys } : {}) }),
          value: next,
          outbox: [automationOutbox(next), ...stopped],
          writes: st.writes()
        }
      }

      case "automation.delete": {
        const d = decodeParams<typeof AutomationDelete.params.Type>(AutomationDelete, params)
        if (!d.ok) return d
        const blocked = denied(state, st, p, d.value.automation, "edit")
        if (blocked) return { ok: false, ...blocked }
        const a = st.automation(d.value.automation)
        if (!a) return reject("selector.not_found", "automation not found")
        const chains = { ...state.chains }
        for (const t of a.triggers) delete chains[t.id]
        const stopped = cancelQueued(st, a.id, ctx.now, "the automation was deleted")
        st.deleteAutomation(a.id)
        const { [a.id]: _charged, ...charged_to } = state.charged_to ?? {}
        return {
          ok: true,
          state: st.head({ ...state, chains, charged_to }),
          value: { automation: a.id },
          outbox: [{ kind: "automation.delete", entity: a.id, payload: { id: a.id } }, ...stopped],
          writes: st.writes()
        }
      }

      case "automation.deploy": {
        const blocked = denied(state, st, p, (params as { automation?: unknown } | null)?.automation, "edit")
        if (blocked) return { ok: false, ...blocked }
        return reduceDeploy(state, st, params, ctx)
      }

      case "automation.run": {
        const d = decodeParams<typeof AutomationRunNow.params.Type>(AutomationRunNow, params)
        if (!d.ok) return d
        // A run's own principal (an op step) starts runs by the chain rules, not by membership.
        const blocked = isAutomationPrincipal(p) ? undefined : denied(state, st, p, d.value.automation, "view")
        if (blocked) return { ok: false, ...blocked }
        const a = st.automationFull(d.value.automation)
        if (!a) return reject("selector.not_found", "automation not found")
        if (a.handoff) return handoffPending()
        const chained = isAutomationPrincipal(p) ? automationTrigger(state, st.rows, p, a) : undefined
        if (chained && "ok" in chained) return chained
        // A person's (or their install's) manual run is charged to them; an automation-started run to its automation's member.
        const r = startRun(st, chained ? { ...state, automation_trees: chained.trees } : state, a, chained?.trigger ?? { id: a.triggers.find((t) => t.spec.type === "manual")?.id ?? null, type: "manual" }, ctx, chained ? chained.charged_user : p.user)
        if ("rejected" in r) return r.rejected
        return { ok: true, state: st.head(r.state), value: publicRun(r.run), outbox: r.outbox, writes: st.writes() }
      }

      case "automation.fire": {
        const d = decodeParams<{ automation: string; trigger: string; scheduled_at: number }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const a = st.automation(d.value.automation)
        const t = a?.triggers.find((x) => x.id === d.value.trigger)
        // Stale: deleted, disabled, edited, or already advanced. A replayed alarm lands here.
        // A fenced automation (a teleport in progress) never fires here (docs/automations-teleport-teams.md).
        if (!a || !t || !a.enabled || a.handoff || t.status !== "active" || t.next_at !== d.value.scheduled_at) return { ok: true, state, value: { stale: true }, changed: false }
        const spec = t.spec
        // The catch-up policy decides what a late fire runs (scheduler-catchup.ts); every slot it drops is a visible missed run.
        const plan = spec.type === "cron" ? planFire(spec.expr, spec.tz, d.value.scheduled_at, ctx.now, a.catch_up ?? "latest") : { run: d.value.scheduled_at, missed: 0, next_at: null, last_slot: d.value.scheduled_at }
        st.putAutomationRow(withNextRun({ ...a, last_slot: plan.last_slot, triggers: a.triggers.map((x) => (x.id === t.id ? { ...x, next_at: plan.next_at } : x)) }))
        const updated = st.automationFull(a.id)!
        const missed = plan.missed > 0 ? [runOutbox(missedRun(st, updated, t.id, d.value.scheduled_at, plan.missed, a.catch_up ?? "latest", ctx))] : []
        if (plan.run === null) return { ok: true, state: st.head(state), value: { skipped: "run.missed" }, outbox: [automationOutbox(updated), ...missed], writes: st.writes() }
        // Runs denied by team policy: the schedule moves on and no run starts (a retry would loop).
        // Not synced yet: a retryable refusal, the alarm retries after SchedulerDO pulls the policy.
        const refused = runPolicyRefusal(state.run_policy)
        if (refused?.code === "policy.denied") return { ok: true, state: st.head(state), value: { skipped: "policy.denied" }, outbox: [automationOutbox(updated)], writes: st.writes() }
        if (refused) return refused
        const r = startRun(st, state, updated, { id: t.id, type: spec.type, scheduled_at: plan.run }, ctx)
        if ("rejected" in r) return r.rejected
        return { ok: true, state: st.head(r.state), value: publicRun(r.run), outbox: [automationOutbox(updated), ...missed, ...r.outbox], writes: st.writes() }
      }

      case "automation.deliver": {
        const d = decodeParams<{ automation: string; trigger: string; delivery_id: string }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const row = st.automation(d.value.automation)
        const t = row?.triggers.find((x) => x.id === d.value.trigger)
        if (!row || !t || !row.enabled || row.handoff || t.status !== "active") return { ok: true, state, value: { stale: true }, changed: false }
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

      case "automation.import": {
        const d = decodeParams<typeof AutomationImport.params.Type>(AutomationImport, params)
        if (!d.ok) return d
        const v = d.value
        const owner = ownerOf(state, p)
        if (!owner || !p.user) return reject("auth.forbidden", "automation.import needs a user in a team")
        // One copy per handoff id: a client that lost its idempotency key still finds the first copy.
        const prior = st.allAutomations().find((x) => x.origin?.handoff === v.handoff.id)
        if (prior) {
          const blocked = refusal(p, owner, prior, "view")
          return blocked ? { ok: false, ...blocked } : { ok: true, state, value: st.automationFull(prior.id)!, changed: false }
        }
        if ((state.automation_count ?? 0) >= MAX_AUTOMATIONS) return reject("automation.limit", `at most ${MAX_AUTOMATIONS} automations per team`)
        const bad = validateTriggers(v.triggers) ?? invalidBody(v.body)
        if (bad) return bad
        const counted = countDeploy(state, undefined, v.body, ctx.now)
        if (!counted.ok) return counted.result
        const last = v.handoff.last_slot
        // The schedule resumes after the source's last fired slot: a slot inside the handoff fires by the catch-up policy, never twice.
        const triggers = storeTriggers(v.triggers, [], ctx).map((t) => (t.spec.type === "cron" && last !== null ? { ...t, next_at: nextFire(t.spec.expr, t.spec.tz, last) } : t))
        const a = withNextRun({
          id: ctx.newId("auto"),
          owner,
          name: v.name,
          description: v.description ?? "",
          enabled: v.enabled ?? true,
          version: 1,
          triggers,
          body: v.body,
          target: v.target ?? { kind: "cloud_vm" },
          concurrency: v.concurrency ?? { max: 1, on_limit: "queue" },
          budget: v.budget ?? {},
          created_by: p.user,
          created_at: ctx.now,
          updated_at: ctx.now,
          next_run_at: null,
          sharing: v.sharing ?? "team",
          ...(v.editors?.length ? { editors: [...new Set(v.editors)] } : {}),
          catch_up: v.catch_up ?? "latest",
          home: "cloud" as const,
          epoch: v.handoff.epoch,
          last_slot: last,
          origin: { handoff: v.handoff.id, from: v.handoff.from, source_id: v.handoff.source_id }
        })
        st.putAutomation(a)
        return { ok: true, state: st.head({ ...chargeTo(state, a.id, p.user), owner, ...(counted.deploys ? { deploys: counted.deploys } : {}) }), value: a, outbox: [automationOutbox(a)], writes: st.writes() }
      }

      case "automation.teleport.begin": {
        const d = decodeParams<typeof AutomationTeleportBegin.params.Type>(AutomationTeleportBegin, params)
        if (!d.ok) return d
        const v = d.value
        const where = automationDestinationError(v.handoff.to)
        if (where) return reject("validation.invalid", `handoff.${where}`)
        const blocked = denied(state, st, p, v.automation, "edit")
        if (blocked) return { ok: false, ...blocked }
        const a = st.automationFull(v.automation)!
        if (a.handoff) return a.handoff.id === v.handoff.id ? { ok: true, state, value: { automation: a, epoch: a.handoff.epoch, last_slot: a.last_slot ?? null }, changed: false } : handoffPending()
        const epoch = (a.epoch ?? 1) + 1
        const fenced = { ...a, handoff: { id: v.handoff.id, to: v.handoff.to, epoch, at: ctx.now } }
        st.putAutomation(withNextRun({ ...fenced, enabled: a.enabled }))
        const stopped = cancelQueued(st, a.id, ctx.now, `the automation is moving to ${v.handoff.to}`)
        const stored = st.automationFull(a.id)!
        return { ok: true, state: st.head(state), value: { automation: stored, epoch, last_slot: a.last_slot ?? null }, outbox: [automationOutbox(stored), ...stopped], writes: st.writes() }
      }

      case "automation.teleport.complete": {
        const d = decodeParams<typeof AutomationTeleportComplete.params.Type>(AutomationTeleportComplete, params)
        if (!d.ok) return d
        const v = d.value
        const gone = movedOf(st.rows, v.automation)
        if (gone && !st.automation(v.automation)) return reject("automation.handoff_mismatch", `this automation already moved to ${gone.moved_to}`)
        const blocked = denied(state, st, p, v.automation, "edit")
        if (blocked) return { ok: false, ...blocked }
        const a = st.automation(v.automation)!
        if (!a.handoff || a.handoff.id !== v.handoff) return reject("automation.handoff_mismatch", "no move with this handoff id is pending")
        const moved = { id: a.id, name: a.name, moved_to: a.handoff.to, moved_id: v.moved_id, epoch: a.handoff.epoch, moved_at: ctx.now }
        const chains = { ...state.chains }
        for (const t of a.triggers) delete chains[t.id]
        st.deleteAutomation(a.id)
        st.putMoved(moved)
        const { [a.id]: _charged, ...charged_to } = state.charged_to ?? {}
        return { ok: true, state: st.head({ ...state, chains, charged_to }), value: moved, outbox: [{ kind: "automation.delete", entity: a.id, payload: { id: a.id } }], writes: st.writes() }
      }

      case "automation.teleport.abort": {
        const d = decodeParams<typeof AutomationTeleportAbort.params.Type>(AutomationTeleportAbort, params)
        if (!d.ok) return d
        const blocked = denied(state, st, p, d.value.automation, "edit")
        if (blocked) return { ok: false, ...blocked }
        const a = st.automationFull(d.value.automation)!
        if (!a.handoff || a.handoff.id !== d.value.handoff) return reject("automation.handoff_mismatch", "no move with this handoff id is pending")
        const { handoff: _h, ...rest } = a
        // Slots missed while fenced fire by the catch-up policy from the next wake.
        st.putAutomation(withNextRun(rest))
        const stored = st.automationFull(a.id)!
        return { ok: true, state: st.head(state), value: stored, outbox: [automationOutbox(stored)], writes: st.writes() }
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
