import type { Domain, Principal, ReduceContext, ReduceResult, RowReader, RowWrite } from "@cmux/ownership"
import { CloudDriverResultParams, CloudMachineCreate, CloudMachineDelete, CloudMachineIdlePolicySet, CloudMachineRename, CloudPruneParams } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { admit, decodeParams, reject, requirePersonalTeamAdmin } from "./common.ts"
import { grantClasses } from "../home-admit.ts"
import { personalTeamIdFor } from "./user.ts"
import { createConfigProblem, DEFAULT_IDLE_SECONDS, DEFAULT_SIZE, providerName, sizeLocked, teamPlan, type CloudConfig, type CloudMachineView } from "./cloud-plan.ts"

/**
 * CloudDO's reducer (plans/cmux-next/state-placement.md 5.1-5.3). Pure: provider calls run in the
 * DO, which commits each outcome as `cloud.driver_result`. Row mode: the head holds counts and the
 * pending provider calls; machines, the provider-call ledger and tombstones are private rows.
 * `rev` grows by one with every committed change, so it equals the stream sequence and every
 * entity revision is the sequence of its last change.
 */
export const TABLE_MACHINE = "machine"
export const TABLE_LEDGER = "ledger"
export const TABLE_TOMBSTONE = "tombstone"
export const CLOUD_PRIVATE_TABLES: ReadonlyArray<string> = [TABLE_MACHINE, TABLE_LEDGER, TABLE_TOMBSTONE]

export const TOMBSTONE_MS = 30 * 24 * 3600_000
export const LEDGER_KEEP_MS = 7 * 24 * 3600_000
/** The request path runs a provider call at once; the alarm picks it up after this if the object died. */
export const PENDING_SAFETY_MS = 30_000
export const MAX_ATTEMPTS = 5
export const retryDelayMs = (attempts: number) => Math.min(5 * 60_000, 1000 * 2 ** attempts)
/**
 * Finds for a create a delete cancelled (P1-2): 30 s, 60 s, 2 min, 4 min between them, then give up
 * (about 7.5 minutes, past the create call's own 2-minute timeout). The hourly orphan report covers
 * a VM that lands later still.
 */
export const cancelFindDelayMs = (attempts: number) => Math.min(5 * 60_000, 30_000 * 2 ** Math.max(0, attempts - 1))

export interface CloudState {
  readonly team: string | null
  readonly rev: number
  readonly active: number
  readonly saved: number
  /** Ledger rows still waiting for their provider call: key -> machine and when the alarm runs it. */
  readonly pending: Readonly<Record<string, { readonly machine: string; readonly due_at: number }>>
  /** The machine the last committed op changed (for the cloud.machine.* wire event), or null. */
  readonly changed: { readonly machine: string; readonly removed: boolean } | null
}

export interface MachineRow extends Omit<CloudMachineView, "revision"> {
  readonly revision: string
  readonly provider_name: string
}

export interface LedgerRow {
  readonly key: string
  readonly op: "create" | "delete"
  readonly machine: string
  readonly provider_name: string
  readonly state: "pending" | "done" | "failed" | "cancelled"
  /**
   * create only: a delete cancelled it while its outcome was uncertain (P1-2). It stays pending and
   * only finds by name (never creates): found = done (the delete then removes it by this recorded
   * name), not found after MAX_ATTEMPTS backed-off finds = cancelled.
   */
  readonly cancel?: boolean
  readonly provider_id: string | null
  readonly attempts: number
  readonly error: { readonly code: string; readonly message: string } | null
  readonly created_at: number
  readonly updated_at: number
}

export interface TombstoneRow {
  readonly machine: string
  readonly deleted_at: number
  readonly revision: string
}

/** The ledger row of one intent: the caller's identity and the op's idempotency key (engine keys are per identity). */
export const ledgerKey = (identity: string, idempotencyKey: string) => `${identity}|${idempotencyKey}`

