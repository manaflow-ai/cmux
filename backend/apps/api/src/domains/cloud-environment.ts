import type { OutboxItem, ReduceContext, ReduceResult, RowReader, RowWrite, StoredRow } from "@cmux/ownership"
import { environmentBuildDigest, environmentSpecBody, formatEnvironmentRepo, parseEnvironmentSpec, type EnvironmentSpec } from "@cmux/cloud-env"
import { CloudEnvironmentBoot, CloudEnvironmentBuildOp, CloudEnvironmentDelete, CloudEnvironmentSet, planRequiredDetails, type CloudDriverResultParams, type CloudEnvironment } from "@cmux/protocol"
import { decodeParams, reject } from "./common.ts"
import { createConfigProblem, DEFAULT_MEMORY_MB, DEFAULT_SIZE, limitDetails, providerName, teamPlan, type CloudConfig } from "./cloud-plan.ts"
import { snapshotRetire, type SnapshotRow } from "./cloud-snapshot.ts"
import { ledgerKey, mayManage, next, TABLE_ENVIRONMENT, TABLE_LEDGER, TABLE_MACHINE, TABLE_SNAPSHOT, unavailable, upsertLedger, withoutPending, type CloudState, type LedgerRow, type MachineRow } from "./cloud.ts"

/**
 * Cloud environments in CloudDO (plans/cmux-next/cloud-environments-DESIGN.md §7): one private row per
 * environment next to the team's machines and snapshots. A build is one `env_build` ledger row the
 * provider pass runs (cloud-do-core.ts: builder machine, detached setup, snapshot, warm boot, builder
 * deleted); its snapshot is an ordinary snapshot row, so quota, listing and deletion are the snapshot
 * code's. A boot is cloud.machine.create, from the snapshot or cold with `env_setup` on the machine.
 * Each change projects a summary row (no spec, no variable values) to Vitess `cloud_environments`.
 */

export { TABLE_ENVIRONMENT as TABLE_ENVIRONMENT_ROWS } from "./cloud.ts"
export const MAX_ENVIRONMENTS = 20
/** A build inside the CloudDO alarm stays well inside its 15-minute wall-clock limit. */
export const ENV_SETUP_TIMEOUT_MS = 10 * 60_000

export interface EnvironmentBuildRecord {
  readonly state: "building" | "ready" | "failed"
  readonly digest: string
  readonly key: string
  readonly started_at: number
  readonly finished_at: number | null
  readonly error: { readonly code: string; readonly message: string } | null
  readonly log_tail: string | null
  readonly timings: { boot_ms: number; ready_ms: number; setup_ms: number; snapshot_ms: number; warm_ms: number; total_ms: number } | null
}

export interface EnvironmentRow {
  readonly id: string
  readonly team: string
  readonly creator: string
  readonly spec: EnvironmentSpec
  /** The snapshot row new machines boot from, the digest it was built for, and that build's transport. */
  readonly snapshot: string | null
  readonly snapshot_digest: string | null
  readonly build: EnvironmentBuildRecord | null
  readonly created_at: number
  readonly updated_at: number
  readonly revision: string
}

type Status = (typeof CloudEnvironment.Type)["status"]

export const environmentRow = (rows: RowReader | undefined, id: string) => rows?.get<EnvironmentRow>(TABLE_ENVIRONMENT, id)
const snapshotOf = (rows: RowReader | undefined, env: EnvironmentRow) => (env.snapshot ? rows?.get<SnapshotRow>(TABLE_SNAPSHOT, env.snapshot) : undefined)
const hasSecrets = (spec: EnvironmentSpec) => spec.env.some((v) => "secret" in v)

/** The snapshot new machines boot from now, or null: ready, built for these inputs and this image, on this transport. */
export const freshSnapshot = (config: CloudConfig, rows: RowReader | undefined, env: EnvironmentRow): SnapshotRow | null => {
  const snap = snapshotOf(rows, env)?.row
  if (!snap || snap.status !== "ready" || !config.image || env.snapshot_digest === null) return null
  if ((snap.transport ?? "direct") !== (config.transport ?? "direct")) return null
  return env.snapshot_digest === environmentBuildDigest(env.spec, config.image) ? snap : null
}

