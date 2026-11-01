import type { ReduceContext, ReduceResult, RowWrite, StoredRow } from "@cmux/ownership"
import { CloudSnapshotCreate, CloudSnapshotDelete, CloudSnapshotRestore, planRequiredDetails, type CloudDriverResultParams, type CloudSnapshot } from "@cmux/protocol"
import { decodeParams, reject } from "./common.ts"
import { limitDetails, providerName, teamPlan, type CloudConfig } from "./cloud-plan.ts"
import { ledgerKey, machineRow, PLATFORM_IDENTITY_PREFIX, TABLE_LEDGER, TABLE_SNAPSHOT, mayManage, next, noChangePower, PENDING_SAFETY_MS, unavailable, upsertLedger, withoutPending, type CloudState, type LedgerRow } from "./cloud.ts"

/**
 * Snapshots (state-placement.md 7 item 4; CLOUDDO-MONEY-OPS). A snapshot row is private; the public
 * view is CloudSnapshot. The provider slug is `<prefix>snap-<20 hex>` (the guard checks it); only the
 * slug recorded here is ever deleted. `saved` also reserves uncertain VM API deletions until cleanup is verified.
 */

export interface SnapshotRow {
  /** Created by a platform snapshot operation; survives ledger pruning and source-machine deletion. */
  readonly platform?: true
  /** This intent requires the journaled VM API capture protocol before it can send. */
  readonly capture_protocol?: 1
  /** A VM API deletion still holds its saved slot until verified cleanup. */
  readonly saved_reserved?: boolean
  readonly transport?: import("../cloud-vm-api-config.ts").CloudTransport
  readonly id: string
  readonly machine: string
  readonly name: string | null
  readonly size_mb: number
  readonly status: "creating" | "ready" | "deleting" | "failed"
  readonly created_at: number
  readonly revision: string
  readonly provider_name: string
  /** Who took it (decides delete once its machine is gone). */
  readonly creator?: string
  /** The machine's size when it was taken (a restore asks for it). */
  readonly size: { readonly cpu: number; readonly memory_mb: number; readonly disk_mb: number }
}

export const publicSnapshot = (r: SnapshotRow): typeof CloudSnapshot.Type => {
  const { transport: _t, provider_name: _p, size: _s, creator: _c, capture_protocol: _cp, saved_reserved: _sr, platform: _pf, ...view } = r
  return view
}
const counts = (s: SnapshotRow["status"]) => (s === "creating" || s === "ready" ? 1 : 0)
const counted = (r: SnapshotRow) => counts(r.status) || (r.status === "deleting" && r.saved_reserved === true ? 1 : 0)
const upsertSnapshot = (row: SnapshotRow, n: number | null): RowWrite => ({ table: TABLE_SNAPSHOT, op: "upsert", key: row.id, n, row })
export const snapshotRow = (ctx: ReduceContext, id: string) => ctx.rows?.get<SnapshotRow>(TABLE_SNAPSHOT, id)