/** Statuses that count against the plan's max_active. */
const COUNTED: ReadonlySet<string> = new Set(["provisioning", "starting", "running", "pausing"])
const counted = (status: string) => (COUNTED.has(status) ? 1 : 0)

export const publicMachine = (row: MachineRow): CloudMachineView => {
  const { provider_name: _hidden, ...machine } = row
  return machine
}

export const isAgent = (p: Principal) => p.kind === "agent" || p.agent !== undefined

/** Creator or team admin (all teams are personal today: the personal team's user is its admin). */
const mayManage = (p: Principal, row: MachineRow) => p.user === row.creator || requirePersonalTeamAdmin(p, personalTeamIdFor) === undefined

const decodeInternal = <T>(schema: Schema.Top, params: unknown): { ok: true; value: T } | ReturnType<typeof reject> => {
  const exit = Schema.decodeUnknownExit(schema as Schema.Codec<T, unknown>)(params ?? {})
  return Exit.isSuccess(exit) ? { ok: true, value: exit.value } : reject("validation.invalid", "invalid params", String(exit.cause))
}

const machineRow = (rows: RowReader | undefined, id: string) => rows?.get<MachineRow>(TABLE_MACHINE, id)
const ledgerRow = (rows: RowReader | undefined, key: string) => rows?.get<LedgerRow>(TABLE_LEDGER, key)

/** A changing commit: one more revision, and the machine it changed (or none). */
const next = (state: CloudState, patch: Partial<CloudState>, changed: CloudState["changed"] = null): CloudState => ({ ...state, ...patch, rev: state.rev + 1, changed })
const noChange = (state: CloudState, value: unknown): ReduceResult<CloudState> => ({ ok: true, state, value, changed: false })
const withoutPending = (state: CloudState, key: string) => Object.fromEntries(Object.entries(state.pending).filter(([k]) => k !== key))
const unavailable = () => ({ ...reject("cloud.provider.unavailable", "Cloud machines are not configured on this deployment"), retryable: true })

const upsertMachine = (row: MachineRow, n: number | null): RowWrite => ({ table: TABLE_MACHINE, op: "upsert", key: row.id, n, row })
const upsertLedger = (row: LedgerRow, n: number | null): RowWrite => ({ table: TABLE_LEDGER, op: "upsert", key: row.key, n, row })

export const cloudDomain = (config: CloudConfig): Domain<CloudState> => ({
  initial: () => ({ team: null, rev: 0, active: 0, saved: 0, pending: {}, changed: null }),

  authorize: (state, op, _params, principal) => {
    if (principal.kind === "system") return admit("cloud:CloudDO", op, principal, () => undefined, Date.now())
    if (!principal.team || !principal.user) return { code: "auth.forbidden", message: "needs a team member" }
    if (state.team !== null && state.team !== principal.team) return { code: "auth.forbidden", message: "not this team's machines" }
    if (isAgent(principal) && op === "cloud.machine.create") return { code: "auth.forbidden", message: "an agent cannot create machines" }
    if (isAgent(principal) && op === "cloud.machine.delete") return { code: "auth.forbidden", message: "an agent cannot delete machines" }
    // Money and destructive ops need a signed-in person, never an install's grant (even one that lists
    // money/destructive). Later: an install with a fresh single-use origin.confirmation (decision ORIGIN).
    if (principal.kind !== "session" && op === "cloud.machine.create") return { code: "auth.forbidden", message: "creating a machine needs a signed-in person" }
    if (principal.kind !== "session" && op === "cloud.machine.delete") return { code: "auth.forbidden", message: "deleting a machine needs a signed-in person" }
    return admit("cloud:CloudDO", op, principal, grantClasses, Date.now())
  },

  reduce: (state, op, params, ctx): ReduceResult<CloudState> => {
    switch (op) {
      case "cloud.machine.create":
        return create(config, state, params, ctx)
      case "cloud.machine.rename":
      case "cloud.machine.idle_policy.set":
        return update(state, op, params, ctx)
      case "cloud.machine.delete":
        return remove(config, state, params, ctx)
      case "cloud.driver_result":
        return driverResult(state, params, ctx)
      case "cloud.prune":
        return prune(state, params, ctx)
      default:
        return reject("validation.invalid", `unknown op ${op}`)
    }
  }
})

