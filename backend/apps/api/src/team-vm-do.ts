import type { Domain, OpFrame, Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult, type SubmitResult } from "./owner-do.ts"
import { DriverError, FakeDriver, providerRefusal, requiredSlugPrefix, teamVmDriver } from "./team-vm-driver.ts"
import { MAX_ATTEMPTS, teamVmDomain, teamVmSlug, teamVmWakeAt, type TeamVmState } from "./domains/team-vm.ts"
import { fromBase64, isStream, MAX_ENTRY_BYTES, sha256Hex, TeamJournal } from "./team-vm-journal.ts"
import { TeamVmLedger, type LedgerRow } from "./team-vm-ledger.ts"
import { TeamVmRegistry, type RegistryCounts, type RegistryEvent, type RegistryEventKind } from "./team-vm-registry.ts"
import { TEAM_VM_REGISTRY } from "./team-vm-admin.ts"

/** Prefix report bounds: pages of this size, at most this many pages, at most this many names in the answer. */
const REPORT_PAGE = 100
const REPORT_MAX_PAGES = 50
const REPORT_MAX_NAMES = 200
/** Retry of undelivered registry events when the alarm next runs for this object. */
const REGISTRY_RETRY_MS = 60_000

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
  private ledgerStore: TeamVmLedger | null = null

  private get vmLedger(): TeamVmLedger {
    if (!this.ledgerStore) this.ledgerStore = new TeamVmLedger(this.sqlStore)
    return this.ledgerStore
  }

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

  protected override nextWakeAt(state: TeamVmState, now: number): number | null {
    const own = teamVmWakeAt(state)
    // Undelivered registry events retry with the alarm (only while some are left; no idle work).
    const outbox = this.registryOutboxSize() > 0 ? now + REGISTRY_RETRY_MS : null
    return own === null ? outbox : outbox === null ? own : Math.min(own, outbox)
  }

  protected override async onWake(now: number): Promise<void> {
    const engine = this.boundEngine
    if (!engine) return
    const state = engine.currentState
    if (Object.values(state.leases).some((l) => l.expires_at <= now)) this.submitSystem("team_vm.leases_expire", { now }, `leases_expire:${now}`)
    if (state.pending && state.pending.retry_at <= now) await this.reconcile()
    await this.drainRegistry()
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

  /**
   * The slug of the pending create for `epoch`: the one the first attempt used (its ledger intent,
   * or a team_vm_create_attempt row from before the ledger), else a new one from `prefix`. The
   * intent is written before the provider call (the DO output gate holds the request until the row
   * is durable), so a retry after a lost answer asks for the same slug even if a deploy changed
   * TEAM_VM_SLUG_PREFIX in between, and finds the VM the first attempt made instead of creating a
   * second one and orphaning the first.
   */
  private createSlug(team: string, epoch: number, prefix: string, createdBy: string): string {
    const earlier = this.vmLedger.createRowFor(epoch)
    if (earlier) {
      // An `absent` name opens again as an intent (the lookup may have run before the create landed).
      if (earlier.state === "absent") {
        this.vmLedger.recordIntent({ name: earlier.name, env: earlier.env, team, epoch, created_by: createdBy, now: Date.now() })
        this.enqueueRegistry("intent", team, earlier.name, null)
      }
      return earlier.name
    }
    this.sqlStore.exec(`CREATE TABLE IF NOT EXISTS team_vm_create_attempt (epoch INTEGER PRIMARY KEY, slug TEXT NOT NULL)`)
    const tried = this.sqlStore.exec<{ slug: string }>(`SELECT slug FROM team_vm_create_attempt WHERE epoch = ?`, epoch)[0]
    const slug = tried?.slug ?? teamVmSlug(prefix, team, epoch)
    this.vmLedger.recordIntent({ name: slug, env: this.env.ENVIRONMENT ?? "unknown", team, epoch, created_by: createdBy, now: Date.now() })
    this.enqueueRegistry("intent", team, slug, null)
    return slug
  }

  /** Backfill: the team record's VM enters the ledger by its exact id if no row holds it yet. */
  private backfillLedger(): void {
    const state = this.boundEngine?.currentState
    if (!state?.vm || !state.team) return
    const wrote = this.vmLedger.backfill({ id: state.vm, name: state.slug ?? state.vm, env: this.env.ENVIRONMENT ?? "unknown", team: state.team, epoch: state.epoch, now: Date.now() })
    if (wrote) this.enqueueRegistry("backfilled", state.team, state.slug ?? state.vm, state.vm)
    if (wrote) console.log(JSON.stringify({ msg: "team vm ledger backfill", team: state.team, vm: state.vm, epoch: state.epoch }))
  }

  /** RPC (tests, operators, the staging backfill): the team's ledger rows, after the backfill. */
  async ledger(entity: string): Promise<{ rows: LedgerRow[] }> {
    this.bind(entity)
    this.backfillLedger()
    await this.drainRegistry()
    return { rows: this.vmLedger.rows() }
  }

  /**
   * Resolves `unconfirmed` rows (a create whose answer never came) by an EXACT name lookup: the VM
   * with this name and this team's tag confirms the row; no VM with the name makes it `absent`.
   * The open intent of a pending create is left to that create's retry. Never lists, never deletes.
   */
  async reconcileLedger(entity: string): Promise<{ confirmed: number; absent: number; unresolved: number }> {
    this.bind(entity)
    this.backfillLedger()
    const state = this.boundEngine?.currentState
    const open = state?.pending?.action === "create" ? state.epoch + 1 : null
    const rows = this.vmLedger.unconfirmed().filter((r) => r.epoch !== open)
    const counts = { confirmed: 0, absent: 0, unresolved: 0 }
    const driver = providerRefusal(this.env) ? null : teamVmDriver(this.env, this.sqlStore)
    for (const row of rows) {
      if (!driver) {
        counts.unresolved++
        continue
      }
      try {
        const found = await driver.lookup(row.name)
        if (found === null) {
          this.vmLedger.markAbsent(row.name)
          counts.absent++
        } else if (found.team === row.team && !this.vmLedger.byId(found.id)) {
          this.vmLedger.confirm(row.name, found.id)
          this.enqueueRegistry("created", row.team, row.name, found.id)
          counts.confirmed++
        } else {
          console.warn(JSON.stringify({ msg: "team vm ledger name held by another VM", team: row.team, name: row.name }))
          counts.unresolved++
        }
      } catch {
        counts.unresolved++
      }
    }
    await this.drainRegistry()
    return counts
  }

  /**
   * Deletes one VM by its provider id. Only a ledger id (confirmed or backfilled) is accepted, and
   * never the team's current VM (a user still uses it; its replacement needs the owner). No public
   * route calls this yet; the age-out of old staging VMs will, under the owner-consent rule.
   */
  async deleteVm(entity: string, providerId: string, by: string): Promise<{ ok: true } | { ok: false; code: string; message: string }> {
    this.bind(entity)
    this.backfillLedger()
    const row = this.vmLedger.byId(providerId)
    if (!row) return { ok: false, code: "team_vm.not_in_ledger", message: "only a VM in this team's ledger can be deleted" }
    if (row.state === "deleted") return { ok: true }
    if (row.state !== "confirmed" && row.state !== "backfilled") return { ok: false, code: "team_vm.not_in_ledger", message: `ledger row is ${row.state}` }
    const state = this.boundEngine?.currentState
    // The current VM, and any VM for a later epoch (the next create finds it by name and makes it current), are in use.
    if (!state || state.vm === providerId || row.epoch > state.epoch) return { ok: false, code: "team_vm.in_use", message: "the team's current or next VM is deleted only with its owner" }
    const refusal = providerRefusal(this.env)
    const driver = refusal ? null : teamVmDriver(this.env, this.sqlStore)
    if (!driver) return { ok: false, code: refusal ?? "team_vm.not_configured", message: "no team VM provider is configured for this deployment" }
    await driver.deleteVm(providerId)
    this.vmLedger.markDeleted(providerId, Date.now())
    this.enqueueRegistry("deleted", row.team, row.name, providerId)
    await this.drainRegistry()
    console.log(JSON.stringify({ msg: "team vm deleted", team: row.team, vm: providerId, name: row.name, by }))
    return { ok: true }
  }

  /** Runs pending provider calls one at a time; concurrent callers share the running pass. */
  private reconcile(): Promise<void> {
    if (!this.inflight) this.inflight = this.runPending().finally(() => (this.inflight = null))
    return this.inflight
  }

  private async runPending(): Promise<void> {
    try {
      await this.runPendingSteps()
    } finally {
      await this.drainRegistry()
    }
  }

  private async runPendingSteps(): Promise<void> {
    // Every pass first puts the team record's VM into the ledger (a no-op once it is there).
    this.backfillLedger()
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
          const slug = this.createSlug(state.team, state.epoch + 1, prefix, `tvm:${pending.requested_by ?? "unknown"}`)
          const vm = await driver.ensureVm(slug, state.team, state.epoch + 1)
          this.submitSystem("team_vm.driver_result", { action: "create", epoch: state.epoch, ok: true, vm: vm.id, slug, observed: vm.state }, key)
          this.vmLedger.confirm(slug, vm.id)
          this.enqueueRegistry("created", state.team, slug, vm.id)
          this.sqlStore.exec(`DELETE FROM team_vm_create_attempt WHERE epoch <= ?`, state.epoch + 1)
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

  // Registry delivery (team instances): events go to an outbox table in the same synchronous step as
  // the ledger write, then to the registry instance; a failed send stays and retries with the alarm.

  private registryOutboxSize(): number {
    this.sqlStore.exec(`CREATE TABLE IF NOT EXISTS team_vm_registry_outbox (key TEXT PRIMARY KEY, kind TEXT NOT NULL, team TEXT NOT NULL, name TEXT NOT NULL, provider_id TEXT, at INTEGER NOT NULL)`)
    return this.sqlStore.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM team_vm_registry_outbox`)[0]?.n ?? 0
  }

  private enqueueRegistry(kind: RegistryEventKind, team: string, name: string, providerId: string | null): void {
    this.registryOutboxSize()
    this.sqlStore.exec(`INSERT OR IGNORE INTO team_vm_registry_outbox (key, kind, team, name, provider_id, at) VALUES (?, ?, ?, ?, ?, ?)`, `${kind}:${providerId ?? name}`, kind, team, name, providerId, Date.now())
  }

  private async drainRegistry(): Promise<void> {
    if (this.registryOutboxSize() === 0) return
    const rows = this.sqlStore.exec<{ key: string; kind: RegistryEventKind; team: string; name: string; provider_id: string | null }>(`SELECT key, kind, team, name, provider_id FROM team_vm_registry_outbox ORDER BY at LIMIT 50`)
    const ns = this.env.TEAM_VM_DO as unknown as DurableObjectNamespace
    const registry = ns.get(ns.idFromName(TEAM_VM_REGISTRY)) as unknown as { registryEvent(ev: RegistryEvent): Promise<void> }
    for (const r of rows) {
      try {
        await registry.registryEvent({ kind: r.kind, team: r.team, name: r.name, provider_id: r.provider_id })
        this.sqlStore.exec(`DELETE FROM team_vm_registry_outbox WHERE key = ?`, r.key)
      } catch (e) {
        console.warn(JSON.stringify({ msg: "team vm registry event not delivered", kind: r.kind, team: r.team, error: String(e).slice(0, 200) }))
        if (this.boundEngine) this.scheduleAlarm()
        return
      }
    }
  }

  // Registry instance (TEAM_VM_REGISTRY only).

  private registryStore: TeamVmRegistry | null = null
  private get registry(): TeamVmRegistry {
    if (!this.registryStore) this.registryStore = new TeamVmRegistry(this.sqlStore)
    return this.registryStore
  }

  /** RPC from a team instance's registry outbox; idempotent by provider id. */
  async registryEvent(ev: RegistryEvent): Promise<void> {
    this.registry.event(ev, Date.now())
  }

  async registryCounts(): Promise<RegistryCounts> {
    return this.registry.counts()
  }

  /**
   * On demand only (the operator route), report-only: pages through the provider account's VMs,
   * keeps the names with this environment's team VM prefix, and names those whose id no team's
   * ledger holds. Never adopts, deletes or writes anything; other names never leave this method.
   */
  async prefixReport(): Promise<{ prefix: string; listed: number; matched: number; in_registry: number; not_in_registry: string[]; truncated: boolean }> {
    const prefix = `${requiredSlugPrefix(this.env.ENVIRONMENT)}tvm-`
    const refusal = providerRefusal(this.env)
    const driver = refusal ? null : teamVmDriver(this.env, this.sqlStore)
    if (!driver) throw new Error(refusal ?? "team_vm.not_configured")
    let listed = 0
    let matched = 0
    let known = 0
    const unknown: string[] = []
    let truncated = false
    for (let page = 0; ; page++) {
      if (page >= REPORT_MAX_PAGES) {
        truncated = true
        break
      }
      const r = await driver.listPage(REPORT_PAGE, page * REPORT_PAGE)
      listed += r.vms.length
      for (const vm of r.vms) {
        if (!vm.slug?.startsWith(prefix)) continue
        matched++
        if (this.registry.knows(vm.id)) known++
        else if (unknown.length < REPORT_MAX_NAMES) unknown.push(vm.slug)
        else truncated = true
      }
      if (r.vms.length < REPORT_PAGE || listed >= r.total) break
    }
    const report = { prefix, listed, matched, in_registry: known, not_in_registry: unknown, truncated }
    console.log(JSON.stringify({ msg: "team vm prefix report", ...report, counts: this.registry.counts() }))
    return report
  }

  /** Test only (ENVIRONMENT=test): drive the fake provider. */
  async fakeControl(cmd: {
    fail_next?: number
    pause_all?: boolean
    delete_all?: boolean
    slug_prefix?: string
    lose_next_create?: number
    seed_vm?: { slug: string; id: string }
    drop_ledger?: boolean
  }): Promise<{ creates: number; starts: number }> {
    if (this.env.ENVIRONMENT !== "test") throw new Error("fakeControl is test only")
    teamVmDriver(this.env, this.sqlStore)
    if (cmd.seed_vm) this.sqlStore.exec(`INSERT OR REPLACE INTO fake_vm (slug, id, state, team) VALUES (?, ?, 'running', NULL)`, cmd.seed_vm.slug, cmd.seed_vm.id)
    if (cmd.drop_ledger) {
      void this.vmLedger
      this.sqlStore.exec(`DELETE FROM team_vm_ledger`)
    }
    if (cmd.slug_prefix !== undefined) this.sqlStore.exec(`UPDATE fake_ctl SET slug_prefix = ? WHERE id = 1`, cmd.slug_prefix)
    if (cmd.lose_next_create !== undefined) this.sqlStore.exec(`UPDATE fake_ctl SET lose_next_create = ? WHERE id = 1`, cmd.lose_next_create)
    if (cmd.fail_next !== undefined) this.sqlStore.exec(`UPDATE fake_ctl SET fail_next = ? WHERE id = 1`, cmd.fail_next)
    if (cmd.pause_all) this.sqlStore.exec(`UPDATE fake_vm SET state = 'paused'`)
    if (cmd.delete_all) this.sqlStore.exec(`DELETE FROM fake_vm`)
    return this.sqlStore.exec<{ creates: number; starts: number }>(`SELECT creates, starts FROM fake_ctl WHERE id = 1`)[0]!
  }

  /** Test only: the fake provider's VM ids. */
  async fakeVms(): Promise<string[]> {
    if (this.env.ENVIRONMENT !== "test") throw new Error("fakeVms is test only")
    teamVmDriver(this.env, this.sqlStore)
    return this.sqlStore.exec<{ id: string }>(`SELECT id FROM fake_vm ORDER BY id`).map((r) => r.id)
  }

  /** Test only: run the alarm's own work as if `aheadMs` had passed. */
  async fakeAlarm(aheadMs: number): Promise<void> {
    if (this.env.ENVIRONMENT !== "test") throw new Error("fakeAlarm is test only")
    await this.onWake(Date.now() + aheadMs)
  }
}
