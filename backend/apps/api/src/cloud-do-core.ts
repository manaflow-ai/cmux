import type { Domain, EventFrame, OpFrame, OwnerFrame, Principal } from "@cmux/ownership"
import { CloudMachineList, planRequiredDetails } from "@cmux/protocol"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult, type SubmitResult } from "./owner-do.ts"
import { VmApiSnapshotOutcome } from "./cloud-vm-api-snapshot.ts"
import { DriverError } from "./team-vm-driver.ts"
import { cloudApiOrigin, cloudConfig, cloudEnvTag, cloudProviderReady, type GuardedCloudDriver } from "./cloud-driver.ts"
import { cloudDriverFor } from "./cloud-vm-api-driver.ts"
import type { CloudTransport } from "./cloud-vm-api-config.ts"
import { collectSuspects, OrphanSweep } from "./cloud-sweep.ts"
import { newBindToken, sha256Hex } from "./cloud-link.ts"
import { AccessAudit, who } from "./cloud-connect.ts"
import { registerVmInstall, revokeVmInstall, VmStatusQueue } from "./cloud-vm.ts"
import { VmInstallRevokes } from "./cloud-vm-revoke.ts"
import { CoderouterEdge } from "./cloud-coderouter-edge.ts"
import { emptyFenceSettles, publicSnapshot, type SnapshotRow } from "./domains/cloud-snapshot.ts"
import { BACKSTOP_IDLE_SECONDS, silentSince } from "./cloud-idle.ts"
import { planView, teamPlan, type CloudConfig } from "./domains/cloud-plan.ts"
import { CloudEntitlementStore } from "./cloud-entitlements.ts"
import { decodeParams } from "./domains/common.ts"
import { cloudApprovalsDueAt, gateCloudRequest, InstallStarts, isApprovedRun, needsCloudApproval, wakeCloudApprovals, type CloudApprovalHost } from "./cloud-approvals.ts"
import { buildEnvironmentSnapshot, EnvironmentBuildError, environmentBuildStartExec } from "@cmux/cloud-env"
import { asWorkUser, GuardedCloudSandbox } from "./cloud-env-sandbox.ts"
import { ENV_SETUP_TIMEOUT_MS, isEnvBuild, publicEnvironment, TABLE_ENVIRONMENT_ROWS, type EnvironmentRow } from "./domains/cloud-environment.ts"
import { CLOUD_PRIVATE_TABLES, cloudDomain, ledgerKey, LEDGER_KEEP_MS, publicMachine, TABLE_LEDGER, TABLE_MACHINE, TABLE_SNAPSHOT, TABLE_TOMBSTONE, TOMBSTONE_MS, type CloudState, type LedgerRow, type MachineRow, type TombstoneRow } from "./domains/cloud.ts"

/** How long a create or delete request waits for its provider call before it answers mutation.indeterminate. */
const REQUEST_WAIT_MS = 25_000
const PROVIDER_OPS: ReadonlySet<string> = new Set(["cloud.machine.create", "cloud.machine.delete", "cloud.machine.pause", "cloud.machine.start", "cloud.machine.resize", "cloud.snapshot.create", "cloud.snapshot.delete", "cloud.snapshot.restore", "cloud.environment.boot", "cloud.environment.delete"])
/** Limited per team like the provider ops, but answered at once: the alarm runs the build (minutes). */
const BUILD_OPS: ReadonlySet<string> = new Set(["cloud.environment.build"])
/** Ops that may start cost: the team's paid plan is refreshed first (cloud-entitlements.ts). */
const PLAN_OPS: ReadonlySet<string> = new Set(["cloud.machine.create", "cloud.machine.start", "cloud.machine.resize", "cloud.machine.upgrade", "cloud.snapshot.create", "cloud.snapshot.restore", "cloud.environment.build", "cloud.environment.boot"])
/** A cloud.machine.vm_status commit that applied the report (a held report from a replaced install is dropped). */
export const statusApplied = (frames: ReadonlyArray<OwnerFrame>) => frames.some((f) => f.t === "result" && (f as { value?: { applied?: unknown } }).value?.applied === true)
const INTERNAL_OPS: ReadonlySet<string> = new Set(["cloud.machine.provider_state", "cloud.machine.idle_pause", "cloud.machine.bind", "cloud.driver_result", "cloud.watch_result", "cloud.prune", "cloud.abandoned_clear"])
const reject = (entity: string, key: string, code: string, message: string, retryable = false, details?: unknown): SubmitResult => ({
  frames: [
    { t: "reject", tx: "", idempotency_key: key, code, message, ...(details === undefined ? {} : { details }), retryable, replayed: false },
    { t: "request-settled", tx: "", idempotency_key: key, stream: `cloud:${entity}`, sequence: 0, ok: false }
  ]
})
const forbidden = (entity: string, key: string): SubmitResult => ({
  frames: [
    { t: "reject", tx: "", idempotency_key: key, code: "auth.forbidden", message: "not this team's machines", retryable: false, replayed: false },
    { t: "request-settled", tx: "", idempotency_key: key, stream: `cloud:${entity}`, sequence: 0, ok: false }
  ]
})

/** What subscribers see of the head: the team and its counts (pending calls stay with the owner). */
const headView = (s: unknown) => {
  const { team, rev, active, saved, changed } = s as CloudState
  return { team, rev, active, saved, changed }
}

/**
 * The core of CloudDO (split from cloud-do.ts at the 500-line limit): the registry, the provider-call
 * ledger and its single-flight passes, the alarm and the plan checks. cloud-do.ts adds the bind,
 * connect, link and VM RPCs, the operator clear and the test controls.
 */