export const snapshotCreate = (config: CloudConfig, state: CloudState, params: unknown, ctx: ReduceContext): ReduceResult<CloudState> => {
  const d = decodeParams<typeof CloudSnapshotCreate.params.Type>(CloudSnapshotCreate, params)
  if (!d.ok) return d
  const stored = machineRow(ctx.rows, d.value.machine)
  if (!stored) return reject("cloud.machine.not_found", "no such machine in this team")
  const m = stored.row
  if (!mayManage(ctx.principal, m)) return reject("auth.forbidden", "only the machine's creator or a team admin may snapshot it")
  // The provider snapshots a running or paused VM; a machine that never bound has nothing worth keeping.
  if ((m.status !== "running" && m.status !== "paused") || !m.host) return reject("cloud.machine.not_running", "only a running or paused machine can be snapshotted", { machine: m.id, state: m.status })
  const plan = teamPlan(config, state.team ?? ctx.principal.team)
  if (!plan) return reject("cloud.plan.required", "Cloud machines need a paid plan", planRequiredDetails())
  if (state.saved >= plan.max_saved) return reject("cloud.quota.exceeded", `this plan keeps ${plan.max_saved} saved snapshots`, limitDetails(plan, { limit: plan.max_saved, used: state.saved, resource: "saved" }))
  if (!config.prefix || !ctx.idempotencyKey) return unavailable()
  const rev = state.rev + 1
  const id = ctx.newId("snap")
  const size = { cpu: m.size.cpu ?? 0, memory_mb: m.size.memory_mb ?? 0, disk_mb: m.size.disk_mb ?? 0 }
  const protocol = m.transport === "vm-api" ? { capture_protocol: 1 as const } : {}
  const row: SnapshotRow = { ...(ctx.principal.identity.startsWith(PLATFORM_IDENTITY_PREFIX) ? { platform: true as const } : {}), ...protocol, transport: m.transport ?? "direct", id, machine: m.id, name: d.value.name ?? null, size_mb: size.disk_mb, status: "creating", created_at: ctx.now, revision: String(rev), provider_name: providerName(config.prefix, id), size, creator: ctx.principal.user! }
  const key = ledgerKey(ctx.principal.identity, ctx.idempotencyKey)
  const ledger: LedgerRow = { ...protocol, transport: m.transport ?? "direct", key, op: "snapshot", machine: m.id, provider_name: m.provider_name, state: "pending", provider_id: null, attempts: 0, error: null, created_at: ctx.now, updated_at: ctx.now, snapshot: id, snapshot_name: row.provider_name }
  const s = next(state, { saved: state.saved + 1, pending: { ...state.pending, [key]: { machine: m.id, due_at: ctx.now + PENDING_SAFETY_MS } } }, { machine: m.id, removed: false, snapshot: id })
  return { ok: true, state: s, value: { snapshot: publicSnapshot(row) }, writes: [upsertLedger(ledger, rev), upsertSnapshot(row, rev)] }
}

export const snapshotDelete = (config: CloudConfig, state: CloudState, params: unknown, ctx: ReduceContext): ReduceResult<CloudState> => {
  const d = decodeParams<typeof CloudSnapshotDelete.params.Type>(CloudSnapshotDelete, params)
  if (!d.ok) return d
  const stored = snapshotRow(ctx, d.value.snapshot)
  if (!stored) return reject("cloud.snapshot.not_found", "no such snapshot")
  const r = stored.row
  const source = machineRow(ctx.rows, r.machine)
  // The machine may be gone; then the team admin (or the creator recorded on no row) decides: personal teams only today.
  // The machine's creator or a team admin; once the machine is gone, the snapshot's own creator or a team admin (review P3).
  const owner = (source ? source.row : { creator: r.creator ?? "" }) as Parameters<typeof mayManage>[1]
  if (!mayManage(ctx.principal, owner)) return reject("auth.forbidden", "only the machine's creator or a team admin may delete its snapshots")
  if (!ctx.idempotencyKey) return unavailable()
  return snapshotRetire(config, state, stored, ledgerKey(ctx.principal.identity, ctx.idempotencyKey), ctx)
}

/**
 * The delete of one snapshot row after its caller's checks: snapshot.delete (a person), an environment's
 * delete, or CloudDO replacing an environment's snapshot with a newer build (system, cloud-environment.ts).
 */
export const snapshotRetire = (config: CloudConfig, state: CloudState, stored: StoredRow<SnapshotRow>, key: string, ctx: ReduceContext): ReduceResult<CloudState> => {
  const r = stored.row
  if (r.status === "deleting" && r.transport !== "vm-api") return noChangePower(state, { deleted: true })
  if (Object.values(state.pending).some((e) => e.machine === r.machine) && r.status === "creating" && r.transport !== "vm-api") return reject("cloud.machine.busy", "the snapshot is still being taken; retry when it is ready", { snapshot: r.id })
  if (!config.prefix) return unavailable()
  const rev = state.rev + 1
  const protocol = r.capture_protocol === 1 ? { capture_protocol: 1 as const } : {}
  const ledger: LedgerRow = { ...protocol, transport: r.transport ?? "direct", key, op: "snapshot_delete", machine: r.machine, provider_name: r.provider_name, state: "pending", provider_id: null, attempts: 0, error: null, created_at: ctx.now, updated_at: ctx.now, snapshot: r.id, snapshot_name: r.provider_name, snapshot_status: r.status }
  const pending = { ...state.pending }, cancelled: RowWrite[] = []
  if (r.transport === "vm-api") for (const k of Object.keys(pending)) {
    const original = ctx.rows?.get<LedgerRow>(TABLE_LEDGER, k)
    if (original?.row.op !== "snapshot" || original.row.snapshot !== r.id) continue
    delete pending[k]
    cancelled.push(upsertLedger({ ...original.row, state: "cancelled", cancel: true, updated_at: ctx.now }, original.n))
  }
  const hold = r.transport === "vm-api"
  const row: SnapshotRow = { ...r, status: "deleting", revision: String(rev), ...(hold ? { saved_reserved: true } : {}) }
  const s = next(state, { saved: state.saved + (hold ? 1 - counted(r) : -counted(r)), pending: { ...pending, [key]: { machine: r.machine, due_at: ctx.now + PENDING_SAFETY_MS } } }, { machine: r.machine, removed: false, snapshot: r.id })
  return { ok: true, state: s, value: { deleted: true }, writes: [...cancelled, upsertLedger(ledger, rev), upsertSnapshot(row, stored.n)] }
}

