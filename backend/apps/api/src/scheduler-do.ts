import type { Principal, RejectFrame, ResultFrame } from "@cmux/ownership"
import type { Body, Run } from "@cmux/protocol"
import { dispatchable, dueFires, publicRun, schedulerDomain, type SchedulerState } from "./domains/scheduler.ts"
import type { Env } from "./env.ts"
import type { DeliverResult } from "./ingress/automation-hook.ts"
import { OwnerDO, type ReadResult, type SubmitResult } from "./owner-do.ts"

/** What a run's Workflow instance receives. The body is the version that fired. */
export interface AutomationRunParams {
  readonly owner: string
  readonly run: string
  readonly automation: string
  readonly automation_version: number
  readonly trigger: Run["trigger"]
  readonly body: Body
  /** What triggered the run, when it carries data (a webhook delivery's body). */
  readonly input?: unknown
}

export interface RunReport {
  readonly run: string
  readonly state: Run["state"]
  readonly step: number
  readonly error?: { readonly code: string; readonly message: string }
  readonly outcome?: { readonly goal_met: boolean; readonly summary?: string }
}

const MAX_RETRY_MS = 5 * 60_000

const rejected = (r: SubmitResult): RejectFrame | undefined => r.frames.find((f): f is RejectFrame => f.t === "reject")

/** Workflows refuses a second instance with the same id; that is our dedupe, not a failure. */
const alreadyExists = (e: unknown) => /already exists|already_exists|duplicate/i.test(String(e))

/**
 * SchedulerDO: one per owner team (decision D13). Owns automation definitions,
 * schedules and recent runs; fires due schedules from its alarm and starts one
 * Workflow instance per run (instance id = run id). Every fire and dispatch is
 * a system op with a deterministic key, so a repeated alarm replays.
 */