export abstract class CloudCore extends OwnerDO<CloudState> {
  protected readonly vmStatus = new VmStatusQueue(this.sqlStore)
  /** The one durable path that ends VM installs (cloud-vm-revoke.ts). */
  protected readonly vmRevokes = new VmInstallRevokes(this.sqlStore)
  /** The coderouter.cmux.internal edge rule and its token refresh (development only; cloud-coderouter-edge.ts). */
  protected readonly edge = new CoderouterEdge(this.sqlStore, this.env)
  /** Test only: fail the next N revoke calls (fakeControl `fail_revokes`). */
  protected failRevokes = 0
  protected async drainRevokes(now: number): Promise<void> {
    const team = this.boundEntity()
    if (!team) return
    await this.vmRevokes.drain(now, async (a) => (this.failRevokes > 0 ? (this.failRevokes--, false) : revokeVmInstall(this.env, { ...a, team })))
    const at = this.vmRevokes.dueAt()
    if (at !== null) void this.ctx.storage.getAlarm().then((t) => (t === null || t > at ? this.ctx.storage.setAlarm(Math.max(at, Date.now())) : undefined))
  }

  /** Client session identities waiting for their provider delete (CloudDO, cloud-client-session.ts); a no-op here. */
  protected async sweepClientIdentities(_now: number, _first?: ReadonlyArray<string>): Promise<void> {}

  /** The idle rules (cloud-do-idle.ts CloudIdle): idle pause from reports, the 24 h cost backstop and its backoff. */
  protected abstract considerIdlePause(entity: string, machine: string, report: unknown, now: number): Promise<void>
  protected abstract pauseSilent(now: number): Promise<void>
  protected abstract alertStale(now: number): void
  protected abstract silentRetryAt(machine: string): number | null
  protected abstract silentRetry: { clear(machine: string): void }

  /** After every commit: a machine the commit left gone, failed or deleting loses its VM install (and a cleared ledger row's machine too). */
  protected override afterOp(_principal: Principal, op: string, frames: ReadonlyArray<OwnerFrame>, _params?: unknown) {
    const engine = this.boundEngine
    if (!engine) return
    const value = (frames.find((f) => f.t === "result") as { value?: { audit?: { machine?: unknown } } } | undefined)?.value
    const machines = new Set([engine.currentState.changed?.machine, op === "cloud.abandoned_clear" ? value?.audit?.machine : undefined].filter((m): m is string => typeof m === "string"))
    for (const m of machines) this.vmRevokes.reconcile(m, engine.rows.get<MachineRow>(TABLE_MACHINE, m)?.row, Date.now() + this.skewMs)
    for (const m of machines) {
      const st = engine.rows.get<MachineRow>(TABLE_MACHINE, m)?.row.status
      if (st !== "running" && st !== "provisioning" && st !== "pausing" && this.silentRetryAt(m) !== null) this.silentRetry.clear(m)
    }
  }
  protected readonly config: CloudConfig
  protected readonly flights = new Map<string, Promise<void>>()
  /** Test only: moves the alarm's clock forward, and drops the next driver_result commits (a crash). */
  /** Test only (fakeControl advance_ms): the object's clock offset, also the engine's clock (commits see the same time). */
  private readonly clock: { skew: number }
  protected get skewMs(): number {
    return this.clock.skew
  }
  protected set skewMs(v: number) {
    this.clock.skew = v
  }
  protected dropResults = 0

  /** The team's paid plan for the reducers (cloud-entitlements.ts); the same object is in `config`. */
  protected readonly entitlements: CloudEntitlementStore

  constructor(ctx: DurableObjectState, env: Env) {
    const clock = { skew: 0 }
    const entitlements = new CloudEntitlementStore(ctx.storage.sql, env, () => Date.now() + clock.skew)
    // One config for the domain and the object, so both read the same entitlements.
    const config: CloudConfig = { ...cloudConfig(env), entitlements }
    super(ctx, env, cloudDomain(config) as Domain<CloudState>, "cloud", undefined, {
      now: () => Date.now() + clock.skew,
      rowMode: { snapshotTable: TABLE_MACHINE, snapshotTail: 0 },
      // P3-8: internal ops carry ledger keys and provider error text; subscribers see neither.
      redact: { privateTables: CLOUD_PRIVATE_TABLES, state: headView, params: (op, params) => (INTERNAL_OPS.has(op) ? {} : params) }
    })
    this.config = config
    this.entitlements = entitlements
    this.clock = clock
  }

  /** P3-8: a member of the team this object is bound to, also while the head has no team yet. */
  protected member(state: CloudState, p: Principal) {
    const team = state.team ?? this.boundEntity()
    return p.team !== undefined && team !== null && p.team === team
  }

  /** P3-7: ops go through /v1/ops (rate limit, provider calls, answers); the socket only subscribes. */
  protected override routeFrame(ws: WebSocket, _a: unknown, frame: { readonly t?: string }): boolean {
    if (frame.t !== "op") return false
    try {
      ws.send(JSON.stringify({ t: "error", code: "validation.invalid", message: "send ops through /v1/ops" }))
    } catch {}
    return true
  }

  protected maySubscribe(state: CloudState, principal: Principal): boolean {
    // Before the first bind the base checks again on the bound object, which compares the entity.
    return principal.install_kind !== "vm" && (this.boundEntity() === null ? principal.team !== undefined : this.member(state, principal))
  }