export const environmentStatus = (config: CloudConfig, rows: RowReader | undefined, env: EnvironmentRow): Status => {
  if (env.build?.state === "building") return "building"
  if (freshSnapshot(config, rows, env)) return "ready"
  if (env.snapshot) return "stale"
  return env.build?.state === "failed" ? "failed" : "unbuilt"
}

export const publicEnvironment = (config: CloudConfig, rows: RowReader | undefined, env: EnvironmentRow): typeof CloudEnvironment.Type => ({
  id: env.id,
  name: env.spec.name,
  repo: formatEnvironmentRepo(env.spec.repo),
  setup_script: env.spec.setupScript,
  env: env.spec.env,
  creator: env.creator,
  status: environmentStatus(config, rows, env),
  snapshot: env.snapshot,
  last_build: env.build ? { state: env.build.state, started_at: env.build.started_at, finished_at: env.build.finished_at, error: env.build.error, log_tail: env.build.log_tail, timings: env.build.timings } : null,
  created_at: env.created_at,
  revision: env.revision
})

/** The Vitess summary row: never the setup script or a variable value. */
const project = (config: CloudConfig, rows: RowReader | undefined, env: EnvironmentRow): OutboxItem => ({
  kind: "cloud.environment.upsert",
  entity: env.id,
  payload: { id: env.id, team_id: env.team, name: env.spec.name, repo: formatEnvironmentRepo(env.spec.repo), status: environmentStatus(config, rows, env), snapshot_id: env.snapshot, created_by: env.creator, created_at: env.created_at, updated_at: env.updated_at }
})
const projectDelete = (env: EnvironmentRow): OutboxItem => ({ kind: "cloud.environment.delete", entity: env.id, payload: { id: env.id, team_id: env.team } })
const upsertEnvironment = (row: EnvironmentRow, n: number | null): RowWrite => ({ table: TABLE_ENVIRONMENT, op: "upsert", key: row.id, n, row })

/** A reader that sees `writes` over `rows`, so a status computed in the same reduce matches the commit. */
const overlay = (rows: RowReader | undefined, writes: ReadonlyArray<RowWrite>): RowReader | undefined => {
  if (!rows) return rows
  const get = <T>(table: string, key: string): StoredRow<T> | undefined => {
    for (let i = writes.length - 1; i >= 0; i--) {
      const w = writes[i]!
      if (w.table === table && w.key === key) return w.op === "delete" ? undefined : ({ key, n: w.n ?? rows.get<T>(table, key)?.n ?? null, row: w.row } as StoredRow<T>)
    }
    return rows.get<T>(table, key)
  }
  return { get, range: (table, range) => rows.range(table, range) }
}

const manager = (env: EnvironmentRow) => ({ creator: env.creator }) as unknown as MachineRow

export const environmentSet = (config: CloudConfig, state: CloudState, params: unknown, ctx: ReduceContext): ReduceResult<CloudState> => {
  const d = decodeParams<typeof CloudEnvironmentSet.params.Type>(CloudEnvironmentSet, params)
  if (!d.ok) return d
  const p = d.value
  const stored = p.environment === undefined ? undefined : environmentRow(ctx.rows, p.environment)
  if (p.environment !== undefined && !stored) return reject("cloud.environment.not_found", "no such environment in this team")
  if (stored && !mayManage(ctx.principal, manager(stored.row))) return reject("auth.forbidden", "only the environment's creator or a team admin may change it")
  const base: Record<string, unknown> = stored ? environmentSpecBody(stored.row.spec) : {}
  const body = { ...base, ...(p.name !== undefined ? { name: p.name } : {}), ...(p.repo !== undefined ? { repo: p.repo } : {}), ...(p.setup_script !== undefined ? { setupScript: p.setup_script } : {}), ...(p.env !== undefined ? { env: p.env } : {}) }
  const parsed = parseEnvironmentSpec(body)
  if (!parsed.ok) {
    const field = parsed.error.field === "setupScript" ? "setup_script" : parsed.error.field
    return reject("cloud.environment.invalid", parsed.error.message, { field, message: parsed.error.message })
  }
  const rev = state.rev + 1
  if (!stored) {
    const count = ctx.rows?.range<EnvironmentRow>(TABLE_ENVIRONMENT, { limit: MAX_ENVIRONMENTS + 1 }).length ?? 0
    if (count >= MAX_ENVIRONMENTS) return reject("cloud.quota.exceeded", `a team keeps at most ${MAX_ENVIRONMENTS} environments`, { limit: MAX_ENVIRONMENTS, used: count, resource: "environments" })
  }
  const row: EnvironmentRow = stored
    ? { ...stored.row, spec: parsed.spec, updated_at: ctx.now, revision: String(rev) }
    : { id: ctx.newId("env"), team: state.team ?? ctx.principal.team!, creator: ctx.principal.user!, spec: parsed.spec, snapshot: null, snapshot_digest: null, build: null, created_at: ctx.now, updated_at: ctx.now, revision: String(rev) }
  const writes = [upsertEnvironment(row, stored ? stored.n : rev)]
  const rows = overlay(ctx.rows, writes)
  return { ok: true, state: next(state, { team: state.team ?? row.team }), value: { environment: publicEnvironment(config, rows, row) }, writes, outbox: [project(config, rows, row)] }
}

