import type { Domain, ReduceResult } from "@cmux/ownership"
import { TeamVmBindInstallParams, TeamVmDriverResultParams, TeamVmEnsureAwake, TeamVmLeaseRelease, TeamVmLeasesExpireParams } from "@cmux/protocol"
import { Schema, Exit } from "effect"
import { admit, decodeParams, reject } from "./common.ts"
import { grantClasses } from "../home-admit.ts"

export type TeamVmStatus = "none" | "provisioning" | "starting" | "running" | "paused" | "failed"
export type ProviderState = "starting" | "running" | "pausing" | "paused" | "stopped"

export interface TeamVmLease {
  readonly holder: string
  readonly reason: string
  readonly expires_at: number
}

/** A provider call the DO still has to run. Set by ensure_awake, cleared by its driver_result. */
export interface TeamVmPending {
  readonly action: "create" | "start"
  /** Failed attempts so far. */
  readonly attempts: number
  /** When the alarm runs the call if no request path ran it first (crash safety net, then backoff). */
  readonly retry_at: number
}

export interface TeamVmState {
  readonly team: string | null
  readonly status: TeamVmStatus
  readonly vm: string | null
  readonly slug: string | null
  /** Increments with each new VM for the team; 0 before the first. */
  readonly epoch: number
  /** The VM's own install for `epoch` (set at bind); the only journal writer. Cleared when the epoch changes. */
  readonly vm_install?: string | null
  readonly leases: Readonly<Record<string, TeamVmLease>>
  readonly pending: TeamVmPending | null
  readonly last_error: { readonly code: string; readonly message: string; readonly at: number } | null
  readonly updated_at: number
}

/** Default wake lease (spec team-vm.md: idle after about 10 minutes without a lease). */
export const DEFAULT_LEASE_SECONDS = 600
/** A request path normally runs the provider call at once; the alarm picks it up after this if the object died. */
export const PENDING_SAFETY_MS = 30_000
/** Provider attempts before a pending call is given up (the next ensure_awake starts again). */
export const MAX_ATTEMPTS = 5
const MAX_BACKOFF_MS = 5 * 60_000

export const retryDelayMs = (attempts: number) => Math.min(MAX_BACKOFF_MS, 1000 * 2 ** attempts)

const decodeInternal = <T>(schema: Schema.Top, params: unknown): { ok: true; value: T } | ReturnType<typeof reject> => {
  const exit = Schema.decodeUnknownExit(schema as Schema.Codec<T, unknown>)(params ?? {})
  return Exit.isSuccess(exit) ? { ok: true, value: exit.value } : reject("validation.invalid", "invalid params", String(exit.cause))
}

const observedStatus = (o: ProviderState | undefined): TeamVmStatus =>
  o === "running" ? "running" : o === "starting" ? "starting" : o === undefined ? "starting" : "paused"

/**
 * TeamVmDO's reducer (plans/cmux-next/team-vm-plan.md S2). Pure: provider calls run in the DO,
 * which commits their outcome as `team_vm.driver_result`. The record is the single source of the
 * team's VM id and epoch; `status` is the last observed provider state, so ensure_awake always
 * asks the provider to start an existing VM (the provider may have paused it on idle).
 */