  protected override subscriberView(state: CloudState): unknown {
    return headView(state)
  }

  protected read(state: CloudState, op: string, params: unknown, principal: Principal): ReadResult {
    // CLOUD-CONNECT-ACCESS: team members read team machines; an agent reads as its principal.
    if (!this.member(state, principal)) return { ok: false, code: "auth.forbidden", message: "not this team's machines" }
    // P3-9: an install reads only with a grant that covers read.
    if (principal.kind !== "session" && !principal.grant_classes?.includes("read")) return { ok: false, code: "auth.forbidden", message: "grant does not cover read" }
    const rows = this.boundEngine?.rows
    switch (op) {
      case "cloud.machine.list": {
        const d = decodeParams<typeof CloudMachineList.params.Type>(CloudMachineList, params)
        if (!d.ok) return d
        const after = d.value.cursor === undefined ? undefined : /^c[0-9]{1,15}$/.test(d.value.cursor) ? Number(d.value.cursor.slice(1)) : NaN
        if (Number.isNaN(after)) return { ok: false, code: "validation.invalid", message: "unknown cursor" }
        const limit = d.value.limit ?? 50
        const page = rows?.range<MachineRow>(TABLE_MACHINE, { ...(after === undefined ? {} : { after }), limit: limit + 1 }) ?? []
        const more = page.length > limit
        const shown = page.slice(0, limit)
        return { ok: true, value: { machines: shown.map((r) => publicMachine(r.row)), next_cursor: more ? `c${shown[shown.length - 1]!.n}` : null, revision: String(state.rev) }, revision: "" }
      }
      case "cloud.machine.get": {
        const id = (params as { machine?: unknown } | null)?.machine
        const row = typeof id === "string" ? rows?.get<MachineRow>(TABLE_MACHINE, id) : undefined
        if (!row) return { ok: false, code: "cloud.machine.not_found", message: "no such machine in this team" }
        return { ok: true, value: publicMachine(row.row), revision: "" }
      }
      case "cloud.snapshot.list": {
        const machine = (params as { machine?: unknown } | null)?.machine
        if (machine !== undefined && typeof machine !== "string") return { ok: false, code: "validation.invalid", message: "invalid machine" }
        const all = rows?.range<SnapshotRow>(TABLE_SNAPSHOT, { limit: 1000 }).map((r) => r.row) ?? []
        return { ok: true, value: { snapshots: all.filter((r) => machine === undefined || r.machine === machine).map(publicSnapshot) }, revision: "" }
      }
      case "cloud.environment.list": {
        const all = rows?.range<EnvironmentRow>(TABLE_ENVIRONMENT_ROWS, { limit: 1000 }).map((r) => r.row) ?? []
        return { ok: true, value: { environments: all.sort((a, b) => a.created_at - b.created_at).map((e) => publicEnvironment(this.config, rows, e)) }, revision: "" }
      }
      case "cloud.plan.get":
        return { ok: true, value: planView(teamPlan(this.config, state.team ?? principal.team), state, Date.now()), revision: "" }
      default:
        return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    }
  }

  /** The cloud.machine.* wire event of a committed op (contract 1.4), from the head's `changed`. */
  protected override eventExtras(_event: EventFrame): Record<string, unknown> | undefined {
    const engine = this.boundEngine
    const changed = engine?.currentState.changed
    if (!engine || !changed) return undefined
    if (changed.snapshot !== undefined) {
      if (changed.removed) return { event: "cloud.snapshot.removed", data: { snapshot: changed.snapshot, revision: String(engine.currentState.rev) } }
      const snap = engine.rows.get<SnapshotRow>(TABLE_SNAPSHOT, changed.snapshot)
      return snap ? { event: "cloud.snapshot.upsert", data: { snapshot: publicSnapshot(snap.row) } } : undefined
    }
    if (changed.removed) {
      const t = engine.rows.get<TombstoneRow>(TABLE_TOMBSTONE, changed.machine)
      return { event: "cloud.machine.removed", data: { machine: changed.machine, revision: t?.row.revision ?? String(engine.currentState.rev) } }
    }
    const row = engine.rows.get<MachineRow>(TABLE_MACHINE, changed.machine)
    return row ? { event: "cloud.machine.upsert", data: { machine: publicMachine(row.row) } } : undefined
  }

  /**
   * Every op from the Worker. Create and delete then run their provider call and answer with its
   * outcome: done = the committed result; still pending = mutation.indeterminate (the caller
   * retries the same key, which replays the result and resumes the call); failed = the provider error.
   */
  override async submit(entity: string, principalIn: Principal, frame: OpFrame): Promise<SubmitResult> {
    // `approval` is set only inside this object, for a run the person approved (cloud-approvals.ts); never from an RPC.
    const { approval: _never, ...principal } = principalIn
    if (principal.team !== entity) return forbidden(entity, frame.idempotency_key)
    // `approval:<request>` keys belong to approved runs (cloud-approvals.ts); a caller cannot take one first.
    if (frame.idempotency_key.startsWith("approval:")) return reject(entity, frame.idempotency_key, "validation.invalid", "idempotency keys starting with approval: are reserved")
    // G8 (cx-wb5.65): an install's money or destructive request waits for the person's approval.
    if (needsCloudApproval(frame.op, principal)) return gateCloudRequest(this.approvalHost(entity), principal, frame)
    return this.submitAs(entity, principal, frame)
  }

