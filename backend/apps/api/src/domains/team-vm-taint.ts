import type { ReduceContext, ReduceResult } from "@cmux/ownership"
import { TeamVmMemberRemovedParams, TeamVmRebuildRequestedParams, TeamVmRetiredParams, TeamVmTaintAcceptedParams } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { reject } from "./common.ts"
import type { TeamVmState } from "./team-vm.ts"

/**
 * Team VM taint (cx-q4f3). Team members are root on the team VM (sudo, docker), so a removed member
 * may have left something running that no certificate revocation ends. A removal of a member who
 * held a team SSH certificate valid after the current VM was created taints that VM's epoch; an
 * owner or admin then accepts the risk or rebuilds (a new VM at the next epoch). A rebuilt VM is
 * paused with its run budget spent, so no inbound traffic resumes it (cx-009a), and kept in
 * `retired` until an owner deletes it (its files can be copied off first).
 */
export interface TeamVmTaint {
  readonly epoch: number
  readonly at: number
  readonly users: ReadonlyArray<string>
  readonly accepted_by: string | null
  readonly accepted_at: number | null
}

export interface TeamVmRetired {
  readonly vm: string
  readonly slug: string | null
  readonly epoch: number
  readonly state: "pausing" | "paused"
  readonly at: number
  readonly by: string
  readonly tainted_by: ReadonlyArray<string>
  /** While `pausing`: failed pause attempts and when the alarm tries again (backoff). */
  readonly pause_attempts?: number
  readonly pause_retry_at?: number
  /**
   * The provider confirmed the retire: run budget spent, then paused, so no inbound traffic
   * resumes it (cx-009a). A `paused` row without it was paused before the fence existed; the
   * alarm retires it again.
   */
  readonly fenced?: boolean
}

/** A rebuild keeps at most this many replaced VMs until an owner deletes some. */
export const MAX_RETIRED = 3

/** Pause retries back off like provider calls: 2 s doubling to 5 minutes. */
const pauseDelayMs = (attempts: number) => Math.min(5 * 60_000, 1000 * 2 ** attempts)

/** The taint that applies to the current epoch, or null (a taint of an older epoch ended with it). */
export const currentTaint = (s: TeamVmState): TeamVmTaint | null => (s.taint && s.vm !== null && s.taint.epoch === s.epoch ? s.taint : null)

/** Tainted and not accepted: members get no certificate and the VM's install cannot bind. */
export const taintBlocks = (s: TeamVmState): boolean => {
  const t = currentTaint(s)
  return t !== null && t.accepted_by === null
}

/**
 * A rebuilt VM the provider has not confirmed paused: team certificates are not bound to one VM,
 * so members get none until it is (the old VM may still run what the removed member left).
 */
export const pausingRetired = (s: TeamVmState): TeamVmRetired | null => (s.retired ?? []).find((r) => r.state === "pausing") ?? null

/** Installs of epochs below this are revoked: a rebuilt epoch's install goes before its replacement exists. */
export const staleBelow = (s: TeamVmState): number => ((s.retired ?? []).some((r) => r.epoch === s.epoch) ? s.epoch + 1 : s.epoch)

/** A retired VM the alarm still retires: not yet paused, or paused before the fence (cx-009a). */
export const retireDue = (r: TeamVmRetired): boolean => r.state === "pausing" || r.fenced !== true

/** The next pause retry of a retired VM, for the alarm. */
export const pauseWakeAt = (s: TeamVmState): number | null => {
  const times = (s.retired ?? []).filter(retireDue).map((r) => r.pause_retry_at ?? r.at)
  return times.length ? Math.min(...times) : null
}

const decode = <T>(schema: Schema.Top, params: unknown): { ok: true; value: T } | ReturnType<typeof reject> => {
  const exit = Schema.decodeUnknownExit(schema as Schema.Codec<T, unknown>)(params ?? {})
  return Exit.isSuccess(exit) ? { ok: true, value: exit.value } : reject("validation.invalid", "invalid params", String(exit.cause))
}

const same = (state: TeamVmState): ReduceResult<TeamVmState> => ({ ok: true, state, value: { applied: false }, changed: false })

/** `team_vm.member_removed`: delivered by the team's own TeamDO only (its outbox stream `team:<team>`). */
export const reduceMemberRemoved = (state: TeamVmState, params: unknown, ctx: ReduceContext): ReduceResult<TeamVmState> => {
  const d = decode<typeof TeamVmMemberRemovedParams.Type>(TeamVmMemberRemovedParams, params)
  if (!d.ok) return d
  // A forged or misrouted notice (another team's TeamDO, or any other system source) changes nothing.
  if (state.team === null || ctx.principal.identity !== `system:team:${state.team}`) return same(state)
  // No VM, or the member's certificates all ended before this VM existed: nothing they could have touched.
  if (state.vm === null || d.value.cert_valid_before <= (state.vm_created_at ?? 0)) return same(state)
  const cur = currentTaint(state)
  // The same removal again (a redelivery), or one the owner already accepted, changes nothing.
  if (cur?.users.includes(d.value.user) && (cur.accepted_at === null || d.value.at <= cur.accepted_at)) return same(state)
  // A new removal after an acceptance (another member, or the same one re-joined and removed again)
  // needs a new decision: the acceptance covered the removals made before it.
  const taint: TeamVmTaint = cur
    ? { ...cur, users: cur.users.includes(d.value.user) ? cur.users : [...cur.users, d.value.user], accepted_by: null, accepted_at: null }
    : { epoch: state.epoch, at: ctx.now, users: [d.value.user], accepted_by: null, accepted_at: null }
  return { ok: true, state: { ...state, taint, updated_at: ctx.now }, value: { tainted: true, epoch: state.epoch } }
}