/** A snapshot_delete may settle on an empty key fence when no capture under the key can still be in flight:
 *  a journaled capture, or a row whose capture already ended (ready, or a legacy failure that predates the journal). */
export const emptyFenceSettles = (l: Pick<LedgerRow, "capture_protocol" | "snapshot_status">): boolean =>
  l.capture_protocol === 1 || l.snapshot_status === "ready" || l.snapshot_status === "failed"

/** cloud.snapshot.restore: a new machine from a ready snapshot (all create checks), through create's from_snapshot. */
export const snapshotRestore = (_state: CloudState, params: unknown, ctx: ReduceContext, create: (params: unknown) => ReduceResult<CloudState>): ReduceResult<CloudState> => {
  const d = decodeParams<typeof CloudSnapshotRestore.params.Type>(CloudSnapshotRestore, params)
  if (!d.ok) return d
  const stored = snapshotRow(ctx, d.value.snapshot)
  if (!stored || stored.row.status !== "ready") return reject("cloud.snapshot.not_found", "no such snapshot")
  return create({ ...(d.value.name ? { name: d.value.name } : {}), size: stored.row.size, from_snapshot: stored.row.id })
}

/** The outcome of a snapshot or snapshot_delete call. */
export const snapshotResult = (state: CloudState, stored: StoredRow<LedgerRow>, r: typeof CloudDriverResultParams.Type, ctx: ReduceContext): ReduceResult<CloudState> => {
  const l = stored.row
  const pending = withoutPending(state, l.key)
  const error = r.ok ? null : { code: r.error?.code ?? "cloud.provider.unavailable", message: r.error?.message ?? "provider call failed" }
  const writes: Array<RowWrite> = [upsertLedger({ ...l, state: r.ok ? "done" : "failed", attempts: l.attempts + 1, error, provider_id: r.provider_id ?? l.provider_id, updated_at: ctx.now }, stored.n)]
  const snap = l.snapshot ? snapshotRow(ctx, l.snapshot) : undefined
  if (!snap) return { ok: true, state: next(state, { pending }), value: { applied: true }, writes }
  const rev = state.rev + 1
  if (l.op === "snapshot") {
    if (snap.row.status !== "creating") return { ok: true, state: next(state, { pending }), value: { applied: true }, writes }
    const row: SnapshotRow = { ...snap.row, status: r.ok ? "ready" : "failed", revision: String(rev) }
    writes.push(upsertSnapshot(row, snap.n))
    return { ok: true, state: next(state, { pending, saved: state.saved - counts(snap.row.status) + counts(row.status) }, { machine: row.machine, removed: false, snapshot: row.id }), value: { applied: true }, writes }
  }
  if (r.ok) {
    writes.push({ table: TABLE_SNAPSHOT, op: "delete", key: snap.row.id })
    return { ok: true, state: next(state, { pending, saved: state.saved - (snap.row.saved_reserved === true ? 1 : 0) }, { machine: snap.row.machine, removed: true, snapshot: snap.row.id }), value: { applied: true }, writes }
  }
  // The provider kept the snapshot: its status (and count) from before the delete (review P3).
  const before = l.snapshot_status && l.snapshot_status !== "deleting" ? l.snapshot_status : "ready"
  const row: SnapshotRow = { ...snap.row, status: before, revision: String(rev) }
  writes.push(upsertSnapshot(row, snap.n))
  return { ok: true, state: next(state, { pending, saved: state.saved + counts(before) }, { machine: row.machine, removed: false, snapshot: row.id }), value: { applied: true, final: true }, writes }
}