  /** The approvals host of this team's object (cloud-approvals.ts). */
  protected approvalHost(entity: string): CloudApprovalHost {
    const engine = this.bind(entity)
    const domain = cloudDomain(this.config)
    return { env: this.env, sql: this.ctx.storage.sql, team: entity, stream: engine.stream, authorize: (p, op, params) => domain.authorize!(engine.currentState, op, params, p, engine.rows), armAlarm: () => this.scheduleAlarm() }
  }

  protected readonly installStarts = new InstallStarts(this.sqlStore)

  /**
   * A checked principal's op. `approval` survives only on a principal cloud-approvals.ts made for an
   * approved run (a Workers RPC caller of this method passes a new object, so it is stripped).
   */
  protected async submitAs(entity: string, principalIn: Principal, frame: OpFrame): Promise<SubmitResult> {
    const principal: Principal = principalIn.approval === undefined || isApprovedRun(principalIn) ? principalIn : (({ approval: _x, ...p }) => p)(principalIn)
    const power = principal.kind === "install" && (frame.op === "cloud.machine.start" || frame.op === "cloud.machine.pause") && principal.install !== undefined
    const fresh = power && this.bind(entity).gate(principal, frame) === undefined
    // cx-wb5.65: at most 10 starts per install per hour (check and reserve in one step; given back unless the start commits).
    const slot = fresh && frame.op === "cloud.machine.start" ? this.installStarts.reserve(principal.install!, Date.now()) : null
    if (slot && "until" in slot) return reject(entity, frame.idempotency_key, "cloud.rate_limited", "this device started machines 10 times in the last hour; retry later or start it from the dashboard", true, { retry_after_ms: Math.max(0, slot.until - Date.now()) })
    // Paid entitlements: the plan the reducer and the provider pass read is refreshed before an op that may cost money.
    if (PLAN_OPS.has(frame.op)) await this.entitlements.refresh(entity, principal)
    const limited = PROVIDER_OPS.has(frame.op) || BUILD_OPS.has(frame.op) ? await this.rateLimited(entity, principal, frame) : undefined
    const result = limited ?? (await super.submit(entity, principal, frame))
    const committed = result.frames.some((f) => f.t === "result" && !f.replayed)
    if (slot && "id" in slot && !committed) this.installStarts.release(slot.id)
    if (limited) return limited
    if (fresh && committed) this.audit.record({ op: frame.op, machine: (frame.params as { machine?: unknown } | null)?.machine ?? null, ...who(principal), at: Date.now() })
    await this.drainRevokes(Date.now() + this.skewMs)
    // A deleted machine's client session identities go with it (never blocks the answer on a failed delete).
    if (frame.op === "cloud.machine.delete" && committed) await this.sweepClientIdentities(Date.now() + this.skewMs).catch(() => undefined)
    if (!PROVIDER_OPS.has(frame.op)) return result
    const reply = result.frames.find((f) => f.t === "result" || f.t === "reject")
    if (!reply || reply.t !== "result") return result
    const key = ledgerKey(principal.identity, frame.idempotency_key)
    const row = this.ledger(key)
    // No provider call (a delete the tombstone answered).
    if (!row) return result
    if (row.state === "pending") {
      let timer: ReturnType<typeof setTimeout> | undefined
      await Promise.race([this.runMachine(row.machine, null), new Promise<void>((r) => (timer = setTimeout(r, REQUEST_WAIT_MS)))])
      clearTimeout(timer)
    }
    const after = this.ledger(key)
    if (after?.state === "pending") return this.refuse(result.frames, "mutation.indeterminate", "the provider call was cut off; retry with the same key", true)
    // A plan refusal at call time (the allowlist changed after the intent) keeps its code and names the lifting plan.
    if (after?.state === "failed" && after.error?.code === "cloud.plan.required") return this.refuse(result.frames, "cloud.plan.required", after.error.message, false, planRequiredDetails())
    if (after?.state === "cancelled" && row.op === "snapshot") return this.refuse(result.frames, "cloud.provider.unavailable", "the snapshot request was cancelled", false)
    if (after?.state === "failed") return this.refuse(result.frames, "cloud.provider.unavailable", after.error?.message ?? "the provider call failed", false)
    return result
  }

  /**
   * P2-4: create and delete per team (CLOUD_MUTATION_LIMIT). A decided key replays and a refused
   * principal gets its refusal without spending the budget; only new intents count.
   */
  protected async rateLimited(entity: string, principal: Principal, frame: OpFrame): Promise<SubmitResult | undefined> {
    const limit = this.env.CLOUD_MUTATION_LIMIT
    if (!limit) return undefined
    if (this.isBound(entity) && this.bind(entity).gate(principal, frame) !== undefined) return undefined
    const { success } = await limit.limit({ key: `cloud:${entity}` })
    if (success) return undefined
    const key = frame.idempotency_key
    return {
      frames: [
        { t: "reject", tx: "", idempotency_key: key, code: "cloud.rate_limited", message: "too many machine creates and deletes for this team; retry in a minute", details: { retry_after_ms: 60_000 }, retryable: true, replayed: false },
        { t: "request-settled", tx: "", idempotency_key: key, stream: `cloud:${entity}`, sequence: 0, ok: false }
      ]
    }
  }

  protected refuse(frames: ReadonlyArray<OwnerFrame>, code: string, message: string, retryable: boolean, details?: unknown): SubmitResult {
    return {
      frames: frames.map((f): OwnerFrame =>
        f.t === "result"
          ? { t: "reject", tx: "", idempotency_key: f.idempotency_key, code, message, ...(details === undefined ? {} : { details }), retryable, replayed: false }
          : f.t === "request-settled"
            ? { ...f, tx: "", sequence: 0, ok: false }
            : f
      )
    }
  }

