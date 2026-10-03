import type { Domain, OpFrame, Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult, type SubmitResult } from "./owner-do.ts"
import { DriverError, providerRefusal, teamVmDriver } from "./team-vm-driver.ts"
import { MAX_ATTEMPTS, teamVmDomain, teamVmSlug, teamVmWakeAt, type TeamVmState } from "./domains/team-vm.ts"

/** How long the request path waits for the provider before it answers with the current state. */
const ENSURE_AWAKE_WAIT_MS = 25_000

/**
 * TeamVmDO, one per team (plans/cmux-next/team-vm-plan.md S2): the team VM record (provider id,
 * epoch, observed state), wake leases, and the provider calls that create and resume the VM.
 * The reducer never calls the provider; this object runs one provider call at a time (single
 * flight) and commits each outcome as `team_vm.driver_result`, so a crash between the call and
 * the commit is repaired by the alarm, and a lost create answer is found again by slug.
 */
export class TeamVmDO extends OwnerDO<TeamVmState> {
  private inflight: Promise<void> | null = null

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env, teamVmDomain as Domain<TeamVmState>, "team_vm")
  }

  private member(state: TeamVmState, p: Principal): boolean {
    return p.team !== undefined && (state.team === null || state.team === p.team)
  }

  protected maySubscribe(state: TeamVmState, principal: Principal): boolean {
    return this.member(state, principal)
  }

  protected read(state: TeamVmState, op: string, _params: unknown, principal: Principal): ReadResult {
    if (!this.member(state, principal)) return { ok: false, code: "auth.forbidden", message: "not this team's VM" }
    if (op !== "team_vm.status") return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    const now = Date.now()
    const leases = Object.entries(state.leases)
      .filter(([, l]) => l.expires_at > now)
      .map(([lease, l]) => ({ lease, holder: l.holder, reason: l.reason, expires_at: l.expires_at }))
    return {
      ok: true,
      value: { team: state.team ?? principal.team, status: state.status, vm: state.vm, epoch: state.epoch, leases, last_error: state.last_error, updated_at: state.updated_at },
      revision: ""
    }
  }

  protected override nextWakeAt(state: TeamVmState, _now: number): number | null {
    return teamVmWakeAt(state)
  }

  protected override async onWake(now: number): Promise<void> {
    const engine = this.boundEngine
    if (!engine) return
    const state = engine.currentState
    if (Object.values(state.leases).some((l) => l.expires_at <= now)) this.submitSystem("team_vm.leases_expire", { now }, `leases_expire:${now}`)
    if (state.pending && state.pending.retry_at <= now) await this.reconcile()
  }

  /**
   * RPC from the Worker for `team_vm.ensure_awake`: commit the lease, then run the provider
   * calls the op left pending and answer with the state they produced. A provider that is slow
   * leaves the call pending; the alarm finishes it, and `team_vm.status` shows the result.
   */
  async ensureAwake(entity: string, principal: Principal, frame: OpFrame): Promise<SubmitResult> {
    const result = await this.submit(entity, principal, frame)
    const ok = result.frames.some((f) => f.t === "result")
    if (ok) await Promise.race([this.reconcile(), new Promise<void>((r) => setTimeout(r, ENSURE_AWAKE_WAIT_MS))])
    const state = this.boundEngine?.currentState
    if (!ok || !state) return result
    // A final provider failure answers as that error; the committed lease stays until it expires.
    if (state.status === "failed" && state.pending === null && state.last_error) {
      const error = state.last_error
      return {
        frames: result.frames.map((f) =>
          f.t === "result" ? { t: "reject" as const, tx: f.tx, idempotency_key: f.idempotency_key, code: error.code, message: error.message, retryable: error.code !== "team_vm.not_configured" && error.code !== "team_vm.plan_gate_missing", replayed: f.replayed } : f
        )
      }
    }
    // The lease and expiry come from the committed op; status, vm and epoch are what the provider calls produced since.
    return {
      frames: result.frames.map((f) => (f.t === "result" ? { ...f, value: { ...(f.value as Record<string, unknown>), status: state.status, vm: state.vm, epoch: state.epoch } } : f))
    }
  }

  /** Runs pending provider calls one at a time; concurrent callers share the running pass. */
  private reconcile(): Promise<void> {
    if (!this.inflight) this.inflight = this.runPending().finally(() => (this.inflight = null))
    return this.inflight
  }

  private async runPending(): Promise<void> {
    // At most start, then (VM missing) create, then start; each step commits before the next reads the state.
    for (let step = 0; step < 3; step++) {
      const state = this.boundEngine?.currentState
      const pending = state?.pending
      if (!state || !pending || !state.team) return
      const key = `driver:${pending.action}:e${state.epoch}:a${pending.attempts}:${pending.retry_at}`
      const refusal = providerRefusal(this.env)
      if (refusal) {
        this.submitSystem("team_vm.driver_result", { action: pending.action, epoch: state.epoch, ok: false, error: { code: refusal, message: "team VMs are not available on this deployment until the plan gate lands" }, final: true }, key)
        return
      }
      const driver = teamVmDriver(this.env, this.sqlStore)
      if (!driver) {
        this.submitSystem("team_vm.driver_result", { action: pending.action, epoch: state.epoch, ok: false, error: { code: "team_vm.not_configured", message: "no team VM provider is configured for this deployment" }, final: true }, key)
        return
      }
      try {
        if (pending.action === "create") {
          const slug = teamVmSlug(this.env.TEAM_VM_SLUG_PREFIX ?? "", state.team, state.epoch + 1)
          const vm = await driver.ensureVm(slug, state.team, state.epoch + 1)
          this.submitSystem("team_vm.driver_result", { action: "create", epoch: state.epoch, ok: true, vm: vm.id, slug, observed: vm.state }, key)
        } else {
          if (!state.vm) return
          const r = await driver.ensureRunning(state.vm)
          this.submitSystem("team_vm.driver_result", { action: "start", epoch: state.epoch, ok: true, observed: r.state }, key)
        }
      } catch (e) {
        const err = e instanceof DriverError ? e : new DriverError("team_vm.provider_failed", String(e), false)
        console.warn(JSON.stringify({ msg: "team vm provider call failed", team: state.team, action: pending.action, attempt: pending.attempts + 1, code: err.code, error: err.message }))
        this.submitSystem("team_vm.driver_result", { action: pending.action, epoch: state.epoch, ok: false, error: { code: err.code, message: err.message }, final: err.final || pending.attempts + 1 >= MAX_ATTEMPTS }, key)
        // A missing VM is replaced at once (the reducer queued a create); other failures wait for the backoff.
        if (err.code === "team_vm.vm_missing") continue
        return
      }
    }
  }

  /** Test only (ENVIRONMENT=test): drive the fake provider. */
  async fakeControl(cmd: { fail_next?: number; pause_all?: boolean; delete_all?: boolean }): Promise<{ creates: number; starts: number }> {
    if (this.env.ENVIRONMENT !== "test") throw new Error("fakeControl is test only")
    teamVmDriver(this.env, this.sqlStore)
    if (cmd.fail_next !== undefined) this.sqlStore.exec(`UPDATE fake_ctl SET fail_next = ? WHERE id = 1`, cmd.fail_next)
    if (cmd.pause_all) this.sqlStore.exec(`UPDATE fake_vm SET state = 'paused'`)
    if (cmd.delete_all) this.sqlStore.exec(`DELETE FROM fake_vm`)
    return this.sqlStore.exec<{ creates: number; starts: number }>(`SELECT creates, starts FROM fake_ctl WHERE id = 1`)[0]!
  }

  /** Test only: run the alarm's own work as if `aheadMs` had passed. */
  async fakeAlarm(aheadMs: number): Promise<void> {
    if (this.env.ENVIRONMENT !== "test") throw new Error("fakeAlarm is test only")
    await this.onWake(Date.now() + aheadMs)
  }
}