export const teamVmDomain: Domain<TeamVmState> = {
  initial: () => ({ team: null, status: "none", vm: null, slug: null, epoch: 0, leases: {}, pending: null, last_error: null, updated_at: 0 }),

  authorize: (state, op, _params, principal) => {
    if (principal.kind === "system") return admit("cloud:TeamVmDO", op, principal, () => undefined, Date.now())
    if (!principal.team) return { code: "auth.forbidden", message: "needs a team" }
    if (state.team !== null && state.team !== principal.team) return { code: "auth.forbidden", message: "not this team's VM" }
    return admit("cloud:TeamVmDO", op, principal, grantClasses, Date.now())
  },

  reduce: (state, op, params, ctx): ReduceResult<TeamVmState> => {
    const p = ctx.principal
    switch (op) {
      case "team_vm.ensure_awake": {
        const d = decodeParams<typeof TeamVmEnsureAwake.params.Type>(TeamVmEnsureAwake, params)
        if (!d.ok) return d
        // One lease per holder and reason: a caller that wakes the VM often renews it instead of adding leases.
        const until = ctx.now + (d.value.lease_seconds ?? DEFAULT_LEASE_SECONDS) * 1000
        const held = Object.entries(state.leases).find(([, l]) => l.holder === p.identity && l.reason === d.value.reason && l.expires_at > ctx.now)
        const lease = held ? held[0] : ctx.newId("lease")
        const expires_at = held ? Math.max(held[1].expires_at, until) : until
        const pending: TeamVmPending =
          state.pending ?? { action: state.vm === null ? "create" : "start", attempts: 0, retry_at: ctx.now + PENDING_SAFETY_MS }
        const status: TeamVmStatus = state.vm === null ? "provisioning" : state.status === "running" ? "running" : "starting"
        const next: TeamVmState = {
          ...state,
          team: state.team ?? p.team!,
          status,
          pending,
          leases: { ...state.leases, [lease]: { holder: p.identity, reason: d.value.reason, expires_at } },
          updated_at: ctx.now
        }
        return { ok: true, state: next, value: { lease, expires_at, status, vm: state.vm, epoch: state.epoch } }
      }

      case "team_vm.lease.release": {
        const d = decodeParams<typeof TeamVmLeaseRelease.params.Type>(TeamVmLeaseRelease, params)
        if (!d.ok) return d
        const held = state.leases[d.value.lease]
        if (!held) return reject("selector.not_found", "no such lease (it may have expired)")
        if (held.holder !== p.identity) return reject("auth.forbidden", "only the holder releases a lease")
        const { [d.value.lease]: _gone, ...leases } = state.leases
        return { ok: true, state: { ...state, leases, updated_at: ctx.now }, value: { lease: d.value.lease, released: true } }
      }

      case "team_vm.leases_expire": {
        const d = decodeInternal<typeof TeamVmLeasesExpireParams.Type>(TeamVmLeasesExpireParams, params)
        if (!d.ok) return d
        const leases = Object.fromEntries(Object.entries(state.leases).filter(([, l]) => l.expires_at > d.value.now))
        if (Object.keys(leases).length === Object.keys(state.leases).length) return { ok: true, state, value: { expired: 0 }, changed: false }
        return { ok: true, state: { ...state, leases, updated_at: ctx.now }, value: { expired: Object.keys(state.leases).length - Object.keys(leases).length } }
      }

      case "team_vm.bind_install": {
        const d = decodeInternal<typeof TeamVmBindInstallParams.Type>(TeamVmBindInstallParams, params)
        if (!d.ok) return d
        // Only the current VM may bind, and only once per epoch (a second install for the same epoch is refused).
        if (state.vm === null || d.value.epoch !== state.epoch) return reject("team_vm.stale_epoch", "bind is for another epoch")
        if (state.vm_install && state.vm_install !== d.value.install) return reject("team_vm.already_bound", "this epoch's VM install is already bound")
        if (state.vm_install === d.value.install) return { ok: true, state, value: { install: d.value.install, epoch: state.epoch }, changed: false }
        return { ok: true, state: { ...state, vm_install: d.value.install, updated_at: ctx.now }, value: { install: d.value.install, epoch: state.epoch } }
      }

      case "team_vm.driver_result": {
        const d = decodeInternal<typeof TeamVmDriverResultParams.Type>(TeamVmDriverResultParams, params)
        if (!d.ok) return d
        const r = d.value
        // A result for a call that is no longer pending (a duplicate, superseded, or from another epoch) changes nothing.
        if (!state.pending || state.pending.action !== r.action || r.epoch !== state.epoch) return { ok: true, state, value: { applied: false }, changed: false }
        // The VM was deleted outside cmux: forget it and create a new one under the next epoch.
        // (Data recovery onto the new VM is the restore slice, S6/S14.)
        if (!r.ok && r.action === "start" && r.error?.code === "team_vm.vm_missing") {
          const next: TeamVmState = {
            ...state,
            vm: null,
            slug: null,
            vm_install: null,
            status: "provisioning",
            pending: { action: "create", attempts: 0, retry_at: ctx.now + PENDING_SAFETY_MS },
            last_error: { code: "team_vm.vm_missing", message: r.error.message, at: ctx.now },
            updated_at: ctx.now
          }
          return { ok: true, state: next, value: { applied: true, replaced: true } }
        }
        if (!r.ok) {
          const attempts = state.pending.attempts + 1
          const error = { code: r.error?.code ?? "team_vm.provider_failed", message: r.error?.message ?? "provider call failed", at: ctx.now }
          const final = r.final === true || attempts >= MAX_ATTEMPTS
          const next: TeamVmState = final
            ? { ...state, pending: null, status: "failed", last_error: error, updated_at: ctx.now }
            : { ...state, pending: { ...state.pending, attempts, retry_at: ctx.now + retryDelayMs(attempts) }, last_error: error, updated_at: ctx.now }
          return { ok: true, state: next, value: { applied: true, final } }
        }
        if (r.action === "create") {
          // A malformed success is a final failure, never a reject: a reject would leave the call due and refire the alarm.
          if (!r.vm || !r.slug) {
            const error = { code: "team_vm.provider_refused", message: "create answered without a VM id", at: ctx.now }
            return { ok: true, state: { ...state, pending: null, status: "failed", last_error: error, updated_at: ctx.now }, value: { applied: true, final: true } }
          }
          // The create also boots the VM; one more start call confirms it is running.
          const next: TeamVmState = {
            ...state,
            vm: r.vm,
            slug: r.slug,
            epoch: state.epoch + 1,
            vm_install: null,
            status: observedStatus(r.observed),
            pending: r.observed === "running" ? null : { action: "start", attempts: 0, retry_at: ctx.now + PENDING_SAFETY_MS },
            last_error: null,
            updated_at: ctx.now
          }
          return { ok: true, state: next, value: { applied: true, vm: r.vm, epoch: next.epoch } }
        }
        return { ok: true, state: { ...state, status: observedStatus(r.observed), pending: null, last_error: null, updated_at: ctx.now }, value: { applied: true } }
      }

      default:
        return reject("validation.invalid", `unknown op ${op}`)
    }
  }
}

/** The DO's next alarm for its own work: the earliest lease expiry or pending provider retry. */
export const teamVmWakeAt = (state: TeamVmState): number | null => {
  const times = Object.values(state.leases).map((l) => l.expires_at)
  if (state.pending) times.push(state.pending.retry_at)
  return times.length ? Math.min(...times) : null
}

/** The provider slug of the team's VM for an epoch (unique per provider account, so a create is idempotent). */
export const teamVmSlug = (prefix: string, team: string, epoch: number) => `${prefix}${team.replace(/_/g, "-")}-e${epoch}`