  protected ledger(key: string): LedgerRow | undefined {
    return this.boundEngine?.rows.get<LedgerRow>(TABLE_LEDGER, key)?.row
  }

  protected driverFor(row: { readonly transport?: CloudTransport }, purpose: "operate" | "cleanup" = "operate", provision = false) {
    const team = this.boundEntity()
    return team ? cloudDriverFor(this.env, this.sqlStore, team, row, purpose, undefined, provision) : Promise.resolve(null)
  }

  /** Test only (fakeControl `unset`): configuration a test removes to prove a fail-closed path. */
  protected testUnset = new Set<string>()
  /** Test only (fakeControl `link_keys`): the signing secret a mint reads instead of the Worker's. */
  protected testLinkKeys: string | undefined
  /** The bind file's api_origin and env, or null when either is missing (then no create runs). */
  protected bindFileConfig(): { api_origin: string; env: string } | null {
    const origin = this.testUnset.has("CLOUD_API_ORIGIN") ? null : cloudApiOrigin(this.env)
    const env = this.envTag()
    return origin && env ? { api_origin: origin, env } : null
  }
  protected envTag(): string | null {
    return this.testUnset.has("ENVIRONMENT_TAG") ? null : cloudEnvTag(this.env.ENVIRONMENT)
  }

  protected get audit(): AccessAudit {
    return (this.auditStore ??= new AccessAudit(this.sqlStore))
  }
  protected auditStore: AccessAudit | null = null

  /** Single flight per machine: a call for a machine waits for the one running, then runs once more. */
  protected runMachine(machine: string, dueBy: number | null): Promise<void> {
    const running = this.flights.get(machine)
    if (running) return running.then(() => this.runMachine(machine, dueBy))
    const flight = this.pass(machine, dueBy).finally(() => this.flights.delete(machine))
    this.flights.set(machine, flight)
    return flight
  }

