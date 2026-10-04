import type { Domain, EventFrame, OpFrame, OwnerFrame, Principal } from "@cmux/ownership"
import { CloudMachineList } from "@cmux/protocol"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult, type SubmitResult } from "./owner-do.ts"
import { DriverError } from "./team-vm-driver.ts"
import { cloudConfig, cloudDriver, cloudProviderReady, type GuardedCloudDriver } from "./cloud-driver.ts"
import { collectSuspects, OrphanSweep } from "./cloud-sweep.ts"
import { planView, teamPlan, type CloudConfig } from "./domains/cloud-plan.ts"
import { decodeParams } from "./domains/common.ts"
import {
  CLOUD_PRIVATE_TABLES,
  cloudDomain,
  ledgerKey,
  LEDGER_KEEP_MS,
  publicMachine,
  TABLE_LEDGER,
  TABLE_MACHINE,
  TABLE_TOMBSTONE,
  TOMBSTONE_MS,
  type CloudState,
  type LedgerRow,
  type MachineRow,
  type TombstoneRow
} from "./domains/cloud.ts"

/** How long a create or delete request waits for its provider call before it answers mutation.indeterminate. */
const REQUEST_WAIT_MS = 25_000
const PROVIDER_OPS: ReadonlySet<string> = new Set(["cloud.machine.create", "cloud.machine.delete"])
const INTERNAL_OPS: ReadonlySet<string> = new Set(["cloud.driver_result", "cloud.watch_result", "cloud.prune", "cloud.abandoned_clear"])
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
 * CloudDO, one per team (plans/cmux-next/state-placement.md 5): the machine registry, the
 * provider-call ledger, plan checks and the alarm that repairs interrupted provider calls.
 * Create and delete commit their ledger row first (the reducer), then this object runs the
 * provider call, one machine at a time (single flight), and commits the outcome as
 * `cloud.driver_result`. A crash between the call and that commit leaves the row pending; the
 * alarm runs it again, and the guarded driver finds the VM by its deterministic name.
 */
