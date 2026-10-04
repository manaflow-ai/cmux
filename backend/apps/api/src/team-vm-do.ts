import type { Domain, OpFrame, Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult, type SubmitResult } from "./owner-do.ts"
import { DriverError, FakeDriver, providerRefusal, teamVmDriver } from "./team-vm-driver.ts"
import { MAX_ATTEMPTS, teamVmDomain, teamVmSlug, teamVmWakeAt, type TeamVmState } from "./domains/team-vm.ts"
import { fromBase64, isStream, MAX_ENTRY_BYTES, sha256Hex, TeamJournal } from "./team-vm-journal.ts"

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
  private journalStore: TeamJournal | null = null

  private get journal(): TeamJournal {
    if (!this.journalStore) this.journalStore = new TeamJournal(this.sqlStore)
    return this.journalStore
  }

  /**
   * The journal is the team's zero-loss tier and holds every person's files: only the VM's own
   * install for the current epoch reads or writes it, never a member's session or another install.
   */
  private journalCaller(state: TeamVmState, p: Principal, risk: "read" | "mutate-own"): { ok: true } | { ok: false; code: string; message: string } {
    if (p.kind !== "install" || p.team === undefined || p.team !== state.team) return { ok: false, code: "auth.forbidden", message: "only the team VM's install uses the journal" }
    if (!state.vm_install) return { ok: false, code: "team_vm.not_bound", message: "the team VM has not bound its install yet" }
    if (p.install !== state.vm_install) return { ok: false, code: "auth.forbidden", message: "only the team VM's install uses the journal" }
    if (!p.grant_classes?.includes(risk)) return { ok: false, code: "auth.forbidden", message: `grant does not cover ${risk}` }
    return { ok: true }
  }

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env, teamVmDomain as Domain<TeamVmState>, "team_vm")
  }

  private member(state: TeamVmState, p: Principal): boolean {
    return p.team !== undefined && (state.team === null || state.team === p.team)
  }

  protected maySubscribe(state: TeamVmState, principal: Principal): boolean {
    return this.member(state, principal)
  }

  protected read(state: TeamVmState, op: string, params: unknown, principal: Principal): ReadResult {
    if (op === "team_vm.journal.high_water" || op === "team_vm.journal.read") {
      const allowed = this.journalCaller(state, principal, "read")
      if (!allowed.ok) return allowed
      const p = (params ?? {}) as { stream?: unknown; from_seq?: unknown }
      if (!isStream(p.stream)) return { ok: false, code: "validation.invalid", message: "unknown journal stream" }
      if (op === "team_vm.journal.high_water") return { ok: true, value: { stream: p.stream, ...this.journal.highWater(p.stream) }, revision: "" }
      const from = typeof p.from_seq === "number" && Number.isSafeInteger(p.from_seq) && p.from_seq >= 1 ? p.from_seq : 0
      if (!from) return { ok: false, code: "validation.invalid", message: "from_seq must be a positive integer" }
      return { ok: true, value: this.journal.read(p.stream, from), revision: "" }
    }
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

  /**
   * RPC from the Worker for `team_vm.journal.append`. The reply leaves only after the SQLite write
   * is durable (DO output gate), which is the zero-loss acknowledgement.
   */
  async journalAppend(entity: string, principal: Principal, frame: OpFrame): Promise<SubmitResult> {
    this.bind(entity)
    const tx = `journal:${frame.idempotency_key}`
    const reject = (code: string, message: string, details?: unknown): SubmitResult => ({
      frames: [{ t: "reject", tx, idempotency_key: frame.idempotency_key, code, message, ...(details === undefined ? {} : { details }), retryable: false, replayed: false }]
    })
    const state = this.boundEngine?.currentState
    if (!state) return reject("owner.unreachable", "team VM record not open")
    const allowed = this.journalCaller(state, principal, "mutate-own")
    if (!allowed.ok) return reject(allowed.code, allowed.message)
    const p = (frame.params ?? {}) as { stream?: unknown; epoch?: unknown; first_seq?: unknown; last_seq?: unknown; bytes?: unknown; sha256?: unknown }
    if (!isStream(p.stream) || typeof p.epoch !== "number" || typeof p.first_seq !== "number" || typeof p.last_seq !== "number" || typeof p.bytes !== "string" || typeof p.sha256 !== "string")
      return reject("validation.invalid", "invalid params")
    // The writer must be on the record's epoch: a VM from before a restore cannot append.
    if (p.epoch !== state.epoch) return reject("journal.stale_epoch", "the append is for another epoch", { epoch: state.epoch })
    // Refuse oversize input before decoding it (base64 is 4 characters per 3 bytes).
    if (p.bytes.length > Math.ceil(MAX_ENTRY_BYTES / 3) * 4) return reject("journal.too_large", `an entry holds at most ${MAX_ENTRY_BYTES} bytes`)
    const bytes = fromBase64(p.bytes)
    if (!bytes) return reject("validation.invalid", "bytes must be base64")
    if ((await sha256Hex(bytes)) !== p.sha256) return reject("validation.invalid", "sha256 does not match the bytes")
    // Re-read after the await: the epoch may have moved while the hash ran.
    const now = this.boundEngine?.currentState
    if (now?.epoch !== p.epoch) return reject("journal.stale_epoch", "the append is for another epoch")
    if (now.vm_install !== principal.install) return reject("auth.forbidden", "only the team VM's install uses the journal")
    const r = this.journal.append(p.stream, p.epoch, p.first_seq, p.last_seq, bytes, p.sha256, Date.now())
    if (!r.ok) return reject(r.code, r.message, r.details)
    return { frames: [{ t: "result", tx, idempotency_key: frame.idempotency_key, value: r.value, revision: String(r.value.high_water), replayed: r.value.replayed }] }
  }

  /**
   * Records the VM's own install for the current epoch (the journal writer). Called by the bind
   * path once the VM proves its instance identity (lane 1 bind, lane 10 pairing); no public route yet.
   */
  async bindInstall(entity: string, install: string, epoch: number): Promise<SubmitResult> {
    this.bind(entity)
    return this.submitSystem("team_vm.bind_install", { install, epoch }, `bind_install:${epoch}:${install}`)
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
          // The prefix names NEW VMs only: an existing VM is always reached by its stored id (state.vm), so a
          // prefix change (FREESTYLE-NAMES) never renames, adopts or loses the VM a team already has.
          const prefix = (driver instanceof FakeDriver ? driver.slugPrefix() : null) ?? this.env.TEAM_VM_SLUG_PREFIX ?? ""
          const slug = teamVmSlug(prefix, state.team, state.epoch + 1)
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
  async fakeControl(cmd: { fail_next?: number; pause_all?: boolean; delete_all?: boolean; slug_prefix?: string }): Promise<{ creates: number; starts: number }> {
    if (this.env.ENVIRONMENT !== "test") throw new Error("fakeControl is test only")
    teamVmDriver(this.env, this.sqlStore)
    if (cmd.slug_prefix !== undefined) this.sqlStore.exec(`UPDATE fake_ctl SET slug_prefix = ? WHERE id = 1`, cmd.slug_prefix)
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