  /** Runs the machine's pending calls in intent order (a create before a later delete); stops at a retryable failure. */
  protected async pass(machine: string, dueBy: number | null): Promise<void> {
    for (let step = 0; step < 4; step++) {
      const engine = this.boundEngine
      if (!engine) return
      // Strict intent order: the oldest pending call of the machine runs first, so a delete never
      // overtakes a create that is still settling (P1-2).
      const oldest = Object.entries(engine.currentState.pending)
        .filter(([, p]) => p.machine === machine)
        .map(([key, p]) => ({ p, r: engine.rows.get<LedgerRow>(TABLE_LEDGER, key) }))
        .filter((x) => x.r !== undefined)
        .sort((a, b) => (a.r!.n ?? 0) - (b.r!.n ?? 0))[0]
      if (!oldest) return
      const due = oldest.r!
      const row = due.row
      // N4: a request runs a call at once only for its first attempt; after a failure it waits for
      // the backoff like the alarm, so fast same-key retries cannot spend the attempts.
      const dueLimit = dueBy ?? (row.attempts === 0 ? Infinity : Date.now() + this.skewMs)
      if (oldest.p.due_at > dueLimit) return
      // Cancelled-create finds restart at attempt 0: their keys must differ from the create's own.
      const commitKey = `driver:${due.n}:${row.cancel ? "c" : "a"}${row.attempts}`
      const tag = { team: engine.currentState.team ?? "", machine: row.machine }
      const planDenied = (row.op === "create" || row.op === "start" || row.op === "resize" || row.op === "snapshot" || row.op === "env_build") && !row.cancel && !teamPlan(this.testUnset.has("CLOUD_ALLOWED_TEAMS") ? { ...this.config, allowedTeams: new Set() } : this.config, tag.team)
      const captureRecovery = row.op === "snapshot" && row.transport === "vm-api"
      const bindDenied = row.op === "create" && !row.cancel && !this.bindFileConfig()
      let driver: GuardedCloudDriver | null = null
      let routingError: DriverError | undefined
      if ((!planDenied || captureRecovery) && !bindDenied) try {
        driver = await this.driverFor(row, row.cancel || row.op === "delete" || row.op === "snapshot_delete" || row.op === "pause" || (planDenied && captureRecovery) ? "cleanup" : "operate", row.op === "create" && !row.cancel)
      } catch { routingError = new DriverError("cloud.provider.unavailable", "the VM tenant route is still being confirmed", false) }
      // Tenant provisioning can await identity I/O. A delete committed meanwhile changes this to lookup-only work.
      if (row.op === "create" && !row.cancel && this.ledger(row.key)?.cancel) continue
      let result: { key: string; ok: boolean; provider_id?: string; bind_token_sha256?: string; error?: { code: string; message: string }; final?: boolean; snapshot_outcome?: "deleted" | "absent"; resources?: { cpu: number; memory_mb: number; disk_mb: number }; env_build?: { stage?: "boot" | "ready" | "setup" | "snapshot" | "warm"; log_tail?: string; timings?: { boot_ms: number; ready_ms: number; setup_ms: number; snapshot_ms: number; warm_ms: number; total_ms: number } } }
      // P1-1: a create runs only for a team with a plan (the allowlist may have changed since the intent). Deletes always run: they only stop cost.
      if (planDenied && !captureRecovery) result = { key: row.key, ok: false, error: { code: "cloud.plan.required", message: "this team has no Cloud plan" }, final: true }
      // Review P3-a: the bind file's origin and env tag are checked before ensure, so a misconfiguration never leaves a running VM.
      else if (bindDenied) result = { key: row.key, ok: false, error: { code: "cloud.provider.unavailable", message: "CLOUD_API_ORIGIN (https) or the environment tag is not configured" }, final: true }
      else if (routingError) result = { key: row.key, ok: false, error: { code: routingError.code, message: routingError.message }, final: false }
      else if (!driver) result = { key: row.key, ok: false, error: { code: "cloud.provider.unavailable", message: "no Cloud provider is configured on this deployment" }, final: true }
      else {
        try {
          if (planDenied && captureRecovery && row.snapshot_name) {
            const recovered = await driver.recoverSnapshot(row.provider_name, tag, row.snapshot_name)
            if (!recovered) throw new VmApiSnapshotOutcome("pending")
            result = { key: row.key, ok: true, provider_id: recovered.id }
          } else if (row.op === "create" && row.cancel) {
            const found = await driver.findOwned(row.provider_name, tag)
            result = found ? { key: row.key, ok: true, provider_id: found.id } : { key: row.key, ok: false, error: { code: "cloud.provider.unavailable", message: "the cancelled create has not appeared (yet)" }, final: false }
          } else if (row.op === "create") {
            // The provider's own timers are off (every provider's create): idle belongs to our policy and backstop.
            const m = engine.rows.get<MachineRow>(TABLE_MACHINE, row.machine)?.row
            // A restore boots its snapshot (a recorded, guarded slug); every other create the deployment's image.
            const fromSnapshot = m?.from_snapshot
            const edgeRule = await this.edge.ruleForCreate(row.machine, m?.creator, Date.now() + this.skewMs)
            const id = (await driver.ensure(row.provider_name, tag, { idleSeconds: 0, ...(fromSnapshot ? { snapshot: fromSnapshot } : {}), ...(edgeRule ? { edgeRules: [edgeRule] } : {}) })).id
            if (edgeRule) this.edge.created(row.machine, Date.now() + this.skewMs)
            // 5.8 item 1: a fresh one-time bind token into the VM; only its sha256 is committed.
            const token = newBindToken()
            // a9's contract: one image for every environment, so the file names the https API origin and the env tag (checked above).
            const cfg = this.bindFileConfig()!
            await driver.writeBindFile(row.provider_name, tag, JSON.stringify({ team: tag.team, machine: row.machine, bind_token: token, ...cfg }))
            const res = await driver.resourcesOf(row.provider_name, tag).catch(() => null)
            await this.startEnvironmentSetup(driver, row.provider_name, tag, m)
            result = { key: row.key, ok: true, provider_id: id, bind_token_sha256: await sha256Hex(token), ...(res ? { resources: { cpu: res.cpu, memory_mb: res.memory, disk_mb: res.storage } } : {}) }
          }
          else if (row.op === "env_build") result = await this.runEnvironmentBuild(driver, row, tag)
          else if (row.op === "pause" || row.op === "start") result = (await driver.power(row.provider_name, tag, row.op), { key: row.key, ok: true })
          else if (row.op === "snapshot" && row.snapshot_name) result = { key: row.key, ok: true, provider_id: (await driver.snapshot(row.provider_name, tag, row.snapshot_name)).id }
          else if (row.op === "snapshot_delete" && row.snapshot_name) result = (await driver.removeSnapshot(row.snapshot_name, tag, emptyFenceSettles(row)), { key: row.key, ok: true })
          else if (row.op === "resize" && row.size) result = (await driver.resize(row.provider_name, tag, { cpu: row.size.cpu, memory: row.size.memory_mb, storage: row.size.disk_mb }), { key: row.key, ok: true })
          else result = (await driver.remove(row.provider_name, tag), { key: row.key, ok: true })
        } catch (e) {
          const err = e instanceof DriverError ? e : new DriverError("cloud.provider.unavailable", String(e), false)
          // Only the step, status and provider code: never the key or a provider message body.
          console.warn(JSON.stringify({ msg: "cloud provider call failed", stream: engine.stream, op: row.op, machine: row.machine, attempt: row.attempts + 1, code: err.code, error: err.message }))
          const res = row.op === "resize" && err.final ? await driver.resourcesOf(row.provider_name, tag).catch(() => null) : null
          result = { key: row.key, ok: false, error: { code: err.code, message: err.message }, final: err.final, ...(err instanceof VmApiSnapshotOutcome && err.outcome !== "pending" ? { snapshot_outcome: err.outcome } : {}), ...(res ? { resources: { cpu: res.cpu, memory_mb: res.memory, disk_mb: res.storage } } : {}) }
        }
      }
      if (this.env.ENVIRONMENT === "test" && this.dropResults > 0) {
        this.dropResults--
        return
      }
      this.submitSystem("cloud.driver_result", result, commitKey)
      if (!result.ok) return
      if (row.op === "start" && driver) await this.edge.started(driver, tag.team, row.machine, engine.rows.get<MachineRow>(TABLE_MACHINE, row.machine)?.row, Date.now() + this.skewMs)
    }
  }