export const environmentDelete = (config: CloudConfig, state: CloudState, params: unknown, ctx: ReduceContext): ReduceResult<CloudState> => {
  const d = decodeParams<typeof CloudEnvironmentDelete.params.Type>(CloudEnvironmentDelete, params)
  if (!d.ok) return d
  const stored = environmentRow(ctx.rows, d.value.environment)
  if (!stored) return reject("cloud.environment.not_found", "no such environment in this team")
  if (!mayManage(ctx.principal, manager(stored.row))) return reject("auth.forbidden", "only the environment's creator or a team admin may delete it")
  if (stored.row.build?.state === "building") return reject("cloud.environment.busy", "a build is running; delete it when the build ends", { environment: stored.row.id })
  if (!ctx.idempotencyKey) return unavailable()
  const writes: Array<RowWrite> = [{ table: TABLE_ENVIRONMENT, op: "delete", key: stored.row.id }]
  let s = next(state, {})
  const snap = snapshotOf(ctx.rows, stored.row)
  if (snap) {
    const retired = snapshotRetire(config, s, snap, ledgerKey(ctx.principal.identity, ctx.idempotencyKey), ctx)
    if (!retired.ok) return retired
    s = retired.state
    writes.push(...(retired.writes ?? []))
  }
  return { ok: true, state: s, value: { deleted: true }, writes, outbox: [projectDelete(stored.row)] }
}

export const environmentBuild = (config: CloudConfig, state: CloudState, params: unknown, ctx: ReduceContext): ReduceResult<CloudState> => {
  const d = decodeParams<typeof CloudEnvironmentBuildOp.params.Type>(CloudEnvironmentBuildOp, params)
  if (!d.ok) return d
  const stored = environmentRow(ctx.rows, d.value.environment)
  if (!stored) return reject("cloud.environment.not_found", "no such environment in this team")
  const env = stored.row
  if (!mayManage(ctx.principal, manager(env))) return reject("auth.forbidden", "only the environment's creator or a team admin may build it")
  if (hasSecrets(env.spec)) return reject("cloud.environment.secrets_unavailable", "secret variables need the cmux Vault for Cloud, which is not available yet; use plain variables or remove the secrets")
  if (env.build?.state === "building") return reject("cloud.environment.busy", "a build of this environment is already running", { environment: env.id })
  const plan = teamPlan(config, state.team ?? ctx.principal.team)
  if (!plan) return reject("cloud.plan.required", "Cloud environments need a paid plan", planRequiredDetails())
  const blocked = createConfigProblem(config)
  if (blocked || !config.prefix || !config.image) return { ...reject(blocked?.code ?? "cloud.provider.unavailable", blocked?.message ?? "Cloud machines are not configured"), retryable: blocked?.retryable ?? true }
  if (!ctx.idempotencyKey) return unavailable()
  // The same inputs on the same image: nothing to build.
  if (freshSnapshot(config, ctx.rows, env)) return { ok: true, state, value: { environment: publicEnvironment(config, ctx.rows, env), built: false }, changed: false }
  if (state.saved >= plan.max_saved) return reject("cloud.quota.exceeded", `this plan keeps ${plan.max_saved} saved snapshots`, limitDetails(plan, { limit: plan.max_saved, used: state.saved, resource: "saved" }))
  const rev = state.rev + 1
  const digest = environmentBuildDigest(env.spec, config.image)
  const builder = ctx.newId("vm")
  const warm = ctx.newId("vm")
  const snapId = ctx.newId("snap")
  const transport = config.transport ?? "direct"
  const size = { cpu: DEFAULT_SIZE.cpu, memory_mb: plan.memory_options_mb[0] ?? DEFAULT_MEMORY_MB, disk_mb: DEFAULT_SIZE.disk_mb }
  const snapshot: SnapshotRow = { transport, id: snapId, machine: builder, name: env.spec.name, size_mb: size.disk_mb, status: "creating", created_at: ctx.now, revision: String(rev), provider_name: providerName(config.prefix, snapId), size, creator: ctx.principal.user! }
  const key = ledgerKey(ctx.principal.identity, ctx.idempotencyKey)
  const ledger: LedgerRow = { transport, key, op: "env_build", machine: builder, provider_name: providerName(config.prefix, builder), state: "pending", provider_id: null, attempts: 0, error: null, created_at: ctx.now, updated_at: ctx.now, snapshot: snapId, snapshot_name: snapshot.provider_name, environment: env.id, env_digest: digest, env_warm: providerName(config.prefix, warm) }
  const row: EnvironmentRow = { ...env, build: { state: "building", digest, key, started_at: ctx.now, finished_at: null, error: null, log_tail: null, timings: null }, updated_at: ctx.now, revision: String(rev) }
  const writes = [upsertLedger(ledger, rev), { table: TABLE_SNAPSHOT, op: "upsert" as const, key: snapId, n: rev, row: snapshot }, upsertEnvironment(row, stored.n)]
  // Due at once: the alarm runs the build (minutes), never the request.
  const s = next(state, { saved: state.saved + 1, pending: { ...state.pending, [key]: { machine: builder, due_at: ctx.now } } }, { machine: builder, removed: false, snapshot: snapId })
  const rows = overlay(ctx.rows, writes)
  return { ok: true, state: s, value: { environment: publicEnvironment(config, rows, row), built: true }, writes, outbox: [project(config, rows, row)] }
}

