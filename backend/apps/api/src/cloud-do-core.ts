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
import { planView, teamPlan, type CloudConfig } from "./domains/cloud-plan.ts"
import { decodeParams } from "./domains/common.ts"
import { CLOUD_PRIVATE_TABLES, cloudDomain, ledgerKey, LEDGER_KEEP_MS, publicMachine, TABLE_LEDGER, TABLE_MACHINE, TABLE_TOMBSTONE, TOMBSTONE_MS, type CloudState, type LedgerRow, type MachineRow, type TombstoneRow } from "./domains/cloud.ts"

/** How long a create or delete request waits for its provider call before it answers mutation.indeterminate. */
const REQUEST_WAIT_MS = 25_000
const PROVIDER_OPS: ReadonlySet<string> = new Set(["cloud.machine.create", "cloud.machine.delete", "cloud.machine.pause", "cloud.machine.start"])
const INTERNAL_OPS: ReadonlySet<string> = new Set(["cloud.machine.bind", "cloud.driver_result", "cloud.watch_result", "cloud.prune", "cloud.abandoned_clear"])
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

  /** After every commit: a machine the commit left gone, failed or deleting loses its VM install (and a cleared ledger row's machine too). */
  protected override afterOp(_principal: Principal, op: string, frames: ReadonlyArray<OwnerFrame>, _params?: unknown) {
    const engine = this.boundEngine
    if (!engine) return
    const value = (frames.find((f) => f.t === "result") as { value?: { audit?: { machine?: unknown } } } | undefined)?.value
    const machines = new Set([engine.currentState.changed?.machine, op === "cloud.abandoned_clear" ? value?.audit?.machine : undefined].filter((m): m is string => typeof m === "string"))
    for (const m of machines) this.vmRevokes.reconcile(m, engine.rows.get<MachineRow>(TABLE_MACHINE, m)?.row, Date.now() + this.skewMs)
  }
  protected readonly config: CloudConfig
  protected readonly flights = new Map<string, Promise<void>>()
  /** Test only: moves the alarm's clock forward, and drops the next driver_result commits (a crash). */
  protected skewMs = 0
  protected dropResults = 0

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env, cloudDomain(cloudConfig(env)) as Domain<CloudState>, "cloud", undefined, {
      rowMode: { snapshotTable: TABLE_MACHINE, snapshotTail: 0 },
      // P3-8: internal ops carry ledger keys and provider error text; subscribers see neither.
      redact: { privateTables: CLOUD_PRIVATE_TABLES, state: headView, params: (op, params) => (INTERNAL_OPS.has(op) ? {} : params) }
    })
    this.config = cloudConfig(env)
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
      let result: { key: string; ok: boolean; provider_id?: string; bind_token_sha256?: string; error?: { code: string; message: string }; final?: boolean }
      if (!driver) result = { key: row.key, ok: false, error: { code: "cloud.provider.unavailable", message: "no Cloud provider is configured on this deployment" }, final: true }
      // P1-1: a create runs only for a team with a plan (the allowlist may have changed since the intent). Deletes always run: they only stop cost.
      else if ((row.op === "create" || row.op === "start") && !row.cancel && !teamPlan(this.testUnset.has("CLOUD_ALLOWED_TEAMS") ? { ...this.config, allowedTeams: new Set() } : this.config, tag.team)) result = { key: row.key, ok: false, error: { code: "cloud.plan.required", message: "this team has no Cloud plan" }, final: true }
      // Review P3-a: the bind file's origin and env tag are checked before ensure, so a misconfiguration never leaves a running VM.
      else if (row.op === "create" && !row.cancel && !this.bindFileConfig()) result = { key: row.key, ok: false, error: { code: "cloud.provider.unavailable", message: "CLOUD_API_ORIGIN (https) or the environment tag is not configured" }, final: true }
      else {
        try {
          if (row.op === "create" && row.cancel) {
            const found = await driver.findOwned(row.provider_name, tag)
            result = found ? { key: row.key, ok: true, provider_id: found.id } : { key: row.key, ok: false, error: { code: "cloud.provider.unavailable", message: "the cancelled create has not appeared (yet)" }, final: false }
          } else if (row.op === "create") {
            const idle = engine.rows.get<MachineRow>(TABLE_MACHINE, row.machine)?.row.idle_policy.idle_seconds ?? 0
            const id = (await driver.ensure(row.provider_name, tag, { idleSeconds: idle })).id
            // 5.8 item 1: a fresh one-time bind token into the VM; only its sha256 is committed.
            const token = newBindToken()
            // a9's contract: one image for every environment, so the file names the https API origin and the env tag (checked above).
            const cfg = this.bindFileConfig()!
            await driver.writeBindFile(row.provider_name, tag, JSON.stringify({ team: tag.team, machine: row.machine, bind_token: token, ...cfg }))
            result = { key: row.key, ok: true, provider_id: id, bind_token_sha256: await sha256Hex(token) }
          }
          else if (row.op === "pause" || row.op === "start") result = (await driver.power(row.provider_name, tag, row.op), { key: row.key, ok: true })
          else result = (await driver.remove(row.provider_name, tag), { key: row.key, ok: true })
        } catch (e) {
          const err = e instanceof DriverError ? e : new DriverError("cloud.provider.unavailable", String(e), false)
          // Only the step, status and provider code: never the key or a provider message body.
          console.warn(JSON.stringify({ msg: "cloud provider call failed", stream: engine.stream, op: row.op, machine: row.machine, attempt: row.attempts + 1, code: err.code, error: err.message }))
          result = { key: row.key, ok: false, error: { code: err.code, message: err.message }, final: err.final }
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

  protected override nextWakeAt(state: CloudState, _now: number): number | null {
    // Pending calls resolve even without a provider (they fail final), so they always count.
    const times = Object.values(state.pending).map((p) => p.due_at)
    const prune = this.pruneAt(state)
    if (prune !== null) times.push(prune)
    for (const t of [this.audit.pruneDueAt(), this.vmStatus.dueAt(), this.vmRevokes.dueAt(), this.vmRevokes.registerDueAt()]) if (t !== null) times.push(t)
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
    for (const d of this.vmStatus.takeDue(now)) this.submitSystem("cloud.machine.vm_status", { machine: d.machine, report: d.report, now }, `vm-status:${d.machine}:${now}`)
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