  /**
   * One environment build (cloud-environments-DESIGN.md §2) through the CloudSandbox seam: builder from
   * the deployment's image, detached setup, snapshot under the recorded slug, warm boot, builder deleted.
   * A setup failure (non-zero exit or past its deadline) is final: the same script fails again. Every other failure retries.
   */
  protected async runEnvironmentBuild(driver: GuardedCloudDriver, row: LedgerRow, tag: { team: string; machine: string }) {
    const env = row.environment ? this.boundEngine?.rows.get<EnvironmentRow>(TABLE_ENVIRONMENT_ROWS, row.environment)?.row : undefined
    if (!env || !row.snapshot_name || !this.config.image) return { key: row.key, ok: false, error: { code: "cloud.environment.not_found", message: "the environment is gone" }, final: true }
    const sandbox = new GuardedCloudSandbox(driver, tag, row.transport ?? "direct")
    try {
      const out = await buildEnvironmentSnapshot(sandbox, env.spec, { baseImage: this.config.image, builderName: row.provider_name, snapshotName: row.snapshot_name, ...(row.env_warm ? { warmName: row.env_warm } : { warmName: null }), setupTimeoutMs: ENV_SETUP_TIMEOUT_MS, ...(this.env.ENVIRONMENT === "test" ? { setupPollMs: 10, readyIntervalMs: 10 } : {}) })
      const t = out.timings
      const ms = (n: number) => Math.max(0, Math.round(n))
      return { key: row.key, ok: true, provider_id: out.snapshotId, env_build: { timings: { boot_ms: ms(t.bootMs), ready_ms: ms(t.readyMs), setup_ms: ms(t.setupMs), snapshot_ms: ms(t.snapshotMs), warm_ms: ms(t.warmMs), total_ms: ms(t.totalMs) } } }
    } catch (e) {
      const err = e instanceof EnvironmentBuildError ? e : new EnvironmentBuildError("boot", String(e))
      const setup = err.stage === "setup"
      console.warn(JSON.stringify({ msg: "cloud environment build failed", stage: err.stage, environment: env.id, attempt: row.attempts + 1 }))
      return { key: row.key, ok: false, error: { code: setup ? "cloud.environment.build_failed" : "cloud.provider.unavailable", message: err.message }, final: setup, env_build: { stage: err.stage, ...(err.logTail ? { log_tail: err.logTail } : {}) } }
    }
  }

  /** A cold boot of an environment: starts its setup on the new machine, detached; a failure leaves the machine as it is. */
  protected async startEnvironmentSetup(driver: GuardedCloudDriver, name: string, tag: { team: string; machine: string }, m: MachineRow | undefined) {
    if (!m?.env_setup) return
    const env = this.boundEngine?.rows.get<EnvironmentRow>(TABLE_ENVIRONMENT_ROWS, m.env_setup.environment)?.row
    if (!env) return
    try {
      await driver.execStdin(name, tag, asWorkUser(environmentBuildStartExec(env.spec, m.env_setup.digest)), null, 60_000)
    } catch (e) {
      console.warn(JSON.stringify({ msg: "cloud environment setup did not start", machine: m.id, error: e instanceof Error ? e.message : String(e) }))
    }
  }

  protected override nextWakeAt(state: CloudState, now: number): number | null {
    // Pending calls resolve even without a provider (they fail final), so they always count.
    const times = Object.values(state.pending).map((p) => p.due_at)
    const prune = this.pruneAt(state)
    if (prune !== null) times.push(prune)
    for (const t of [this.audit.pruneDueAt(), this.vmStatus.dueAt(), this.vmRevokes.dueAt(), this.vmRevokes.registerDueAt(), cloudApprovalsDueAt(this.ctx.storage.sql, now)]) if (t !== null) times.push(t)
    // The cost backstop: the earliest silent deadline of a running machine (never sooner than a minute: a
    // pause the limit held back must not re-fire the alarm at once).
    for (const r of this.boundEngine?.rows.range<MachineRow>(TABLE_MACHINE, { limit: 1000 }) ?? []) if (r.row.status === "running" || r.row.status === "provisioning") times.push(Math.max(silentSince(r.row, this.vmStatus.lastActivityAt(r.row.id)) + BACKSTOP_IDLE_SECONDS * 1000, this.silentRetryAt(r.row.id) ?? 0, now + 60_000))
    // The cancelled-create lookups and the sweep need the provider: with none (key, prefix or image
    // removed), their overdue times would re-fire the alarm at once, forever (third review P2-1).
    if (cloudProviderReady(this.env)) {
      times.push(...Object.values(state.watch ?? {}).map((w) => w.due_at))
      const edgeDue = this.edge.schedule.dueAt()
      if (edgeDue !== null) times.push(edgeDue)
      if (this.hasRows()) times.push(this.sweep.dueAt() ?? Date.now())
    }
    return times.length ? Math.min(...times) : null
  }

