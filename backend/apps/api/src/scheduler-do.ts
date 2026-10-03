import { createHash } from "node:crypto"
import type { OpFrame, OwnerFrame, Principal, RejectFrame, ResultFrame } from "@cmux/ownership"
import type { Body, Run } from "@cmux/protocol"
import { deadlineOf, dispatchable, dueFires, matchingEventTriggers, publicRun, schedulerDomain, TERMINAL, type SchedulerState } from "./domains/scheduler.ts"
import { codeRefOf, precheckCodeOp } from "./code-check.ts"
import type { CodeStorageError } from "./code-storage.ts"
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
/** Retry delay after a run limit refused a fire or a delivery (the bucket refills 5 tokens a second). */
const RATE_RETRY_MS = 1000
/** Deferred provider deliveries one team may hold. */
const MAX_DEFERRED = 1000
/** How long a delivery id is remembered for dedupe (longer than any provider's redelivery window). */
export const DELIVERY_RETENTION_MS = 30 * 24 * 3600_000
/** Trigger payloads kept for a run's input; larger ones are replaced by a truncation marker. */
const MAX_INPUT_BYTES = 256 * 1024

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
    // Backoff for failed fires, dispatches and deadline checks: persisted, so a restarted object
    // waits out the backoff instead of retrying at once.
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS retry_state (key TEXT PRIMARY KEY, attempts INTEGER NOT NULL, at INTEGER NOT NULL)`)
    // Webhook and provider-event dedupe, independent of the request ledger (7-day window):
    // providers may redeliver later (GitHub signs no timestamp), so delivery keys live 30 days.
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS seen_deliveries (key TEXT PRIMARY KEY, run TEXT, at INTEGER NOT NULL)`)
    ctx.storage.sql.exec(`CREATE INDEX IF NOT EXISTS seen_deliveries_at ON seen_deliveries (at)`)
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS run_inputs (run TEXT PRIMARY KEY, json TEXT NOT NULL, created_at INTEGER NOT NULL)`)
    // Provider events refused by the team's run limits: providers do not redeliver after a 2xx, so the
    // owner keeps them and retries from its alarm (same ledger key, so a later success replays once).
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS deferred_deliveries (key TEXT PRIMARY KEY, automation TEXT NOT NULL, trigger TEXT NOT NULL, delivery TEXT NOT NULL, input TEXT NOT NULL, at INTEGER NOT NULL)`)
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
      case "automation.settings.get":
        return { ok: true, value: state.settings ?? { agent_run_default_seconds: null }, revision: "" }
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
    const row = this.ctx.storage.sql.exec<{ at: number }>(`SELECT at FROM retry_state WHERE key = ?`, key).toArray()[0]
    return row ? Number(row.at) : undefined
  }

  private failed(key: string, now: number, error: unknown) {
    const prior = this.ctx.storage.sql.exec<{ attempts: number }>(`SELECT attempts FROM retry_state WHERE key = ?`, key).toArray()[0]
    const attempts = Number(prior?.attempts ?? 0) + 1
    this.ctx.storage.sql.exec(
      `INSERT INTO retry_state (key, attempts, at) VALUES (?, ?, ?) ON CONFLICT (key) DO UPDATE SET attempts = excluded.attempts, at = excluded.at`,
      key,
      attempts,
      now + Math.min(MAX_RETRY_MS, 1000 * 2 ** attempts)
    )
    console.error(JSON.stringify({ msg: "scheduler step failed", stream: this.boundEngine?.stream, key, attempts, error: String(error) }))
  }

  private seen(key: string): { run: string | null } | undefined {
    const row = this.ctx.storage.sql.exec<{ run: string | null }>(`SELECT run FROM seen_deliveries WHERE key = ?`, key).toArray()[0]
    return row ? { run: row.run } : undefined
  }

  private remember(key: string, run: string | undefined) {
    this.ctx.storage.sql.exec(`INSERT OR IGNORE INTO seen_deliveries (key, run, at) VALUES (?, ?, ?)`, key, run ?? null, Date.now())
  }

  private succeeded(key: string) {
    this.ctx.storage.sql.exec(`DELETE FROM retry_state WHERE key = ?`, key)
  }

  /** A run limit (not a failure): try again in a second, without backoff or an error log. */
  private retrySoon(key: string, now: number) {
    this.ctx.storage.sql.exec(
      `INSERT INTO retry_state (key, attempts, at) VALUES (?, 0, ?) ON CONFLICT (key) DO UPDATE SET at = excluded.at`,
      key,
      now + RATE_RETRY_MS
    )
  }

  /**
   * One event delivery for one trigger. "limited" when the team's run limits refused it (the
   * caller defers it); "done" otherwise (started, replayed, stale or skipped).
   */
  private deliverOne(automation: string, trigger: string, delivery: string, input: string): "started" | "done" | "limited" {
    const key = deliverKey(automation, trigger, delivery)
    if (this.seen(key)) return "done"
    const res = this.submitSystem("automation.deliver", { automation, trigger, delivery_id: delivery }, key)
    const out = res.frames.find((f): f is ResultFrame => f.t === "result")
    // Rate limits and a policy not loaded yet are temporary: the event waits; a deny drops it.
    if (!out) return rejected(res)?.code === "rate.limited" || rejected(res)?.code === "policy.pending" ? "limited" : "done"
    const value = out.value as { id?: string; state?: string; stale?: boolean } | undefined
    if (!value?.stale) this.remember(key, value?.id)
    if (out.replayed || !value?.id || value.stale || value.state === "skipped") return "done"
    this.ctx.storage.sql.exec(`INSERT OR REPLACE INTO run_inputs (run, json, created_at) VALUES (?, ?, ?)`, value.id, input, Date.now())
    return "started"
  }

  private defer(automation: string, trigger: string, delivery: string, input: string, now: number) {
    const count = Number(this.ctx.storage.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM deferred_deliveries`).toArray()[0]?.n ?? 0)
    if (count >= MAX_DEFERRED) {
      console.error(JSON.stringify({ msg: "deferred delivery dropped: too many waiting", stream: this.boundEngine?.stream, automation, trigger }))
      return
    }
    this.ctx.storage.sql.exec(
      `INSERT OR IGNORE INTO deferred_deliveries (key, automation, trigger, delivery, input, at) VALUES (?, ?, ?, ?, ?, ?)`,
      deliverKey(automation, trigger, delivery), automation, trigger, delivery, input, now + RATE_RETRY_MS
    )
  }

  /** Retries deferred deliveries that are due, oldest first, until the limits refuse again. */
  private retryDeferred(now: number) {
    const due = this.ctx.storage.sql.exec<{ key: string; automation: string; trigger: string; delivery: string; input: string }>(
      `SELECT key, automation, trigger, delivery, input FROM deferred_deliveries WHERE at <= ? ORDER BY at LIMIT 50`, now
    ).toArray()
    for (const d of due) {
      if (this.deliverOne(d.automation, d.trigger, d.delivery, d.input) === "limited") {
        this.ctx.storage.sql.exec(`UPDATE deferred_deliveries SET at = ? WHERE at <= ?`, now + RATE_RETRY_MS, now)
        return
      }
      this.ctx.storage.sql.exec(`DELETE FROM deferred_deliveries WHERE key = ?`, d.key)
    }
  }

  /** Inputs of runs that are gone or finished, and stale backoff rows, leave with the replay window. */
  protected override onPrune(before: number): void {
    const runs = this.boundEngine?.currentState.runs ?? {}
    for (const row of this.ctx.storage.sql.exec<{ run: string }>(`SELECT run FROM run_inputs WHERE created_at < ?`, before).toArray()) {
      const r = runs[row.run]
      // A queued run may wait for weeks behind a long one; its input stays until it ends.
      if (!r || TERMINAL.has(r.state)) this.ctx.storage.sql.exec(`DELETE FROM run_inputs WHERE run = ?`, row.run)
    }
    this.ctx.storage.sql.exec(`DELETE FROM retry_state WHERE at < ?`, before)
    this.ctx.storage.sql.exec(`DELETE FROM seen_deliveries WHERE at < ?`, Date.now() - DELIVERY_RETENTION_MS)
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
    const deferred = this.ctx.storage.sql.exec<{ at: number | null }>(`SELECT MIN(at) AS at FROM deferred_deliveries`).toArray()[0]?.at
    if (deferred !== null && deferred !== undefined) take(Number(deferred))
    const oldestSeen = this.ctx.storage.sql.exec<{ at: number | null }>(`SELECT MIN(at) AS at FROM seen_deliveries`).toArray()[0]?.at
    if (oldestSeen !== null && oldestSeen !== undefined) take(Number(oldestSeen) + DELIVERY_RETENTION_MS)
    // One wake per open run at its deadline; a run that reports its end never causes it.
    for (const r of Object.values(state.runs)) {
      const deadline = deadlineOf(r)
      if (deadline !== undefined && !TERMINAL.has(r.state)) take(this.retryAt(deadlineKey(r.id)) ?? deadline)
    }
    return at
  }

  /**
   * Runs past their deadline (set at dispatch from the budget or the body's
   * sleeps). A Workflow still going is terminated and the run fails; one that
   * ended without its final report (killed, or the report failed) is dead.
   */
  private async enforceDeadlines(now: number) {
    const engine = this.boundEngine!
    // Runs in backoff are filtered before the batch cap, so the rest always get their check.
    const due = Object.values(engine.currentState.runs).filter((r) => {
      const deadline = deadlineOf(r)
      return deadline !== undefined && deadline <= now && !TERMINAL.has(r.state) && (this.retryAt(deadlineKey(r.id)) ?? 0) <= now
    })
    for (const r of due.slice(0, 20)) {
      const key = deadlineKey(r.id)
      let status: string
      try {
        const instance = await this.env.AUTOMATION_RUN.get(r.id)
        status = (await instance.status()).status
        if (status === "queued" || status === "running" || status === "paused" || status === "waiting" || status === "waitingForPause") {
          await instance.terminate()
          status = "terminated_at_deadline"
        }
      } catch (e) {
        if (!/not.?found/i.test(String(e))) {
          this.failed(key, now, e)
          continue
        }
        status = "unknown"
      }
      const budget = r.wall_clock_seconds
      const report =
        status === "terminated_at_deadline"
          ? { run: r.id, state: "failed", step: r.step, error: budget !== undefined ? { code: "budget.wall_clock", message: `ran longer than ${budget} s` } : { code: "run.deadline", message: "ran past its deadline" } }
          : { run: r.id, state: "dead", step: r.step, error: { code: "run.dead", message: `the run's Workflow is ${status} without a final report` } }
      const res = this.submitSystem("run.report", report, `report:${r.id}:deadline`)
      if (res.frames.some((f) => f.t === "reject")) this.failed(key, now, "deadline report refused")
      else this.succeeded(key)
    }
  }

  protected override async onWake(now: number): Promise<void> {
    const engine = this.boundEngine
    if (!engine) return
    await this.enforceDeadlines(now)
    await this.ensureRunPolicy(engine.currentState.owner ?? engine.stream.slice("scheduler:".length))
    for (const f of dueFires(engine.currentState, now)) {
      const key = fireKey(f.automation, f.trigger, f.scheduled_at)
      if ((this.retryAt(key) ?? 0) > now) continue
      const r = rejected(this.submitSystem("automation.fire", f, key))
      if (r?.code === "rate.limited") this.retrySoon(key, now)
      else if (r) this.failed(key, now, `${r.code}: ${r.message}`)
      else this.succeeded(key)
    }
    this.retryDeferred(now)
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
      // The create awaited: a policy deny, disable or delete may have cancelled the run meanwhile.
      // Its Workflow must not run on: terminate it now (run.report also stops it, see reportRun).
      if (TERMINAL.has(engine.currentState.runs[run.id]?.state ?? "cancelled")) {
        await this.terminateInstance(run.id)
        this.succeeded(key)
        continue
      }
      const r = rejected(this.submitSystem("run.dispatched", { run: run.id }, key))
      if (r) this.failed(key, now, `${r.code}: ${r.message}`)
      else {
        this.succeeded(key)
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
    const key = deliverKey(a.id, trigger, delivery)
    const prior = this.seen(key)
    if (prior) return { status: "duplicate", ...(prior.run ? { run: prior.run } : {}) }
    await this.ensureRunPolicy(entity)
    const res = this.submitSystem("automation.deliver", { automation: a.id, trigger, delivery_id: delivery }, key)
    const out = res.frames.find((f): f is ResultFrame => f.t === "result")
    if (!out) {
      const code = rejected(res)?.code
      return { status: code === "rate.limited" ? "rate_limited" : code === "policy.denied" ? "policy_denied" : code === "policy.pending" ? "policy_pending" : "disabled" }
    }
    const value = out.value as { id?: string; state?: string; stale?: boolean }
    if (value.stale) return { status: "disabled" }
    this.remember(key, value.id)
    if (out.replayed) return { status: "duplicate", ...(value.id ? { run: value.id } : {}) }
    if (value.state === "skipped") return { status: "skipped", ...(value.id ? { run: value.id } : {}) }
    if (value.id) this.ctx.storage.sql.exec(`INSERT OR REPLACE INTO run_inputs (run, json, created_at) VALUES (?, ?, ?)`, value.id, JSON.stringify(input ?? null), Date.now())
    return { status: "accepted", ...(value.id ? { run: value.id } : {}) }
  }

  /**
   * A provider event from one of this team's connections (ConnectionDO.ingest).
   * Each matching `event` trigger gets one run, keyed
   * deliver:<automation>:<trigger>:<connection>:<delivery>, so a provider
   * redelivery replays. The payload is kept for the run as its input (capped).
   */
  async deliverEvent(
    entity: string,
    ev: { connection: string; sharing: "private" | "team"; created_by: string; provider: string; event: string; delivery_id: string; payload: unknown }
  ): Promise<{ runs: number }> {
    const bound = this.ctx.storage.sql.exec<{ entity: string }>(`SELECT entity FROM do_entity WHERE id = 1`).toArray()[0]
    if (!bound || bound.entity !== entity) return { runs: 0 }
    const engine = this.bind(entity)
    await this.ensureRunPolicy(entity)
    let runs = 0
    const text = JSON.stringify({ provider: ev.provider, event: ev.event, delivery_id: ev.delivery_id, body: ev.payload })
    const input = new TextEncoder().encode(text).byteLength <= MAX_INPUT_BYTES ? text : JSON.stringify({ provider: ev.provider, event: ev.event, delivery_id: ev.delivery_id, truncated: true })
    const now = Date.now()
    for (const { automation, trigger } of matchingEventTriggers(engine.currentState, ev)) {
      const delivery = `${ev.connection}:${ev.delivery_id}`
      const r = this.deliverOne(automation, trigger, delivery, input)
      if (r === "started") runs++
      if (r === "limited") this.defer(automation, trigger, delivery, input, now)
    }
    this.scheduleAlarm()
    return { runs }
  }

  /**
   * Ops that pin automation code (create, update, deploy with a code body): the commit and its
   * bundle must exist in this team's repository before the reducer sees the op. Replays and
   * denied ops skip the check (OwnerEngine.gate), so a decided key always gets its original
   * answer. The check awaits code.storage; if the automation's path changed meanwhile, the op is
   * refused as retryable instead of pinning a path that was never checked.
   */
  async submitCode(entity: string, principal: Principal, frame: OpFrame): Promise<SubmitResult | { readonly refusal: CodeStorageError }> {
    const engine = this.bind(entity)
    if (codeRefOf(frame.op, frame.params) && engine.gate(principal, frame) === undefined) {
      const pathOf = (id: string) => {
        const b = engine.currentState.automations[id]?.body
        return b?.type === "code" ? b.ref.path : undefined
      }
      const id = (frame.params as { automation?: unknown } | null)?.automation
      const before = typeof id === "string" ? pathOf(id) : undefined
      const refusal = await precheckCodeOp(this.env, entity, frame.op, frame.params, async (a) => engine.currentState.automations[a])
      // The await lets other requests in: a same-key twin may have committed meanwhile; then replay it.
      if (refusal && engine.gate(principal, frame) !== "replay") return { refusal }
      if (typeof id === "string" && pathOf(id) !== before) return { refusal: { code: "code.unavailable", message: "the automation changed during the code check; retry", retryable: true } }
    }
    return this.submit(entity, principal, frame)
  }

  /** RPC from TeamDO: the run class of agents.allowedClasses at a policy version (newest wins). */
  async applyRunPolicy(entity: string, policy: { version: number; runs_allowed: boolean }): Promise<{ ok: boolean; message?: string }> {
    this.bind(entity)
    const r = rejected(this.submitSystem("scheduler.run_policy", policy, `run-policy:${policy.version}:${policy.runs_allowed ? 1 : 0}`))
    return r ? { ok: false, message: `${r.code}: ${r.message}` } : { ok: true }
  }

  /** RPC from a run's Workflow. One key per (run, state, step): a retried step replays. */
  async reportRun(entity: string, report: RunReport): Promise<{ ok: boolean; code?: string; stopped?: boolean }> {
    const engine = this.bind(entity)
    // A run that ended here (cancelled by a policy deny, disable or delete) stops its Workflow.
    const before = engine.currentState.runs[report.run]
    if (before && TERMINAL.has(before.state) && !TERMINAL.has(report.state)) return { ok: true, stopped: true }
    const r = rejected(this.submitSystem("run.report", report, `report:${report.run}:${report.state}:${report.step}`))
    return r ? { ok: false, code: r.code } : { ok: true }
  }

  /** Stops a run's Workflow instance; a missing or finished instance is fine. */
  private async terminateInstance(run: string) {
    try {
      await (await this.env.AUTOMATION_RUN.get(run)).terminate()
    } catch (e) {
      console.error(JSON.stringify({ msg: "terminate refused", stream: this.boundEngine?.stream, run, error: String(e) }))
    }
  }

  /**
   * Fail closed (scheduler-policy.ts): before work that can create runs, a scheduler without the
   * team's run policy asks TeamDO for it once. A failure leaves runs refused (policy.pending,
   * retryable); TeamDO's own push also delivers it later.
   */
  private async ensureRunPolicy(entity: string): Promise<void> {
    const engine = this.boundEngine
    if (!engine || engine.currentState.run_policy !== undefined) return
    try {
      const team = this.env.TEAM_DO.get(this.env.TEAM_DO.idFromName(entity)) as unknown as { runPolicy(e: string): Promise<{ version: number; runs_allowed: boolean }> }
      const p = await team.runPolicy(entity)
      this.submitSystem("scheduler.run_policy", p, `run-policy:${p.version}:${p.runs_allowed ? 1 : 0}`)
    } catch (e) {
      console.error(JSON.stringify({ msg: "run policy pull failed", stream: engine.stream, error: String(e) }))
    }
  }

  /** HTTP ops: a manual run pulls the run policy first, so the first run is not refused as pending. */
  override async submit(entity: string, principal: Principal, frame: OpFrame): Promise<SubmitResult> {
    this.bind(entity)
    if (frame.op === "automation.run") await this.ensureRunPolicy(entity)
    return super.submit(entity, principal, frame)
  }

  /** Any path (wire, HTTP) refused as policy.pending: pull the policy so the client's retry passes. */
  protected override afterOp(_principal: Principal, _op: string, frames: ReadonlyArray<OwnerFrame>) {
    const entity = this.boundEngine?.currentState.owner
    if (entity && frames.some((f) => f.t === "reject" && f.code === "policy.pending")) this.ctx.waitUntil(this.ensureRunPolicy(entity))
  }
}

const fireKey = (automation: string, trigger: string, scheduledAt: number) => `fire:${automation}:${trigger}:${scheduledAt}`
/** Ledger keys stay under the engine's 128-character limit: the delivery id goes in hashed. */
export const deliverKey = (automation: string, trigger: string, delivery: string) =>
  `deliver:${automation}:${trigger}:${createHash("sha256").update(delivery).digest("base64url").slice(0, 32)}`
const dispatchKey = (run: string) => `dispatch:${run}`
const deadlineKey = (run: string) => `deadline:${run}`