export const environmentBoot = (config: CloudConfig, state: CloudState, params: unknown, ctx: ReduceContext, create: (params: unknown) => ReduceResult<CloudState>): ReduceResult<CloudState> => {
  const d = decodeParams<typeof CloudEnvironmentBoot.params.Type>(CloudEnvironmentBoot, params)
  if (!d.ok) return d
  const stored = environmentRow(ctx.rows, d.value.environment)
  if (!stored) return reject("cloud.environment.not_found", "no such environment in this team")
  const env = stored.row
  if (hasSecrets(env.spec)) return reject("cloud.environment.secrets_unavailable", "secret variables need the cmux Vault for Cloud, which is not available yet; use plain variables or remove the secrets")
  const name = d.value.name !== undefined ? { name: d.value.name } : {}
  const fresh = freshSnapshot(config, ctx.rows, env)
  if (fresh) {
    const r = create({ ...name, size: d.value.size, from_snapshot: fresh.id })
    return r.ok ? { ...r, value: { ...(r.value as object), boot: "snapshot" } } : r
  }
  const r = create({ ...name, size: d.value.size })
  if (!r.ok || !config.image) return r
  // Cold: the create's provider call starts the setup on the new machine (cloud-do-core.ts).
  const env_setup = { environment: env.id, digest: environmentBuildDigest(env.spec, config.image) }
  const writes = (r.writes ?? []).map((w) => (w.table === TABLE_MACHINE && w.op === "upsert" ? { ...w, row: { ...(w.row as MachineRow), env_setup } } : w))
  return { ...r, writes, value: { ...(r.value as object), boot: "cold" } }
}