  protected override async onWake(realNow: number): Promise<void> {
    const engine = this.boundEngine
    if (!engine) return
    const now = realNow + this.skewMs
    const due = Object.entries(engine.currentState.pending).filter(([, p]) => p.due_at <= now)
    // Environment builds take minutes: every other machine's call runs first.
    const builds = new Set(due.filter(([key]) => isEnvBuild(engine.rows, key)).map(([, p]) => p.machine))
    const machines = new Set(due.map(([, p]) => p.machine).filter((m) => !builds.has(m)))
    for (const m of machines) await this.runMachine(m, now)
    for (const m of builds) await this.runMachine(m, now)
    if ((this.pruneAt(engine.currentState) ?? Infinity) <= now) this.submitSystem("cloud.prune", { now }, `prune:${now}`)
    if ((this.audit.pruneDueAt() ?? Infinity) <= now) this.audit.prune(now)
    await this.vmRevokes.settleRegisters(now, async (reg) => ((r) => (r.ok ? { ok: true as const, id: r.id } : { ok: false as const, code: r.code }))(await registerVmInstall(this.env, reg)), (m) => engine.rows.get<MachineRow>(TABLE_MACHINE, m)?.row.vm_install)
    await this.drainRevokes(now)
    await this.sweepClientIdentities(now).catch(() => undefined)
    await this.pauseSilent(now)
    const entity = this.boundEntity()
    if (entity) await wakeCloudApprovals(this.approvalHost(entity), realNow, (p, f) => this.submitAs(entity, p, f), (e) => this.audit.record(e))
    this.alertStale(now)
    for (const d of this.vmStatus.takeDue(now)) {
      const r = this.submitSystem("cloud.machine.vm_status", { machine: d.machine, report: d.report, now }, `vm-status:${d.machine}:${now}`)
      if (!statusApplied(r.frames)) continue
      this.vmStatus.markActivity(d.machine, d.report, now)
      await this.considerIdlePause(engine.currentState.team ?? "", d.machine, d.report, now)
    }
    const team = engine.currentState.team
    if (!team) return
    await this.lookUpCancelled(now, team)
    for (const m of this.edge.schedule.due(now)) {
      const row = engine.rows.get<MachineRow>(TABLE_MACHINE, m)?.row
      const driver = row ? await this.driverFor(row) : null
      if (driver) await this.edge.refresh(driver, team, m, row, now)
      else this.edge.schedule.retry(m, now)
    }
    // N5: only while the team has machine, ledger or tombstone rows.
    if (this.hasRows()) await this.sweep.maybeRun(now, team, engine.stream, async () => {
      const direct = await this.driverFor({ transport: "direct" }, "cleanup")
      const api = await this.driverFor({ transport: "vm-api" }, "cleanup")
      const recorded = [...engine.rows.range<MachineRow>(TABLE_MACHINE, { limit: 1000 }), ...engine.rows.range<LedgerRow>(TABLE_LEDGER, { limit: 1000 })]
      if ((!direct && recorded.some((r) => r.row.transport === undefined || r.row.transport === "direct")) || (!api && recorded.some((r) => r.row.transport === "vm-api"))) throw new DriverError("cloud.provider.unavailable", "an orphan-report transport is unavailable", false)
      return [...(direct ? await collectSuspects(direct, team, engine.rows, "direct") : []), ...(api ? await collectSuspects(api, team, engine.rows, "vm-api") : [])]
    })
  }

  /**
   * N1: the hourly lookup of each cancelled create's recorded name for 24 h. A VM there whose
   * metadata names this team and this machine is deleted by that recorded ledger name; any other VM
   * there is reported (metadata_mismatch) and never deleted. Deletion is only by ledger name, never
   * from a list.
   */
  protected async lookUpCancelled(now: number, team: string): Promise<void> {
    const engine = this.boundEngine
    if (!engine) return
    for (const [key, w] of Object.entries(engine.currentState.watch ?? {})) {
      if (w.due_at > now) continue
      const stored = engine.rows.get<LedgerRow>(TABLE_LEDGER, key)
      if (!stored) continue
      const l = stored.row
      const driver = await this.driverFor(l, "cleanup")
      let outcome: "absent" | "deleted" | "mismatch" = "absent"
      try {
        if (!driver) throw new DriverError("cloud.provider.unavailable", "recorded transport is unavailable", false)
        const vm = await driver.peek(l.provider_name)
        if (vm && vm.tag.cmux_next_team === team && vm.tag.cmux_next_machine === l.machine) {
          await driver.remove(l.provider_name, { team, machine: l.machine })
          outcome = "deleted"
        } else if (vm) {
          console.error(JSON.stringify({ level: "error", event: "cloud.orphan.suspect", stream: engine.stream, team, name: l.provider_name, provider_id: vm.id, reason: "metadata_mismatch" }))
          outcome = "mismatch"
        }
      } catch (e) {
        // A failed lookup counts as absent: the next one comes an hour later, inside the same window.
        console.warn(JSON.stringify({ msg: "cloud late-VM lookup failed", stream: engine.stream, machine: l.machine, error: e instanceof Error ? e.message : String(e) }))
      }
      this.submitSystem("cloud.watch_result", { key, outcome, now }, `watch:${stored.n}:${now}`)
    }
  }

  protected get sweep(): OrphanSweep {
    return (this.sweepStore ??= new OrphanSweep(this.sqlStore))
  }
  protected sweepStore: OrphanSweep | null = null

  protected hasRows(): boolean {
    const rows = this.boundEngine?.rows
    return Boolean(rows) && [TABLE_MACHINE, TABLE_LEDGER, TABLE_TOMBSTONE].some((t) => rows!.range(t, { limit: 1 }).length > 0)
  }

  /** When the next prune is due: the oldest tombstone past 30 days, or a finished ledger row past 7 (abandoned and watched rows stay). */
  protected pruneAt(state: CloudState): number | null {
    const rows = this.boundEngine?.rows
    const tomb = rows?.range<TombstoneRow>(TABLE_TOMBSTONE, { limit: 1 })[0]
    const finished = rows?.range<LedgerRow>(TABLE_LEDGER, { limit: 50 }).find((l) => l.row.state !== "pending" && l.row.state !== "abandoned" && !state.watch?.[l.key])
    const times = [tomb ? tomb.row.deleted_at + TOMBSTONE_MS : null, finished ? finished.row.updated_at + LEDGER_KEEP_MS : null].filter((t): t is number => t !== null)
    return times.length ? Math.min(...times) : null
  }

}
