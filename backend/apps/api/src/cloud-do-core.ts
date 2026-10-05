import type { Domain, EventFrame, OpFrame, OwnerFrame, Principal } from "@cmux/ownership"
import { CloudMachineList, planRequiredDetails } from "@cmux/protocol"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult, type SubmitResult } from "./owner-do.ts"
import { DriverError } from "./team-vm-driver.ts"
import { cloudApiOrigin, cloudConfig, cloudDriver, cloudEnvTag, cloudProviderReady, type GuardedCloudDriver } from "./cloud-driver.ts"
import { collectSuspects, OrphanSweep } from "./cloud-sweep.ts"
import { newBindToken, sha256Hex } from "./cloud-link.ts"
import { AccessAudit } from "./cloud-connect.ts"
import { registerVmInstall, revokeVmInstall, VmStatusQueue } from "./cloud-vm.ts"
import { VmInstallRevokes } from "./cloud-vm-revoke.ts"
import { publicSnapshot, type SnapshotRow } from "./domains/cloud-snapshot.ts"
import { BACKSTOP_IDLE_SECONDS, idleFromReport, silentSince, type ReportedActivity } from "./cloud-idle.ts"
import { planView, teamPlan, type CloudConfig } from "./domains/cloud-plan.ts"
import { decodeParams } from "./domains/common.ts"
import { CLOUD_PRIVATE_TABLES, cloudDomain, ledgerKey, LEDGER_KEEP_MS, publicMachine, TABLE_LEDGER, TABLE_MACHINE, TABLE_SNAPSHOT, TABLE_TOMBSTONE, TOMBSTONE_MS, type CloudState, type LedgerRow, type MachineRow, type TombstoneRow } from "./domains/cloud.ts"