/** The end of a build (cloud.driver_result of an env_build row): the snapshot row, the environment, the old snapshot. */
export const environmentBuildResult = (config: CloudConfig, state: CloudState, stored: StoredRow<LedgerRow>, r: typeof CloudDriverResultParams.Type, ctx: ReduceContext): ReduceResult<CloudState> => {
  const l = stored.row
  const error = r.ok ? null : { code: r.error?.code ?? "cloud.provider.unavailable", message: r.error?.message ?? "the build failed" }
  const writes: Array<RowWrite> = [upsertLedger({ ...l, state: r.ok ? "done" : "failed", attempts: l.attempts + 1, error, provider_id: r.provider_id ?? l.provider_id, updated_at: ctx.now }, stored.n)]
  let s = next(state, { pending: withoutPending(state, l.key) })
  // Atomically transfer both recorded names to cleanup when the build settles. Immediate deletion
  // is best effort; even an uncertain boot can have created a VM. Until this commit the pending
  // build owns recovery, so an alarm never deletes a builder while setup/snapshot is still running.
  for (const name of [l.provider_name, ...(l.env_warm ? [l.env_warm] : [])]) {
    const key = `env-cleanup:${name}`
    const cleanup: LedgerRow = { transport: l.transport ?? "direct", key, op: "env_cleanup", machine: l.machine, provider_name: name, state: "pending", provider_id: null, attempts: 0, error: null, created_at: ctx.now, updated_at: ctx.now }
    // Ordered ledger rows need distinct positions, including multiple rows in one
    // commit. Reserve a revision for each cleanup before any snapshot retirement.
    s = next(s, { pending: { ...s.pending, [key]: { machine: l.machine, due_at: ctx.now } } })
    writes.push(upsertLedger(cleanup, s.rev))
  }
  const snap = l.snapshot ? ctx.rows?.get<SnapshotRow>(TABLE_SNAPSHOT, l.snapshot) : undefined
  const envStored = l.environment ? environmentRow(ctx.rows, l.environment) : undefined
  const t = r.env_build?.timings
  if (r.ok && snap) {
    const ready: SnapshotRow = { ...snap.row, status: "ready", revision: String(s.rev) }
    writes.push({ table: TABLE_SNAPSHOT, op: "upsert", key: ready.id, n: snap.n, row: ready })
    s = { ...s, changed: { machine: ready.machine, removed: false, snapshot: ready.id } }
    const retire = (old: StoredRow<SnapshotRow> | undefined) => {
      if (!old) return
      const done = snapshotRetire(config, s, old, `env-retire:${old.row.id}`, { ...ctx, rows: overlay(ctx.rows, writes) })
      if (done.ok) {
        s = { ...done.state, changed: s.changed }
        writes.push(...(done.writes ?? []))
      }
    }
    if (!envStored) {
      // The environment was deleted meanwhile: its new snapshot goes too.
      retire({ ...snap, row: ready })
      return { ok: true, state: s, value: { applied: true }, writes }
    }
    const env = envStored.row
    const previous = env.snapshot && env.snapshot !== ready.id ? ctx.rows?.get<SnapshotRow>(TABLE_SNAPSHOT, env.snapshot) : undefined
    const row: EnvironmentRow = { ...env, snapshot: ready.id, snapshot_digest: l.env_digest ?? null, build: env.build ? { ...env.build, state: "ready", finished_at: ctx.now, error: null, log_tail: null, timings: t ?? null } : null, updated_at: ctx.now, revision: String(s.rev) }
    writes.push(upsertEnvironment(row, envStored.n))
    retire(previous)
    const rows = overlay(ctx.rows, writes)
    return { ok: true, state: s, value: { applied: true }, writes, outbox: [project(config, rows, row)] }
  }
  // Failed for good: a snapshot the provider never took leaves no row; one that may exist stays as failed.
  if (snap) {
    const taken = r.env_build?.stage === "snapshot" || r.env_build?.stage === "warm"
    if (taken) writes.push({ table: TABLE_SNAPSHOT, op: "upsert", key: snap.row.id, n: snap.n, row: { ...snap.row, status: "failed", revision: String(s.rev) } })
    else writes.push({ table: TABLE_SNAPSHOT, op: "delete", key: snap.row.id })
    s = { ...s, saved: s.saved - (snap.row.status === "creating" || snap.row.status === "ready" ? 1 : 0), changed: { machine: snap.row.machine, removed: !taken, snapshot: snap.row.id } }
  }
  if (!envStored) return { ok: true, state: s, value: { applied: true, final: true }, writes }
  const env = envStored.row
  const row: EnvironmentRow = { ...env, build: env.build ? { ...env.build, state: "failed", finished_at: ctx.now, error, log_tail: r.env_build?.log_tail ?? null } : null, updated_at: ctx.now, revision: String(s.rev) }
  writes.push(upsertEnvironment(row, envStored.n))
  const rows = overlay(ctx.rows, writes)
  return { ok: true, state: s, value: { applied: true, final: true }, writes, outbox: [project(config, rows, row)] }
}

/** The ledger row a machine's pending env_build waits on, if any (the alarm runs builds last). */
export const isEnvBuild = (rows: RowReader | undefined, key: string) => rows?.get<LedgerRow>(TABLE_LEDGER, key)?.row.op === "env_build"
