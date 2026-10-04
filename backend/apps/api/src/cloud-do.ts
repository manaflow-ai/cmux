import type { Domain, EventFrame, OpFrame, OwnerFrame, Principal } from "@cmux/ownership"
import { CloudMachineList } from "@cmux/protocol"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult, type SubmitResult } from "./owner-do.ts"
import { DriverError } from "./team-vm-driver.ts"
import { cloudConfig, cloudDriver } from "./cloud-driver.ts"
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
const INTERNAL_OPS: ReadonlySet<string> = new Set(["cloud.driver_result", "cloud.prune"])
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
      const due = Object.entries(engine.currentState.pending)
        .filter(([, p]) => p.machine === machine && (dueBy === null || p.due_at <= dueBy))
        .map(([key]) => engine.rows.get<LedgerRow>(TABLE_LEDGER, key))
        .filter((r) => r !== undefined)
        .sort((a, b) => (a.n ?? 0) - (b.n ?? 0))[0]
      if (!due) return
      const row = due.row
      const commitKey = `driver:${due.n}:a${row.attempts}`
      const tag = { team: engine.currentState.team ?? "", machine: row.machine }
      const driver = cloudDriver(this.env, this.sqlStore)
      let result: { key: string; ok: boolean; provider_id?: string; error?: { code: string; message: string }; final?: boolean }
      if (!driver) result = { key: row.key, ok: false, error: { code: "cloud.provider.unavailable", message: "no Cloud provider is configured on this deployment" }, final: true }
      // P1-1: a create runs only for a team with a plan (the allowlist may have changed since the intent). Deletes always run: they only stop cost.
      else if (row.op === "create" && !teamPlan(this.config, tag.team)) result = { key: row.key, ok: false, error: { code: "cloud.plan.required", message: "this team has no Cloud plan" }, final: true }
      else {
        try {
          if (row.op === "create") {
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
    const times = Object.values(state.pending).map((p) => p.due_at)
    const rows = this.boundEngine?.rows
    const tomb = rows?.range<TombstoneRow>(TABLE_TOMBSTONE, { limit: 1 })[0]
    if (tomb) times.push(tomb.row.deleted_at + TOMBSTONE_MS)
    const finished = rows?.range<LedgerRow>(TABLE_LEDGER, { limit: 50 }).find((l) => l.row.state !== "pending")
    if (finished) times.push(finished.row.updated_at + LEDGER_KEEP_MS)
    return times.length ? Math.min(...times) : null
  }

  protected override async onWake(realNow: number): Promise<void> {
    const engine = this.boundEngine
    if (!engine) return
    const now = realNow + this.skewMs
    const machines = new Set(Object.values(engine.currentState.pending).filter((p) => p.due_at <= now).map((p) => p.machine))
    for (const m of machines) await this.runMachine(m, now)
    if ((this.nextWakeAt(engine.currentState, now) ?? Infinity) <= now) this.submitSystem("cloud.prune", { now }, `prune:${now}`)
  }

  /** Test only (ENVIRONMENT=test): drive the fake provider and the object's clock. */
  async fakeControl(cmd: { fail_next?: number; drop_results?: number; advance_ms?: number; delete_vm?: string; add_vm?: { name: string; team: string; machine: string } }) {
    if (this.env.ENVIRONMENT !== "test") throw new Error("fakeControl is test only")
    cloudDriver(this.env, this.sqlStore)
    if (cmd.fail_next !== undefined) this.sqlStore.exec(`UPDATE cloud_fake_ctl SET fail_next = ? WHERE id = 1`, cmd.fail_next)
    if (cmd.drop_results !== undefined) this.dropResults = cmd.drop_results
    if (cmd.advance_ms !== undefined) this.skewMs += cmd.advance_ms
    if (cmd.delete_vm !== undefined) this.sqlStore.exec(`DELETE FROM cloud_fake_vm WHERE name = ?`, cmd.delete_vm)
    if (cmd.add_vm !== undefined) {
      const t = { cmux_next_team: cmd.add_vm.team, cmux_next_machine: cmd.add_vm.machine }
      this.sqlStore.exec(`INSERT INTO cloud_fake_vm (name, id, tag, idle) VALUES (?, ?, ?, NULL)`, cmd.add_vm.name, `fs-${cmd.add_vm.name}`, JSON.stringify(t))
    }
    const ctl = this.sqlStore.exec<{ creates: number; deletes: number }>(`SELECT creates, deletes FROM cloud_fake_ctl WHERE id = 1`)[0]!
    const vms = this.sqlStore.exec<{ name: string; id: string; idle: number | null }>(`SELECT name, id, idle FROM cloud_fake_vm ORDER BY name`)
    return { creates: ctl.creates, deletes: ctl.deletes, vms, pending: Object.keys(this.boundEngine?.currentState.pending ?? {}).length }
  }
}