/** Only TeamVmDO's own admin path submits these (after TeamDO checked the role); never a delivered item. */
const ownSystem = (ctx: ReduceContext) => ctx.principal.kind === "system" && ctx.principal.identity === "system:team_vm"

export const reduceTaintAccepted = (state: TeamVmState, params: unknown, ctx: ReduceContext): ReduceResult<TeamVmState> => {
  if (!ownSystem(ctx)) return reject("auth.forbidden", "internal op")
  const d = decode<typeof TeamVmTaintAcceptedParams.Type>(TeamVmTaintAcceptedParams, params)
  if (!d.ok) return d
  const cur = currentTaint(state)
  if (!cur || cur.epoch !== d.value.epoch) return reject("team_vm.not_tainted", "this epoch of the team VM is not tainted")
  // The owner accepts the removals they saw: a removal since then needs its own look.
  if ([...cur.users].sort().join(",") !== [...d.value.users].sort().join(",")) return reject("team_vm.stale_taint", "the taint changed since you read it; read team_vm.status again")
  if (cur.accepted_by !== null) return { ok: true, state, value: { epoch: cur.epoch, accepted_by: cur.accepted_by, accepted_at: cur.accepted_at }, changed: false }
  const taint = { ...cur, accepted_by: d.value.by, accepted_at: ctx.now }
  return { ok: true, state: { ...state, taint, updated_at: ctx.now }, value: { epoch: cur.epoch, accepted_by: d.value.by, accepted_at: ctx.now } }
}

export const reduceRebuildRequested = (state: TeamVmState, params: unknown, ctx: ReduceContext): ReduceResult<TeamVmState> => {
  if (!ownSystem(ctx)) return reject("auth.forbidden", "internal op")
  const d = decode<typeof TeamVmRebuildRequestedParams.Type>(TeamVmRebuildRequestedParams, params)
  if (!d.ok) return d
  if (state.vm === null || d.value.epoch !== state.epoch) return reject("team_vm.stale_epoch", "the team VM is not at this epoch")
  // A create already pending (a missing VM) makes the next VM on its own.
  if (state.pending?.action === "create") return reject("team_vm.stale_epoch", "a new team VM is already being created")
  if ((state.retired ?? []).length >= MAX_RETIRED) return reject("team_vm.retired_full", `delete a retired team VM first (at most ${MAX_RETIRED} are kept)`)
  const retired: TeamVmRetired = { vm: state.vm, slug: state.slug, epoch: state.epoch, state: "pausing", at: ctx.now, by: d.value.by, tainted_by: currentTaint(state)?.users ?? [], pause_attempts: 0, pause_retry_at: ctx.now }
  const next: TeamVmState = {
    ...state,
    vm: null,
    slug: null,
    vm_install: null,
    status: "provisioning",
    taint: null,
    retired: [...(state.retired ?? []), retired],
    pending: { action: "create", attempts: 0, retry_at: ctx.now, requested_by: d.value.by },
    updated_at: ctx.now
  }
  return { ok: true, state: next, value: { retired: retired.vm, epoch: state.epoch } }
}

export const reduceRetired = (state: TeamVmState, op: "team_vm.retired_paused" | "team_vm.retired_deleted" | "team_vm.retired_pause_failed", params: unknown, ctx: ReduceContext): ReduceResult<TeamVmState> => {
  if (!ownSystem(ctx)) return reject("auth.forbidden", "internal op")
  const d = decode<typeof TeamVmRetiredParams.Type>(TeamVmRetiredParams, params)
  if (!d.ok) return d
  const list = state.retired ?? []
  const row = list.find((r) => r.vm === d.value.vm)
  if (!row) return op === "team_vm.retired_deleted" ? reject("selector.not_found", "no retired VM with this id") : same(state)
  if (op === "team_vm.retired_pause_failed") {
    if (!retireDue(row)) return same(state)
    const attempts = (row.pause_attempts ?? 0) + 1
    const retiredList = list.map((r) => (r.vm === row.vm ? { ...r, pause_attempts: attempts, pause_retry_at: ctx.now + pauseDelayMs(attempts) } : r))
    return { ok: true, state: { ...state, retired: retiredList, updated_at: ctx.now }, value: { vm: row.vm, attempts } }
  }
  if (op === "team_vm.retired_paused") {
    if (!retireDue(row)) return same(state)
    return { ok: true, state: { ...state, retired: list.map((r) => (r.vm === row.vm ? { ...r, state: "paused" as const, fenced: true } : r)), updated_at: ctx.now }, value: { vm: row.vm, state: "paused" } }
  }
  return { ok: true, state: { ...state, retired: list.filter((r) => r.vm !== row.vm), updated_at: ctx.now }, value: { vm: row.vm, deleted: true } }
}

/** The status read's taint and retired fields. */
export const taintView = (s: TeamVmState) => ({
  taint: currentTaint(s),
  retired: (s.retired ?? []).map((r) => ({ vm: r.vm, epoch: r.epoch, state: r.state, at: r.at, by: r.by, tainted_by: r.tainted_by }))
})
