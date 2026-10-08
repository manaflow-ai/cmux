import { Schema } from "effect"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"
import { InstallId, TeamId } from "./schemas.ts"

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

/**
 * A removed member held a team SSH certificate while this VM existed (cx-q4f3). Members are root on
 * the VM (sudo, docker), so nothing proves the VM clean: until an owner or admin accepts the risk
 * or rebuilds, only owners and admins get new certificates and the VM's install cannot bind again.
 */
export const TeamVmTaint = Schema.Struct({
  epoch: Schema.Int,
  /** When the first removal tainted this epoch. */
  at: Schema.Int,
  /** The removed members (user ids). */
  users: Schema.Array(Schema.String),
  accepted_by: Schema.NullOr(Schema.String),
  accepted_at: Schema.NullOr(Schema.Int)
}).annotate({ identifier: "TeamVmTaint" })

/** A VM a rebuild replaced: paused and kept (its data can be copied off) until an owner deletes it. */
export const TeamVmRetired = Schema.Struct({
  vm: Schema.String,
  epoch: Schema.Int,
  /** `pausing` until the provider confirmed the pause. */
  state: Schema.Literals(["pausing", "paused"]),
  at: Schema.Int,
  /** The owner or admin who rebuilt. */
  by: Schema.String,
  /** The removed members whose taint led to the rebuild (empty for a plain rebuild). */
  tainted_by: Schema.Array(Schema.String)
}).annotate({ identifier: "TeamVmRetired" })

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
  updated_at: Schema.Int,
  /** Set while the current epoch is tainted by a member removal; null otherwise. */
  taint: Schema.NullOr(TeamVmTaint),
  /** VMs replaced by a rebuild that an owner has not deleted yet. */
  retired: Schema.Array(TeamVmRetired)
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

export const JournalStreamName = Schema.Literals(["tasks", "mail", "memory", "files"]).annotate({ identifier: "TeamJournalStream" })
const Seq = Schema.Int.check(Schema.isGreaterThanOrEqualTo(1))
const JournalAckSchema = Schema.Struct({ stream: JournalStreamName, first_seq: Seq, last_seq: Seq, epoch: Schema.Int, high_water: Schema.Int, replayed: Schema.Boolean })
const journalDocs = " Only the team VM's own install for the current epoch may call it (plans/cmux-next/team-vm-plan.md 3b)."

export const TeamVmJournalAppend = def({
  name: "team_vm.journal.append",
  owner: "cloud:TeamVmDO",
  class: "mutation",
  risk: "mutate-own",
  target: "team",
  principals: ["install"],
  params: Schema.Struct({
    stream: JournalStreamName,
    epoch: Schema.Int,
    first_seq: Seq,
    last_seq: Seq,
    /** The entry's bytes, base64 (at most 1 MiB decoded). */
    bytes: Schema.String,
    /** Lowercase hex SHA-256 of the decoded bytes; checked by the owner. */
    sha256: Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/))
  }),
  result: JournalAckSchema,
  errors: [...mutationErrors, "journal.gap", "journal.conflict", "journal.stale_epoch", "journal.too_large", "journal.full", "team_vm.not_bound"],
  docs: "Append one seq range (at most 100,000 seqs, 1 MiB) to a team journal stream; returns after the write is durable. A replay of the same range returns the stored acknowledgement. A writer whose reply was lost and whose epoch has since moved gets journal.stale_epoch even though its row is stored." + journalDocs,
  cli: { path: "team journal append", visible: false },
  mcp: { expose: "never", group: "team" }
})

export const TeamVmJournalHighWater = def({
  name: "team_vm.journal.high_water",
  owner: "cloud:TeamVmDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["install"],
  params: Schema.Struct({ stream: JournalStreamName }),
  result: Schema.Struct({ stream: JournalStreamName, high_water: Schema.Int, epoch: Schema.Int }),
  errors: ["auth.unauthenticated", "auth.forbidden", "team_vm.not_bound"],
  docs: "The last seq a team journal stream holds." + journalDocs,
  cli: { path: "team journal high-water", visible: false },
  mcp: { expose: "never", group: "team" }
})

export const TeamVmJournalRead = def({
  name: "team_vm.journal.read",
  owner: "cloud:TeamVmDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["install"],
  params: Schema.Struct({ stream: JournalStreamName, from_seq: Seq }),
  result: Schema.Struct({
    entries: Schema.Array(Schema.Struct({ first_seq: Seq, last_seq: Seq, epoch: Schema.Int, sha256: Schema.String, bytes: Schema.String })),
    high_water: Schema.Int,
    more: Schema.Boolean
  }),
  errors: ["auth.unauthenticated", "auth.forbidden", "team_vm.not_bound"],
  docs: "Whole journal entries from a seq on, for restore (up to about 4 MiB per call; `more` asks for the next call)." + journalDocs,
  cli: { path: "team journal read", visible: false },
  mcp: { expose: "never", group: "team" }
})