const create = (config: CloudConfig, state: CloudState, params: unknown, ctx: ReduceContext): ReduceResult<CloudState> => {
  const d = decodeParams<typeof CloudMachineCreate.params.Type>(CloudMachineCreate, params)
  if (!d.ok) return d
  const p = ctx.principal
  // Plan checks come before anything that could reach the provider.
  const plan = teamPlan(config, state.team ?? p.team)
  if (!plan) return reject("cloud.plan.required", "Cloud machines need a paid plan")
  if (d.value.from_snapshot !== undefined) return reject("cloud.snapshot.not_found", "no such snapshot")
  const memory = d.value.size.memory_mb ?? plan.memory_options_mb[0] ?? 4096
  if (sizeLocked(plan, memory)) return reject("cloud.size.locked", "this size needs another plan", { memory_mb: memory })
  const cpu = d.value.size.cpu ?? DEFAULT_SIZE.cpu
  const disk = d.value.size.disk_mb ?? DEFAULT_SIZE.disk_mb
  if (cpu > plan.max_cpu) return reject("cloud.size.locked", "this size needs another plan", { cpu })
  if (disk > plan.max_disk_mb) return reject("cloud.size.locked", "this size needs another plan", { disk_mb: disk })
  if (state.active >= plan.max_active) return reject("cloud.quota.exceeded", `this plan allows ${plan.max_active} active machines`, { limit: plan.max_active, used: state.active, resource: "active" })
  if (!ctx.idempotencyKey) return unavailable()
  const blocked = createConfigProblem(config)
  if (blocked || !config.prefix || !config.image) return { ...reject(blocked?.code ?? "cloud.provider.unavailable", blocked?.message ?? "Cloud machines are not configured"), retryable: blocked?.retryable ?? true }
  // Only the deployment's image: a client never picks an arbitrary snapshot on the shared provider account.
  if (d.value.image !== undefined && d.value.image !== config.image) return reject("validation.invalid", "unknown image")
  const rev = state.rev + 1
  const id = ctx.newId("vm")
  // The id comes from the request's transaction (identity and key): a key re-sent after the engine's
  // 7-day ledger window names the same id. Never upsert over a live machine or a tombstone.
  if (ctx.rows?.get(TABLE_MACHINE, id) || ctx.rows?.get(TABLE_TOMBSTONE, id)) return reject("idempotency.conflict", "this idempotency key was already used for another machine")
  const name = providerName(config.prefix, id)
  const machine: MachineRow = {
    id,
    team: state.team ?? p.team!,
    creator: p.user!,
    name: d.value.name ?? null,
    size: { cpu, memory_mb: memory, disk_mb: disk },
    status: "provisioning",
    image: { id: config.image, daemon_version: null },
    host: null,
    classic: false,
    created_at: ctx.now,
    last_active_at: null,
    idle_policy: { idle_seconds: DEFAULT_IDLE_SECONDS },
    error: null,
    revision: String(rev),
    provider_name: name
  }
  const key = ledgerKey(p.identity, ctx.idempotencyKey)
  const ledger: LedgerRow = { key, op: "create", machine: id, provider_name: name, state: "pending", provider_id: null, attempts: 0, error: null, created_at: ctx.now, updated_at: ctx.now }
  const s = next(state, { team: machine.team, active: state.active + 1, pending: { ...state.pending, [key]: { machine: id, due_at: ctx.now + PENDING_SAFETY_MS } } }, { machine: id, removed: false })
  return { ok: true, state: s, value: { machine: publicMachine(machine) }, writes: [upsertMachine(machine, rev), upsertLedger(ledger, rev)] }
}

