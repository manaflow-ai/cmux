import { Schema } from "effect"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"
import { TeamId } from "./schemas.ts"

/**
 * The team VM (plans/cmux-next/team-vm-plan.md S2, spec/team-vm.md). TeamVmDO, one per team,
 * is the single writer of the team's VM record: the provider VM id, the epoch that fences a
 * replaced VM, the last observed state and the wake leases. The VM is created lazily on the
 * first `team_vm.ensure_awake`; the provider call runs in the DO outside the reducer, and its
 * outcome is committed as the internal op `team_vm.driver_result`.
 */

export const TeamVmStatus = Schema.Literals(["none", "provisioning", "starting", "running", "paused", "failed"]).annotate({
  identifier: "TeamVmStatus",
  description: "Last observed state of the team VM. `none`: never created. `failed`: the last provider call failed for good; the next ensure_awake retries."
})

export const TeamVmLeaseId = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(64)).annotate({ identifier: "TeamVmLeaseId" })

export const TeamVmError = Schema.Struct({ code: Schema.String, message: Schema.String, at: Schema.Int }).annotate({ identifier: "TeamVmError" })

export const TeamVmView = Schema.Struct({
  team: TeamId,
  status: TeamVmStatus,
  /** Provider VM id; null until the first create succeeds. */
  vm: Schema.NullOr(Schema.String),
  /** Increments on each new VM for the team (create, later restore). Writers on an older epoch are refused. */
  epoch: Schema.Int,
  /** Active wake leases (expired ones are not listed). */
  leases: Schema.Array(Schema.Struct({ lease: TeamVmLeaseId, holder: Schema.String, reason: Schema.String, expires_at: Schema.Int })),
  last_error: Schema.NullOr(TeamVmError),
  updated_at: Schema.Int
}).annotate({ identifier: "TeamVmView" })

export const TeamVmStatusRead = def({
  name: "team_vm.status",
  owner: "cloud:TeamVmDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({}),
  result: TeamVmView,
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "Show the team VM: its state, epoch and active wake leases.",
  cli: { path: "team vm status", visible: true },
  mcp: { expose: "default", group: "team" }
})

export const TeamVmEnsureAwake = def({
  name: "team_vm.ensure_awake",
  owner: "cloud:TeamVmDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({
    /** Why the caller needs the VM (shown in status and audit), for example `ssh`, `tasks`, `mail`. */
    reason: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(40)),
    /** Lease length; the VM may pause when no lease is active. Default 600 s. */
    lease_seconds: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 30, maximum: 3600 })))
  }),
  result: Schema.Struct({ lease: TeamVmLeaseId, expires_at: Schema.Int, status: TeamVmStatus, vm: Schema.NullOr(Schema.String), epoch: Schema.Int }),
  errors: [...mutationErrors, "team_vm.not_configured", "team_vm.plan_gate_missing", "team_vm.provider_failed", "team_vm.provider_refused", "team_vm.slug_conflict", "owner.unreachable"],
  docs: "Create the team VM if it does not exist, resume it if it is paused, and hold it awake with a lease. The same holder and reason renew one lease. When the provider call fails for good, the op answers with that error (the lease stays until it expires).",
  cli: { path: "team vm wake", visible: true },
  mcp: { expose: "opt_in", group: "team" }
})

export const TeamVmLeaseRelease = def({
  name: "team_vm.lease.release",
  owner: "cloud:TeamVmDO",
  class: "mutation",
  risk: "mutate-own",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({ lease: TeamVmLeaseId }),
  result: Schema.Struct({ lease: TeamVmLeaseId, released: Schema.Boolean }),
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Release a wake lease you hold, so the team VM may pause when no other lease is active.",
  cli: { path: "team vm release", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const teamVmOps = [TeamVmStatusRead, TeamVmEnsureAwake, TeamVmLeaseRelease] as const satisfies readonly CloudOpDef[]

export const TeamVmDriverResultParams = Schema.Struct({
  /** Which provider call finished. */
  action: Schema.Literals(["create", "start"]),
  /** The record's epoch when the call started; a result for another epoch changes nothing. */
  epoch: Schema.Int,
  ok: Schema.Boolean,
  /** create: the new VM's provider id. */
  vm: Schema.optionalKey(Schema.String),
  /** create: the provider slug, which makes the create idempotent. */
  slug: Schema.optionalKey(Schema.String),
  /** Observed provider state after the call. */
  observed: Schema.optionalKey(Schema.Literals(["starting", "running", "pausing", "paused", "stopped"])),
  error: Schema.optionalKey(Schema.Struct({ code: Schema.String, message: Schema.String })),
  /** Final failure: the DO stops retrying until the next ensure_awake. */
  final: Schema.optionalKey(Schema.Boolean)
})

export const TeamVmLeasesExpireParams = Schema.Struct({ now: Schema.Int })

const internal = (name: string, params: Schema.Top, docs: string): CloudOpDef =>
  ({
    name,
    owner: "cloud:TeamVmDO",
    class: "mutation",
    risk: "mutate-own",
    target: "team",
    principals: ["system"],
    params,
    result: Schema.Unknown,
    errors: [],
    docs,
    cli: { path: "", visible: false },
    mcp: { expose: "never", group: "internal" }
  }) as CloudOpDef

/** Ops only TeamVmDO itself submits (after a provider call, from its alarm). Not exported to the catalog. */
export const teamVmInternalOps: ReadonlyArray<CloudOpDef> = [
  internal("team_vm.driver_result", TeamVmDriverResultParams, "Internal: a provider call (create or start) finished."),
  internal("team_vm.leases_expire", TeamVmLeasesExpireParams, "Internal: drop wake leases that expired before `now`.")
]