const adminErrors = [...mutationErrors, "team_vm.not_tainted", "team_vm.stale_epoch", "selector.not_found", "team_vm.not_configured", "team_vm.plan_gate_missing", "team_vm.in_use", "team_vm.not_in_ledger", "owner.unreachable"] as const

export const TeamVmTaintAccept = def({
  name: "team_vm.taint.accept",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "destructive",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({ epoch: Schema.Int }),
  result: Schema.Struct({ epoch: Schema.Int, accepted_by: Schema.String, accepted_at: Schema.Int }),
  errors: [...adminErrors],
  docs: "Accept the risk of a team VM tainted by a member removal and keep using it: members get certificates again and the VM's install may bind. Owners and admins only, in a person's session; names the tainted epoch; audited.",
  cli: { path: "team vm taint accept", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const TeamVmRebuild = def({
  name: "team_vm.rebuild",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "destructive",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({ epoch: Schema.Int }),
  result: Schema.Struct({ retired: Schema.String, epoch: Schema.Int }),
  errors: [...adminErrors],
  docs: "Replace the team VM (epoch) with a new VM from the base snapshot at the next epoch. The old VM is paused and kept, its install revoked and its logins refused, until an owner deletes it with team_vm.retired.delete (copy its files off first). Owners and admins only, in a person's session; audited.",
  cli: { path: "team vm rebuild", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const TeamVmRetiredDelete = def({
  name: "team_vm.retired.delete",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "destructive",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({ vm: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(128)) }),
  result: Schema.Struct({ vm: Schema.String, deleted: Schema.Boolean }),
  errors: [...adminErrors],
  docs: "Delete a VM that a rebuild replaced (team_vm.status `retired`), by its exact id. Its files are gone for good. Owners and admins only, in a person's session; audited.",
  cli: { path: "team vm retired delete", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const teamVmAdminOps = [TeamVmTaintAccept, TeamVmRebuild, TeamVmRetiredDelete] as const satisfies readonly CloudOpDef[]

export const teamVmOps = [TeamVmStatusRead, TeamVmEnsureAwake, TeamVmLeaseRelease, TeamVmJournalAppend, TeamVmJournalHighWater, TeamVmJournalRead, ...teamVmAdminOps] as const satisfies readonly CloudOpDef[]

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

/** The install of the VM's own `cmux` (after bind) for one epoch; only that install may append to the journal. */
export const TeamVmBindInstallParams = Schema.Struct({ install: InstallId, epoch: Schema.Int, vm: Schema.optionalKey(Schema.String) })

export const TeamVmMemberRemovedParams = Schema.Struct({
  user: Schema.String,
  /** The removal time. */
  at: Schema.Int,
  /** The latest `valid_before` of any team SSH certificate the member got (ms). */
  cert_valid_before: Schema.Int
})
export const TeamVmTaintAcceptedParams = Schema.Struct({ epoch: Schema.Int, by: Schema.String })
export const TeamVmRebuildRequestedParams = Schema.Struct({ epoch: Schema.Int, by: Schema.String })
export const TeamVmRetiredParams = Schema.Struct({ vm: Schema.String })

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
  internal("team_vm.leases_expire", TeamVmLeasesExpireParams, "Internal: drop wake leases that expired before `now`."),
  internal("team_vm.bind_install", TeamVmBindInstallParams, "Internal: the VM's own install for the current epoch (journal writer)."),
  internal("team_vm.member_removed", TeamVmMemberRemovedParams, "Internal: the team's TeamDO removed a member who held a team SSH certificate (taints the current VM when that certificate outlived its creation)."),
  internal("team_vm.taint_accepted", TeamVmTaintAcceptedParams, "Internal: an owner or admin accepted the taint of this epoch (checked and audited by TeamDO)."),
  internal("team_vm.rebuild_requested", TeamVmRebuildRequestedParams, "Internal: an owner or admin asked for a new VM at the next epoch (checked and audited by TeamDO)."),
  internal("team_vm.retired_paused", TeamVmRetiredParams, "Internal: the provider paused a retired VM."),
  internal("team_vm.retired_deleted", TeamVmRetiredParams, "Internal: an owner deleted a retired VM.")
]