const update = (state: CloudState, op: string, params: unknown, ctx: ReduceContext): ReduceResult<CloudState> => {
  const rename = op === "cloud.machine.rename"
  const d = decodeParams<{ machine: string; name?: string; idle_seconds?: number }>(rename ? CloudMachineRename : CloudMachineIdlePolicySet, params)
  if (!d.ok) return d
  const stored = machineRow(ctx.rows, d.value.machine)
  if (!stored) return reject("cloud.machine.not_found", "no such machine in this team")
  if (!mayManage(ctx.principal, stored.row)) return reject("auth.forbidden", "only the machine's creator or a team admin may change it")
  const rev = state.rev + 1
  const row: MachineRow = rename
    ? { ...stored.row, name: d.value.name!, revision: String(rev) }
    : // Recorded only: applying the idle policy to the provider comes with start/pause (state-placement.md 7.4).
      { ...stored.row, idle_policy: { idle_seconds: d.value.idle_seconds! }, revision: String(rev) }
  return { ok: true, state: next(state, {}, { machine: row.id, removed: false }), value: { machine: publicMachine(row) }, writes: [upsertMachine(row, stored.n)] }
}

const remove = (config: CloudConfig, state: CloudState, params: unknown, ctx: ReduceContext): ReduceResult<CloudState> => {
  const d = decodeParams<typeof CloudMachineDelete.params.Type>(CloudMachineDelete, params)
  if (!d.ok) return d
  // The tombstone answers every key for 30 days.
  if (ctx.rows?.get(TABLE_TOMBSTONE, d.value.machine)) return noChange(state, { deleted: true })
  const stored = machineRow(ctx.rows, d.value.machine)
  if (!stored) return reject("cloud.machine.not_found", "no such machine in this team")
  if (!mayManage(ctx.principal, stored.row)) return reject("auth.forbidden", "only the machine's creator or a team admin may delete it")
  // A delete already waiting for its call: the same answer, no new ledger row (no churn).
  const deleting = Object.entries(state.pending).some(([key, e]) => e.machine === stored.row.id && ledgerRow(ctx.rows, key)?.row.op === "delete")
  if (deleting) return noChange(state, { deleted: true })
  if (!config.prefix || !ctx.idempotencyKey) return unavailable()
  const rev = state.rev + 1
  const writes: Array<RowWrite> = []
  let pending = { ...state.pending }
  // P1-2: a create still waiting for its call may already have made the VM (a timeout, a lost
  // answer). It never creates again, but stays pending as finds by name until a definite answer;
  // the delete (ordered after it) waits, so it never finishes as deleted while a VM could appear.
  for (const [key, entry] of Object.entries(state.pending)) {
    const l = entry.machine === stored.row.id ? ledgerRow(ctx.rows, key) : undefined
    if (l?.row.op !== "create" || l.row.cancel) continue
    writes.push(upsertLedger({ ...l.row, cancel: true, attempts: 0, updated_at: ctx.now }, l.n))
    pending = { ...pending, [key]: { machine: entry.machine, due_at: ctx.now } }
  }
  const key = ledgerKey(ctx.principal.identity, ctx.idempotencyKey)
  writes.push(upsertLedger({ key, op: "delete", machine: stored.row.id, provider_name: stored.row.provider_name, state: "pending", provider_id: null, attempts: 0, error: null, created_at: ctx.now, updated_at: ctx.now }, rev))
  const row: MachineRow = { ...stored.row, status: "deleting", revision: String(rev) }
  writes.push(upsertMachine(row, stored.n))
  const s = next(state, { active: state.active - counted(stored.row.status), pending: { ...pending, [key]: { machine: row.id, due_at: ctx.now + PENDING_SAFETY_MS } } }, { machine: row.id, removed: false })
  return { ok: true, state: s, value: { deleted: true }, writes }
}