export class CloudDO extends OwnerDO<CloudState> {
  private readonly config: CloudConfig
  private readonly flights = new Map<string, Promise<void>>()
  /** Test only: moves the alarm's clock forward, and drops the next driver_result commits (a crash). */
  private skewMs = 0
  private dropResults = 0

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env, cloudDomain(cloudConfig(env)) as Domain<CloudState>, "cloud", undefined, {
      rowMode: { snapshotTable: TABLE_MACHINE, snapshotTail: 0 },
      // P3-8: internal ops carry ledger keys and provider error text; subscribers see neither.
      redact: { privateTables: CLOUD_PRIVATE_TABLES, state: headView, params: (op, params) => (INTERNAL_OPS.has(op) ? {} : params) }
    })
    this.config = cloudConfig(env)
  }

  /** P3-8: a member of the team this object is bound to, also while the head has no team yet. */
  private member(state: CloudState, p: Principal) {
    const team = state.team ?? this.boundEntity()
    return p.team !== undefined && team !== null && p.team === team
  }

  override async readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<ReadResult> {
    if (principal.team !== entity) return { ok: false, code: "auth.forbidden", message: "not this team's machines" }
    // An object nobody created: answer from an empty head for this entity, without creating it.
    if (!this.isBound(entity)) {
      const r = this.read({ team: entity, rev: 0, active: 0, saved: 0, pending: {}, changed: null }, op, params, principal)
      return r.ok ? { ...r, revision: "0" } : r
    }
    return super.readOp(entity, principal, op, params)
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
    return this.boundEntity() === null ? principal.team !== undefined : this.member(state, principal)
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
    if (after?.state === "failed") return this.refuse(result.frames, "cloud.provider.unavailable", after.error?.message ?? "the provider call failed", false)
    return result
  }

  /**
   * P2-4: create and delete per team (CLOUD_MUTATION_LIMIT). A decided key replays and a refused
   * principal gets its refusal without spending the budget; only new intents count.
   */
  private async rateLimited(entity: string, principal: Principal, frame: OpFrame): Promise<SubmitResult | undefined> {
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

  private refuse(frames: ReadonlyArray<OwnerFrame>, code: string, message: string, retryable: boolean): SubmitResult {
    return {
      frames: frames.map((f): OwnerFrame =>
        f.t === "result"
          ? { t: "reject", tx: "", idempotency_key: f.idempotency_key, code, message, retryable, replayed: false }
          : f.t === "request-settled"
            ? { ...f, tx: "", sequence: 0, ok: false }
            : f
      )
    }
  }

  private ledger(key: string): LedgerRow | undefined {
    return this.boundEngine?.rows.get<LedgerRow>(TABLE_LEDGER, key)?.row
  }

  /** Single flight per machine: a call for a machine waits for the one running, then runs once more. */
  private runMachine(machine: string, dueBy: number | null): Promise<void> {
    const running = this.flights.get(machine)
    if (running) return running.then(() => this.runMachine(machine, dueBy))
    const flight = this.pass(machine, dueBy).finally(() => this.flights.delete(machine))
    this.flights.set(machine, flight)
    return flight
  }

  /** Runs the machine's pending calls in intent order (a create before a later delete); stops at a retryable failure. */
  private async pass(machine: string, dueBy: number | null): Promise<void> {
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
      let result: { key: string; ok: boolean; provider_id?: string; error?: { code: string; message: string }; final?: boolean }
      if (!driver) result = { key: row.key, ok: false, error: { code: "cloud.provider.unavailable", message: "no Cloud provider is configured on this deployment" }, final: true }
      // P1-1: a create runs only for a team with a plan (the allowlist may have changed since the intent). Deletes always run: they only stop cost.
      else if (row.op === "create" && !row.cancel && !teamPlan(this.config, tag.team)) result = { key: row.key, ok: false, error: { code: "cloud.plan.required", message: "this team has no Cloud plan" }, final: true }
      else {
        try {
          if (row.op === "create" && row.cancel) {
            const found = await driver.findOwned(row.provider_name, tag)
            result = found ? { key: row.key, ok: true, provider_id: found.id } : { key: row.key, ok: false, error: { code: "cloud.provider.unavailable", message: "the cancelled create has not appeared (yet)" }, final: false }
          } else if (row.op === "create") {
            const idle = engine.rows.get<MachineRow>(TABLE_MACHINE, row.machine)?.row.idle_policy.idle_seconds ?? 0
            result = { key: row.key, ok: true, provider_id: (await driver.ensure(row.provider_name, tag, { idleSeconds: idle })).id }
          }
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
  private async lookUpCancelled(now: number, team: string, driver: GuardedCloudDriver): Promise<void> {
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

  private get sweep(): OrphanSweep {
    return (this.sweepStore ??= new OrphanSweep(this.sqlStore))
  }
  private sweepStore: OrphanSweep | null = null

  private hasRows(): boolean {
    const rows = this.boundEngine?.rows
    return Boolean(rows) && [TABLE_MACHINE, TABLE_LEDGER, TABLE_TOMBSTONE].some((t) => rows!.range(t, { limit: 1 }).length > 0)
  }

  /** When the next prune is due: the oldest tombstone past 30 days, or a finished ledger row past 7 (abandoned and watched rows stay). */
  private pruneAt(state: CloudState): number | null {
    const rows = this.boundEngine?.rows
    const tomb = rows?.range<TombstoneRow>(TABLE_TOMBSTONE, { limit: 1 })[0]
    const finished = rows?.range<LedgerRow>(TABLE_LEDGER, { limit: 50 }).find((l) => l.row.state !== "pending" && l.row.state !== "abandoned" && !state.watch?.[l.key])
    const times = [tomb ? tomb.row.deleted_at + TOMBSTONE_MS : null, finished ? finished.row.updated_at + LEDGER_KEEP_MS : null].filter((t): t is number => t !== null)
    return times.length ? Math.min(...times) : null
  }

  /** Test only (ENVIRONMENT=test): drive the fake provider and the object's clock. */
  /**
   * Operator action (route /v1/admin/cloud/abandoned/clear: admin key plus a person's session):
   * clear one abandoned ledger row. Refused unless a provider lookup of the recorded name, done
   * now, finds no VM. The clear and its audit row (who, when, why) commit together.
   */
  async clearAbandoned(entity: string, machine: string, who: { user: string; email: string | null }, reason: string): Promise<{ ok: true; audit: Record<string, unknown> } | { ok: false; code: string; message: string }> {
    const engine = this.boundEngine
    if (!engine || this.boundEntity() !== entity) return { ok: false, code: "not_abandoned", message: "no abandoned ledger row for that machine" }
    const stored = engine.rows.range<LedgerRow>(TABLE_LEDGER, { limit: 1000 }).find((l) => l.row.machine === machine && l.row.state === "abandoned")
    if (!stored) return { ok: false, code: "not_abandoned", message: "no abandoned ledger row for that machine" }
    const driver = cloudDriver(this.env, this.sqlStore)
    if (!driver) return { ok: false, code: "provider_unavailable", message: "no Cloud provider is configured, so the recorded name cannot be checked" }
    const found = await driver.peek(stored.row.provider_name).catch(() => undefined)
    if (found === undefined) return { ok: false, code: "provider_unavailable", message: "the provider lookup failed; try again" }
    if (found !== null) return { ok: false, code: "vm_present", message: "a VM exists under the recorded name; delete or adopt it by hand first" }
    const r = this.submitSystem("cloud.abandoned_clear", { key: stored.key, by: who.user, by_email: who.email, reason, at: Date.now() }, `abandoned-clear:${stored.key}`)
    const f = r.frames.find((x: OwnerFrame) => x.t === "result" || x.t === "reject") as { t: string; value?: { audit: Record<string, unknown> }; code?: string; message?: string } | undefined
    if (!f || f.t !== "result" || !f.value) return { ok: false, code: f?.code ?? "not_abandoned", message: f?.message ?? "not cleared" }
    console.warn(JSON.stringify({ event: "cloud.abandoned.cleared", team: entity, machine, by: who.user, reason_chars: reason.length }))
    return { ok: true, audit: f.value.audit }
  }

  async fakeControl(cmd: { fail_next?: number; drop_results?: number; advance_ms?: number; delete_vm?: string; fail_list?: boolean; add_vm?: { name: string; team: string; machine: string } }) {
    if (this.env.ENVIRONMENT !== "test") throw new Error("fakeControl is test only")
    cloudDriver(this.env, this.sqlStore)
    if (cmd.fail_next !== undefined) this.sqlStore.exec(`UPDATE cloud_fake_ctl SET fail_next = ? WHERE id = 1`, cmd.fail_next)
    if (cmd.drop_results !== undefined) this.dropResults = cmd.drop_results
    if (cmd.fail_list !== undefined) this.sqlStore.exec(`UPDATE cloud_fake_ctl SET fail_list = ? WHERE id = 1`, cmd.fail_list ? 1 : 0)
    if (cmd.advance_ms !== undefined) this.skewMs += cmd.advance_ms
    if (cmd.delete_vm !== undefined) this.sqlStore.exec(`DELETE FROM cloud_fake_vm WHERE name = ?`, cmd.delete_vm)
    if (cmd.add_vm !== undefined) {
      const t = { cmux_next_team: cmd.add_vm.team, cmux_next_machine: cmd.add_vm.machine }
      this.sqlStore.exec(`INSERT INTO cloud_fake_vm (name, id, tag, idle) VALUES (?, ?, ?, NULL)`, cmd.add_vm.name, `fs-${cmd.add_vm.name}`, JSON.stringify(t))
    }
    const ctl = this.sqlStore.exec<{ creates: number; deletes: number }>(`SELECT creates, deletes FROM cloud_fake_ctl WHERE id = 1`)[0]!
    const vms = this.sqlStore.exec<{ name: string; id: string; idle: number | null }>(`SELECT name, id, idle FROM cloud_fake_vm ORDER BY name`)
    return { creates: ctl.creates, deletes: ctl.deletes, vms, pending: Object.keys(this.boundEngine?.currentState.pending ?? {}).length, suspects: this.sweep.suspects(), sweep_at: this.sweep.at(), now: Date.now() + this.skewMs }
  }
}