export class SchedulerDO extends OwnerDO<SchedulerState> {
  /** Backoff for fires and dispatches that failed in this instance's lifetime (a scheduling hint, not entity state). */
  private readonly retry = new Map<string, { attempts: number; at: number }>()

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env, schedulerDomain, "scheduler", (p) => ({
      identity: p.kind === "system" ? p.identity : (p.install ?? `user:${p.user}`),
      ...(p.kind ? { kind: p.kind } : {}),
      ...(p.user ? { user: p.user } : {}),
      ...(p.team ? { team: p.team } : {}),
      ...(p.install ? { install: p.install } : {}),
      ...(p.display_name ? { display_name: p.display_name } : {})
    }))
    // Trigger payloads wait here between the delivery and the Workflow start. They are
    // inputs, not entity state: never in events, snapshots or the ledger.
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS run_inputs (run TEXT PRIMARY KEY, json TEXT NOT NULL, created_at INTEGER NOT NULL)`)
  }

  protected read(state: SchedulerState, op: string, params: unknown, principal: Principal): ReadResult {
    if (!principal.team || (state.owner !== null && state.owner !== principal.team)) return { ok: false, code: "auth.forbidden", message: "not this team's scheduler" }
    const p = (params ?? {}) as { automation?: unknown; limit?: unknown }
    switch (op) {
      case "automation.list":
        return { ok: true, value: { owner: state.owner, automations: Object.values(state.automations).sort((a, b) => a.created_at - b.created_at) }, revision: "" }
      case "automation.get": {
        const a = typeof p.automation === "string" ? state.automations[p.automation] : undefined
        return a ? { ok: true, value: a, revision: "" } : { ok: false, code: "selector.not_found", message: "automation not found" }
      }
      case "automation.runs.list": {
        const limit = typeof p.limit === "number" && Number.isInteger(p.limit) ? Math.min(200, Math.max(1, p.limit)) : 50
        const runs = Object.values(state.runs)
          .filter((r) => typeof p.automation !== "string" || r.automation === p.automation)
          .sort((a, b) => b.created_at - a.created_at || (a.id < b.id ? 1 : -1))
          .slice(0, limit)
          .map(publicRun)
        return { ok: true, value: { runs }, revision: "" }
      }
      case "automation.webhook.get": {
        const params2 = (params ?? {}) as { automation?: unknown; trigger?: unknown }
        const a = typeof params2.automation === "string" ? state.automations[params2.automation] : undefined
        const t = a?.triggers.find((x) => x.id === params2.trigger)
        if (!a || !t || t.spec.type !== "webhook") return { ok: false, code: "selector.not_found", message: "webhook trigger not found" }
        // The Worker adds the path and the derived secret; the DO only proves the trigger exists in this team.
        return { ok: true, value: { owner: a.owner, automation: a.id, trigger: t.id }, revision: "" }
      }
      default:
        return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    }
  }

  protected maySubscribe(state: SchedulerState, principal: Principal): boolean {
    return Boolean(principal.team && (state.owner === null || state.owner === principal.team))
  }

  private retryAt(key: string): number | undefined {
    return this.retry.get(key)?.at
  }

  private failed(key: string, now: number, error: unknown) {
    const attempts = (this.retry.get(key)?.attempts ?? 0) + 1
    this.retry.set(key, { attempts, at: now + Math.min(MAX_RETRY_MS, 1000 * 2 ** attempts) })
    console.error(JSON.stringify({ msg: "scheduler step failed", stream: this.boundEngine?.stream, key, attempts, error: String(error) }))
  }

  protected override nextWakeAt(state: SchedulerState, now: number): number | null {
    let at: number | null = null
    const take = (t: number) => {
      if (at === null || t < at) at = t
    }
    for (const a of Object.values(state.automations)) {
      if (!a.enabled) continue
      for (const t of a.triggers) {
        if (t.status !== "active" || t.next_at === null) continue
        take(t.next_at > now ? t.next_at : (this.retryAt(fireKey(a.id, t.id, t.next_at)) ?? t.next_at))
      }
    }
    for (const r of dispatchable(state)) take(this.retryAt(dispatchKey(r.id)) ?? now)
    return at
  }

  protected override async onWake(now: number): Promise<void> {
    const engine = this.boundEngine
    if (!engine) return
    for (const f of dueFires(engine.currentState, now)) {
      const key = fireKey(f.automation, f.trigger, f.scheduled_at)
      if ((this.retryAt(key) ?? 0) > now) continue
      const r = rejected(this.submitSystem("automation.fire", f, key))
      if (r) this.failed(key, now, `${r.code}: ${r.message}`)
      else this.retry.delete(key)
    }
    for (const run of dispatchable(engine.currentState)) {
      const key = dispatchKey(run.id)
      if ((this.retryAt(key) ?? 0) > now) continue
      const stored = this.ctx.storage.sql.exec<{ json: string }>(`SELECT json FROM run_inputs WHERE run = ?`, run.id).toArray()[0]
      const params: AutomationRunParams = {
        owner: run.owner,
        run: run.id,
        automation: run.automation,
        automation_version: run.automation_version,
        trigger: run.trigger,
        body: run.body,
        ...(stored ? { input: JSON.parse(stored.json) as unknown } : {})
      }
      try {
        await this.env.AUTOMATION_RUN.create({ id: run.id, params })
      } catch (e) {
        if (!alreadyExists(e)) {
          this.failed(key, now, e)
          continue
        }
      }
      const r = rejected(this.submitSystem("run.dispatched", { run: run.id }, key))
      if (r) this.failed(key, now, `${r.code}: ${r.message}`)
      else {
        this.retry.delete(key)
        this.ctx.storage.sql.exec(`DELETE FROM run_inputs WHERE run = ?`, run.id)
      }
    }
  }

  /**
   * A verified webhook delivery (the Worker checked the signature first). The
   * ledger key `deliver:<automation>:<trigger>:<delivery>` makes a redelivery a
   * replay. Never creates storage for a team that has no scheduler yet.
   */
  async deliverWebhook(entity: string, trigger: string, delivery: string, input: unknown): Promise<DeliverResult> {
    const bound = this.ctx.storage.sql.exec<{ entity: string }>(`SELECT entity FROM do_entity WHERE id = 1`).toArray()[0]
    if (!bound || bound.entity !== entity) return { status: "unknown" }
    const engine = this.bind(entity)
    const a = Object.values(engine.currentState.automations).find((x) => x.triggers.some((t) => t.id === trigger && t.spec.type === "webhook"))
    if (!a) return { status: "unknown" }
    const res = this.submitSystem("automation.deliver", { automation: a.id, trigger, delivery_id: delivery }, `deliver:${a.id}:${trigger}:${delivery}`)
    const out = res.frames.find((f): f is ResultFrame => f.t === "result")
    if (!out) return { status: "disabled" }
    const value = out.value as { id?: string; state?: string; stale?: boolean }
    if (value.stale) return { status: "disabled" }
    if (out.replayed) return { status: "duplicate", ...(value.id ? { run: value.id } : {}) }
    if (value.state === "skipped") return { status: "skipped", ...(value.id ? { run: value.id } : {}) }
    if (value.id) this.ctx.storage.sql.exec(`INSERT OR REPLACE INTO run_inputs (run, json, created_at) VALUES (?, ?, ?)`, value.id, JSON.stringify(input ?? null), Date.now())
    return { status: "accepted", ...(value.id ? { run: value.id } : {}) }
  }

  /** RPC from a run's Workflow. One key per (run, state, step): a retried step replays. */
  async reportRun(entity: string, report: RunReport): Promise<{ ok: boolean; code?: string }> {
    this.bind(entity)
    const r = rejected(this.submitSystem("run.report", report, `report:${report.run}:${report.state}:${report.step}`))
    return r ? { ok: false, code: r.code } : { ok: true }
  }
}

const fireKey = (automation: string, trigger: string, scheduledAt: number) => `fire:${automation}:${trigger}:${scheduledAt}`
const dispatchKey = (run: string) => `dispatch:${run}`