const driverResult = (state: CloudState, params: unknown, ctx: ReduceContext): ReduceResult<CloudState> => {
  const d = decodeInternal<typeof CloudDriverResultParams.Type>(CloudDriverResultParams, params)
  if (!d.ok) return d
  const r = d.value
  const stored = ledgerRow(ctx.rows, r.key)
  // A result for a call that is no longer pending (a duplicate, or a create a delete cancelled) changes nothing.
  if (!stored || stored.row.state !== "pending" || !state.pending[r.key]) return noChange(state, { applied: false })
  const l = stored.row
  const rev = state.rev + 1
  const machine = machineRow(ctx.rows, l.machine)
  const pending = withoutPending(state, r.key)
  if (!r.ok) {
    const attempts = l.attempts + 1
    const error = { code: r.error?.code ?? "cloud.provider.unavailable", message: r.error?.message ?? "provider call failed" }
    if (r.final !== true && attempts < MAX_ATTEMPTS) {
      const delay = l.cancel ? cancelFindDelayMs(attempts) : retryDelayMs(attempts)
      const s = next(state, { pending: { ...state.pending, [r.key]: { machine: l.machine, due_at: ctx.now + delay } } })
      return { ok: true, state: s, value: { applied: true, final: false }, writes: [upsertLedger({ ...l, attempts, error, updated_at: ctx.now }, stored.n)] }
    }
    // A cancelled create that never appeared: settled; the machine stays deleting for its delete.
    if (l.cancel) return { ok: true, state: next(state, { pending }), value: { applied: true, final: true }, writes: [upsertLedger({ ...l, state: "cancelled", attempts, error, updated_at: ctx.now }, stored.n)] }
    const writes: Array<RowWrite> = [upsertLedger({ ...l, state: "failed", attempts, error, updated_at: ctx.now }, stored.n)]
    if (!machine) return { ok: true, state: next(state, { pending }), value: { applied: true, final: true }, writes }
    const row: MachineRow = { ...machine.row, status: "failed", error: { ...error, at: ctx.now }, revision: String(rev) }
    writes.push(upsertMachine(row, machine.n))
    return { ok: true, state: next(state, { pending, active: state.active - counted(machine.row.status) }, { machine: row.id, removed: false }), value: { applied: true, final: true }, writes }
  }
  const done = upsertLedger({ ...l, state: "done", provider_id: r.provider_id ?? l.provider_id, error: null, updated_at: ctx.now }, stored.n)
  // The VM exists; the machine stays provisioning until its bind agent binds it (5.8).
  if (l.op === "create" || !machine) return { ok: true, state: next(state, { pending }), value: { applied: true }, writes: [done] }
  const tomb: TombstoneRow = { machine: l.machine, deleted_at: ctx.now, revision: String(rev) }
  const writes: Array<RowWrite> = [done, { table: TABLE_MACHINE, op: "delete", key: l.machine }, { table: TABLE_TOMBSTONE, op: "upsert", key: l.machine, n: rev, row: tomb }]
  // Other deletes of the same machine still run (by name, so they find nothing and succeed).
  return { ok: true, state: next(state, { pending, active: state.active - counted(machine.row.status) }, { machine: l.machine, removed: true }), value: { applied: true }, writes }
}

const prune = (state: CloudState, params: unknown, ctx: ReduceContext): ReduceResult<CloudState> => {
  const d = decodeInternal<typeof CloudPruneParams.Type>(CloudPruneParams, params)
  if (!d.ok) return d
  const writes: Array<RowWrite> = []
  for (const t of ctx.rows?.range<TombstoneRow>(TABLE_TOMBSTONE, { limit: 100 }) ?? []) {
    if (t.row.deleted_at > d.value.now - TOMBSTONE_MS) break
    writes.push({ table: TABLE_TOMBSTONE, op: "delete", key: t.key })
  }
  for (const l of ctx.rows?.range<LedgerRow>(TABLE_LEDGER, { limit: 100 }) ?? []) {
    if (l.row.state !== "pending" && l.row.updated_at <= d.value.now - LEDGER_KEEP_MS) writes.push({ table: TABLE_LEDGER, op: "delete", key: l.key })
  }
  if (writes.length === 0) return noChange(state, { pruned: 0 })
  return { ok: true, state: next(state, {}), value: { pruned: writes.length }, writes }
}