/** How long a create or delete request waits for its provider call before it answers mutation.indeterminate. */
const REQUEST_WAIT_MS = 25_000
const PROVIDER_OPS: ReadonlySet<string> = new Set(["cloud.machine.create", "cloud.machine.delete", "cloud.machine.pause", "cloud.machine.start", "cloud.machine.resize", "cloud.snapshot.create", "cloud.snapshot.delete", "cloud.snapshot.restore"])
/** A cloud.machine.vm_status commit that applied the report (a held report from a replaced install is dropped). */
export const statusApplied = (frames: ReadonlyArray<OwnerFrame>) => frames.some((f) => f.t === "result" && (f as { value?: { applied?: unknown } }).value?.applied === true)
const INTERNAL_OPS: ReadonlySet<string> = new Set(["cloud.machine.provider_state", "cloud.machine.idle_pause", "cloud.machine.bind", "cloud.driver_result", "cloud.watch_result", "cloud.prune", "cloud.abandoned_clear"])
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
  /** Test only: fail the next N revoke calls (fakeControl `fail_revokes`). */
  protected failRevokes = 0
  protected async drainRevokes(now: number): Promise<void> {
    const team = this.boundEntity()
    if (!team) return
    await this.vmRevokes.drain(now, async (a) => (this.failRevokes > 0 ? (this.failRevokes--, false) : revokeVmInstall(this.env, { ...a, team })))
    const at = this.vmRevokes.dueAt()
    if (at !== null) void this.ctx.storage.getAlarm().then((t) => (t === null || t > at ? this.ctx.storage.setAlarm(Math.max(at, Date.now())) : undefined))
  }

  /** The team's Cloud policy from its TeamDO (fail closed: a failed RPC fails the caller). */
  protected teamCloudPolicy(entity: string): Promise<{ connect_services: ReadonlyArray<string>; idle_pause: boolean }> {
    const stub = this.env.TEAM_DO.get(this.env.TEAM_DO.idFromName(entity)) as unknown as { cloudPolicy(e: string): Promise<{ connect_services: ReadonlyArray<string>; idle_pause: boolean }> }
    return stub.cloudPolicy(entity)
  }

  /**
   * After a VM status report was applied: pause the machine when the report shows it idle past its
   * idle policy and the team policy cloud.idlePause is on (cloud-idle.ts). The money-op path: the
   * per-team limit, the ledger (cloud.machine.idle_pause), the guarded provider call.
   */
  protected async considerIdlePause(entity: string, machine: string, report: unknown, now: number): Promise<void> {
    const engine = this.boundEngine
    const row = engine?.rows.get<MachineRow>(TABLE_MACHINE, machine)?.row
    const activity = (report as { activity?: ReportedActivity } | null)?.activity
    // The 24 h backstop applies to every team; it is also the longest threshold, so a report not idle by it needs no policy read.
    if (!engine || !row || !idleFromReport(row, activity, now, Math.min(BACKSTOP_IDLE_SECONDS, row.idle_policy.idle_seconds > 0 ? row.idle_policy.idle_seconds : BACKSTOP_IDLE_SECONDS))) return
    if (!idleFromReport(row, activity, now, BACKSTOP_IDLE_SECONDS)) {
      // Shorter than the backstop: only with the team's cloud.idlePause on (fail closed: a failed read means off).
      if (!(await this.teamCloudPolicy(entity).catch(() => ({ idle_pause: false }))).idle_pause) return
    }
    const limit = this.env.CLOUD_MUTATION_LIMIT
    // Per machine (review P3): a VM whose pauses keep failing cannot use up the team's create/delete budget.
    if (limit && !(await limit.limit({ key: `cloud-idle:${machine}` })).success) return
    const r = this.submitSystem("cloud.machine.idle_pause", { machine, reason: "idle" }, `idle-pause:${machine}:${engine.currentSeq}`)
    if (r.frames.some((f) => f.t === "result")) await this.runMachine(machine, null)
  }

  /** Backoff of the cost-backstop pause per machine (durable; cleared once the machine is no longer running). */
  private silentTable() {
    this.sqlStore.exec(`CREATE TABLE IF NOT EXISTS cloud_silent_retry (machine TEXT PRIMARY KEY, attempts INTEGER NOT NULL, next_at INTEGER NOT NULL)`)
  }
  protected silentRetryAt(machine: string): number | null {
    if (Number(this.sqlStore.exec<{ n: number }>(`SELECT count(*) AS n FROM sqlite_master WHERE name = 'cloud_silent_retry'`)[0]?.n ?? 0) === 0) return null
    const r = this.sqlStore.exec<{ next_at: number }>(`SELECT next_at FROM cloud_silent_retry WHERE machine = ?`, machine)[0]
    return r ? Number(r.next_at) : null
  }
  private silentTried(machine: string, now: number) {
    this.silentTable()
    const prev = Number(this.sqlStore.exec<{ attempts: number }>(`SELECT attempts FROM cloud_silent_retry WHERE machine = ?`, machine)[0]?.attempts ?? 0)
    const attempts = prev + 1
    this.sqlStore.exec(`INSERT INTO cloud_silent_retry (machine, attempts, next_at) VALUES (?, ?, ?) ON CONFLICT(machine) DO UPDATE SET attempts = excluded.attempts, next_at = excluded.next_at`, machine, attempts, now + Math.min(3600_000, 60_000 * 2 ** attempts))
  }

  /** Running machines that sent no applied report for 24 h after their last start or bind (the cost backstop). */
  protected silentMachines(now: number): Array<string> {
    return (this.boundEngine?.rows.range<MachineRow>(TABLE_MACHINE, { limit: 1000 }) ?? []).filter((r) => (r.row.status === "running" || r.row.status === "provisioning") && now - silentSince(r.row, this.vmStatus.lastAppliedAt(r.row.id)) >= BACKSTOP_IDLE_SECONDS * 1000).map((r) => r.row.id)
  }

  /** The cost backstop pass (alarm): pause each silent machine on the money-op path, pause_reason no_report. */
  protected async pauseSilent(now: number): Promise<void> {
    const engine = this.boundEngine
    if (!engine) return
    for (const machine of this.silentMachines(now)) {
      // A pause the provider keeps refusing backs off: 60 s, 2 min, 4 min ... at most 1 h (coordinator, 2026-10-05).
      if ((this.silentRetryAt(machine) ?? 0) > now) continue
      const limit = this.env.CLOUD_MUTATION_LIMIT
      if (limit && !(await limit.limit({ key: `cloud-idle:${machine}` })).success) continue
      const r = this.submitSystem("cloud.machine.idle_pause", { machine, reason: "no_report" }, `silent-pause:${machine}:${engine.currentSeq}`)
      this.silentTried(machine, now)
      if (r.frames.some((f) => f.t === "result")) await this.runMachine(machine, null)
    }
  }

  /** After every commit: a machine the commit left gone, failed or deleting loses its VM install (and a cleared ledger row's machine too). */
  protected override afterOp(_principal: Principal, op: string, frames: ReadonlyArray<OwnerFrame>, _params?: unknown) {
    const engine = this.boundEngine
    if (!engine) return
    const value = (frames.find((f) => f.t === "result") as { value?: { audit?: { machine?: unknown } } } | undefined)?.value
    const machines = new Set([engine.currentState.changed?.machine, op === "cloud.abandoned_clear" ? value?.audit?.machine : undefined].filter((m): m is string => typeof m === "string"))
    for (const m of machines) this.vmRevokes.reconcile(m, engine.rows.get<MachineRow>(TABLE_MACHINE, m)?.row, Date.now() + this.skewMs)
    for (const m of machines) {
      const st = engine.rows.get<MachineRow>(TABLE_MACHINE, m)?.row.status
      if (st !== "running" && st !== "provisioning" && st !== "pausing" && this.silentRetryAt(m) !== null) this.sqlStore.exec(`DELETE FROM cloud_silent_retry WHERE machine = ?`, m)
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

  constructor(ctx: DurableObjectState, env: Env) {
    const clock = { skew: 0 }
    super(ctx, env, cloudDomain(cloudConfig(env)) as Domain<CloudState>, "cloud", undefined, {
      now: () => Date.now() + clock.skew,
      rowMode: { snapshotTable: TABLE_MACHINE, snapshotTail: 0 },
      // P3-8: internal ops carry ledger keys and provider error text; subscribers see neither.
      redact: { privateTables: CLOUD_PRIVATE_TABLES, state: headView, params: (op, params) => (INTERNAL_OPS.has(op) ? {} : params) }
    })
    this.config = cloudConfig(env)
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
  override async submit(entity: string, principal: Principal, frame: OpFrame): Promise<SubmitResult> {
    if (principal.team !== entity) return forbidden(entity, frame.idempotency_key)
    const limited = PROVIDER_OPS.has(frame.op) ? await this.rateLimited(entity, principal, frame) : undefined
    if (limited) return limited
    const result = await super.submit(entity, principal, frame)
    await this.drainRevokes(Date.now() + this.skewMs)
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
      const driver = cloudDriver(this.env, this.sqlStore)
      let result: { key: string; ok: boolean; provider_id?: string; bind_token_sha256?: string; error?: { code: string; message: string }; final?: boolean; resources?: { cpu: number; memory_mb: number; disk_mb: number } }
      if (!driver) result = { key: row.key, ok: false, error: { code: "cloud.provider.unavailable", message: "no Cloud provider is configured on this deployment" }, final: true }
      // P1-1: a create runs only for a team with a plan (the allowlist may have changed since the intent). Deletes always run: they only stop cost.
      else if ((row.op === "create" || row.op === "start" || row.op === "resize" || row.op === "snapshot") && !row.cancel && !teamPlan(this.testUnset.has("CLOUD_ALLOWED_TEAMS") ? { ...this.config, allowedTeams: new Set() } : this.config, tag.team)) result = { key: row.key, ok: false, error: { code: "cloud.plan.required", message: "this team has no Cloud plan" }, final: true }
      // Review P3-a: the bind file's origin and env tag are checked before ensure, so a misconfiguration never leaves a running VM.
      else if (row.op === "create" && !row.cancel && !this.bindFileConfig()) result = { key: row.key, ok: false, error: { code: "cloud.provider.unavailable", message: "CLOUD_API_ORIGIN (https) or the environment tag is not configured" }, final: true }
      else {
        try {
          if (row.op === "create" && row.cancel) {
            const found = await driver.findOwned(row.provider_name, tag)
            result = found ? { key: row.key, ok: true, provider_id: found.id } : { key: row.key, ok: false, error: { code: "cloud.provider.unavailable", message: "the cancelled create has not appeared (yet)" }, final: false }
          } else if (row.op === "create") {
            // Freestyle's own timers are off (createBody): idle belongs to our policy and backstop.
            const m = engine.rows.get<MachineRow>(TABLE_MACHINE, row.machine)?.row
            // A restore boots its snapshot (a recorded, guarded slug); every other create the deployment's image.
            const fromSnapshot = m?.from_snapshot
            const id = (await driver.ensure(row.provider_name, tag, { idleSeconds: 0, ...(fromSnapshot ? { snapshot: fromSnapshot } : {}) })).id
            // 5.8 item 1: a fresh one-time bind token into the VM; only its sha256 is committed.
            const token = newBindToken()
            // a9's contract: one image for every environment, so the file names the https API origin and the env tag (checked above).
            const cfg = this.bindFileConfig()!
            await driver.writeBindFile(row.provider_name, tag, JSON.stringify({ team: tag.team, machine: row.machine, bind_token: token, ...cfg }))
            const res = await driver.resourcesOf(row.provider_name, tag).catch(() => null)
            result = { key: row.key, ok: true, provider_id: id, bind_token_sha256: await sha256Hex(token), ...(res ? { resources: { cpu: res.cpu, memory_mb: res.memory, disk_mb: res.storage } } : {}) }
          }
          else if (row.op === "pause" || row.op === "start") result = (await driver.power(row.provider_name, tag, row.op), { key: row.key, ok: true })
          else if (row.op === "snapshot" && row.snapshot_name) result = { key: row.key, ok: true, provider_id: (await driver.snapshot(row.provider_name, tag, row.snapshot_name)).id }
          else if (row.op === "snapshot_delete" && row.snapshot_name) result = (await driver.removeSnapshot(row.snapshot_name), { key: row.key, ok: true })
          else if (row.op === "resize" && row.size) result = (await driver.resize(row.provider_name, tag, { cpu: row.size.cpu, memory: row.size.memory_mb, storage: row.size.disk_mb }), { key: row.key, ok: true })
          else result = (await driver.remove(row.provider_name, tag), { key: row.key, ok: true })
        } catch (e) {
          const err = e instanceof DriverError ? e : new DriverError("cloud.provider.unavailable", String(e), false)
          // Only the step, status and provider code: never the key or a provider message body.
          console.warn(JSON.stringify({ msg: "cloud provider call failed", stream: engine.stream, op: row.op, machine: row.machine, attempt: row.attempts + 1, code: err.code, error: err.message }))
          const res = row.op === "resize" && err.final ? await driver.resourcesOf(row.provider_name, tag).catch(() => null) : null
          result = { key: row.key, ok: false, error: { code: err.code, message: err.message }, final: err.final, ...(res ? { resources: { cpu: res.cpu, memory_mb: res.memory, disk_mb: res.storage } } : {}) }
        }
      }
      if (this.env.ENVIRONMENT === "test" && this.dropResults > 0) {
        this.dropResults--
        return
      }
      this.submitSystem("cloud.driver_result", result, commitKey)
      if (!result.ok) return
    }
  }

  protected override nextWakeAt(state: CloudState, now: number): number | null {
    // Pending calls resolve even without a provider (they fail final), so they always count.
    const times = Object.values(state.pending).map((p) => p.due_at)
    const prune = this.pruneAt(state)
    if (prune !== null) times.push(prune)
    for (const t of [this.audit.pruneDueAt(), this.vmStatus.dueAt(), this.vmRevokes.dueAt(), this.vmRevokes.registerDueAt()]) if (t !== null) times.push(t)
    // The cost backstop: the earliest silent deadline of a running machine (never sooner than a minute: a
    // pause the limit held back must not re-fire the alarm at once).
    for (const r of this.boundEngine?.rows.range<MachineRow>(TABLE_MACHINE, { limit: 1000 }) ?? []) if (r.row.status === "running" || r.row.status === "provisioning") times.push(Math.max(silentSince(r.row, this.vmStatus.lastAppliedAt(r.row.id)) + BACKSTOP_IDLE_SECONDS * 1000, this.silentRetryAt(r.row.id) ?? 0, now + 60_000))
    // The cancelled-create lookups and the sweep need the provider: with none (key, prefix or image
    // removed), their overdue times would re-fire the alarm at once, forever (third review P2-1).
    if (cloudProviderReady(this.env)) {
      times.push(...Object.values(state.watch ?? {}).map((w) => w.due_at))
      if (this.hasRows()) times.push(this.sweep.dueAt() ?? Date.now())
    }
    return times.length ? Math.min(...times) : null
  }

  protected override async onWake(realNow: number): Promise<void> {
    const engine = this.boundEngine
    if (!engine) return
    const now = realNow + this.skewMs
    const machines = new Set(Object.values(engine.currentState.pending).filter((p) => p.due_at <= now).map((p) => p.machine))
    for (const m of machines) await this.runMachine(m, now)
    if ((this.pruneAt(engine.currentState) ?? Infinity) <= now) this.submitSystem("cloud.prune", { now }, `prune:${now}`)
    if ((this.audit.pruneDueAt() ?? Infinity) <= now) this.audit.prune(now)
    await this.vmRevokes.settleRegisters(now, async (reg) => ((r) => (r.ok ? { ok: true as const, id: r.id } : { ok: false as const, code: r.code }))(await registerVmInstall(this.env, reg)), (m) => engine.rows.get<MachineRow>(TABLE_MACHINE, m)?.row.vm_install)
    await this.drainRevokes(now)
    await this.pauseSilent(now)
    for (const d of this.vmStatus.takeDue(now)) {
      const r = this.submitSystem("cloud.machine.vm_status", { machine: d.machine, report: d.report, now }, `vm-status:${d.machine}:${now}`)
      if (statusApplied(r.frames)) await this.considerIdlePause(engine.currentState.team ?? "", d.machine, d.report, now)
    }
    const driver = cloudDriver(this.env, this.sqlStore)
    const team = engine.currentState.team
    if (!driver || !team) return
    await this.lookUpCancelled(now, team, driver)
    // N5: only while the team has machine, ledger or tombstone rows.
    if (this.hasRows()) await this.sweep.maybeRun(now, team, engine.stream, () => collectSuspects(driver, team, engine.rows))
  }

  /**
   * N1: the hourly lookup of each cancelled create's recorded name for 24 h. A VM there whose
   * metadata names this team and this machine is deleted by that recorded ledger name; any other VM
   * there is reported (metadata_mismatch) and never deleted. Deletion is only by ledger name, never
   * from a list.
   */
  protected async lookUpCancelled(now: number, team: string, driver: GuardedCloudDriver): Promise<void> {
    const engine = this.boundEngine
    if (!engine) return
    for (const [key, w] of Object.entries(engine.currentState.watch ?? {})) {
      if (w.due_at > now) continue
      const stored = engine.rows.get<LedgerRow>(TABLE_LEDGER, key)
      if (!stored) continue
      const l = stored.row
      let outcome: "absent" | "deleted" | "mismatch" = "absent"
      try {
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
