import { Schema } from "effect"
import { def, mutationErrors } from "./op-def.ts"
import { HostId, Revision, TeamId, UserId } from "./schemas.ts"
import { CloudVmNetwork } from "./cloud-network.ts"
import { ServerNetworkProof } from "./server-network.ts"
import { isPattern } from "./json-checks.ts"

/**
 * cmux-next Cloud machines (plans/cmux-next/cloud-client-contract.md 1.2, 1.3 and 1.7;
 * state-placement.md 5). CloudDO, one per team, is the single writer of the team's machine and
 * snapshot registry, the provider-call ledger and the plan checks. Revisions are the CloudDO
 * stream sequence of an entity's last change, so entity and list revisions compare. Each op
 * declares every error code it may answer; a client treats any other code as a protocol break.
 * The shared vectors are backend/catalog/cloud-vectors.json.
 */

export const MachineId = Schema.String.check(isPattern(/^vm_[a-z0-9]{20}$/)).annotate({ identifier: "MachineId", description: "A Cloud machine." })
export const SnapshotId = Schema.String.check(isPattern(/^snap_[a-z0-9]{20}$/)).annotate({ identifier: "SnapshotId", description: "A Cloud machine snapshot." })
const PlanId = Schema.String.check(isPattern(/^[a-z0-9][a-z0-9_-]{0,63}$/))
const ImageId = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(128))
export const MachineName = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(80))
const Millis = Schema.Int

export const CloudMachineStatus = Schema.Literals(["provisioning", "starting", "running", "pausing", "paused", "deleting", "failed"]).annotate({ identifier: "CloudMachineStatus" })

export const CloudMachineSize = Schema.Struct({
  cpu: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 64 }))),
  memory_mb: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 512, maximum: 262144 }))),
  disk_mb: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 1024, maximum: 1048576 })))
}).annotate({ identifier: "CloudMachineSize", description: "A machine size. The plan decides which sizes are allowed (cloud.size.locked)." })

export const CloudDeleteReason = Schema.Literals(["failed_create", "never_used", "unused", "requested"]).annotate({ identifier: "CloudDeleteReason" })

export const CloudRetentionNotice = Schema.Struct({
  kind: Schema.Literals(["heads_up", "last_note"]),
  /** When the platform recorded it (ms); the app remembers a dismissal per machine and `at`. */
  at: Millis,
  delete_at: Millis
}).annotate({ identifier: "CloudRetentionNotice" })

/**
 * Text in an origin: no control characters (C0, DEL, C1) and no invisible format characters (zero-width, bidi marks,
 * embeddings, overrides and isolates, the byte order mark). An origin is shown in machine lists, audit rows and logs
 * as given, and must read as what it is. The platform's POST /v1/machines `origin` (MachineOrigin) is the same.
 */
const OriginText = (max: number) =>
  Schema.String.check(
    Schema.isMinLength(1),
    Schema.isMaxLength(max),
    // oxlint-disable-next-line no-control-regex -- refusing control characters is the point.
    isPattern(/^[^\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]*$/)
  )

/**
 * Who started a machine, as its create said: a workflow run, a lane, an agent or a person, with a label to show and
 * where to look (`url`, https only). Bounded free text; the platform stores it as given and never acts on it.
 */
export const CloudMachineOrigin = Schema.Struct({
  kind: Schema.optionalKey(Schema.Literals(["workflow", "lane", "agent", "person"])),
  label: OriginText(200),
  url: Schema.optionalKey(OriginText(500).check(isPattern(/^https:\/\/[^\s/?#@]+(?:[/?#]\S*)?$/))),
  run: Schema.optionalKey(OriginText(200)),
  workflow: Schema.optionalKey(OriginText(200)),
  lane: Schema.optionalKey(OriginText(200))
}).annotate({ identifier: "CloudMachineOrigin" })

export const CloudMachine = Schema.Struct({
  id: MachineId,
  team: TeamId,
  creator: UserId,
  name: Schema.NullOr(MachineName),
  size: CloudMachineSize,
  status: CloudMachineStatus,
  image: Schema.Struct({ id: ImageId, daemon_version: Schema.NullOr(Schema.String) }),
  /** The overlay host id; null until the machine is bound. */
  host: Schema.NullOr(HostId),
  /** Imported from cmux Cloud classic and not upgraded yet. */
  classic: Schema.Boolean,
  created_at: Millis,
  last_active_at: Schema.NullOr(Millis),
  idle_policy: Schema.Struct({ idle_seconds: Schema.Int }),
  error: Schema.NullOr(Schema.Struct({ code: Schema.String, message: Schema.String, at: Millis })),
  /**
   * Why cmux paused a machine by itself, for the app to show: idle (its reports showed it idle past its
   * idle policy or 24 h), no_report (no report for 24 h after its last start or bind: the cost
   * backstop), provider_stopped / provider_paused (the VM was found stopped or paused, e.g. a poweroff
   * inside). Absent or null after a person's pause or a start.
   */
  pause_reason: Schema.optionalKey(Schema.NullOr(Schema.Literals(["idle", "no_report", "provider_stopped", "provider_paused"]))),
  /**
   * What the machine costs while it runs, in US dollars an hour: the provider's list price for its size
   * (cmux sets it; clients keep no rate table). For display only, not a bill. Absent or null when the size
   * has no rate.
   */
  hourly_rate_usd: Schema.optionalKey(Schema.NullOr(Schema.Number.check(Schema.isGreaterThanOrEqualTo(0)))),
  /**
   * What the machine costs while it is paused, in US dollars an hour: the provider's list price for keeping
   * its disk and memory (cmux sets it; clients keep no rate table). Clients show it by the month ("about $X
   * a month while paused"), since an hour of it is under a cent. For display only, not a bill. Absent or
   * null when the size has no paused rate.
   */
  paused_hourly_rate_usd: Schema.optionalKey(Schema.NullOr(Schema.Number.check(Schema.isGreaterThanOrEqualTo(0)))),
  /** When the machine last started running (a start or a bind); null unless it is running. Clients show rate x time running as "about $X so far". */
  running_since: Schema.optionalKey(Schema.NullOr(Millis)),
  /**
   * The machine serves link service `desktop` (its agent display as cmux.rd/1): a Native machine whose daemon
   * advertises CLOUD_DESKTOP_CAPABILITY in its bind or status report. Clients offer Open Desktop's `rd` viewer on
   * it; the link_token mint stays the authority (the creator only). Absent from an older server: no desktop.
   */
  desktop: Schema.optionalKey(Schema.Boolean),
  /**
   * Automatic cleanup (cmux-platform Retention.ts). evict_at: when the platform deletes this machine by itself (ms),
   * null when nothing will (kept, running, a paid plan's worked-in machine, or cleanup off). delete_reason: why
   * (failed_create and never_used go silently; unused is a worked-in machine on a plan that deletes them, after one
   * heads-up; requested is a person's archive and delete). Absent from an older server: no date.
   */
  evict_at: Schema.optionalKey(Schema.NullOr(Millis)),
  delete_reason: Schema.optionalKey(Schema.NullOr(CloudDeleteReason)),
  /** A person pinned it (cloud.machine.keep): never deleted automatically. Absent: false. */
  keep: Schema.optionalKey(Schema.Boolean),
  /**
   * The one in-app notice before an `unused` machine's delete: the heads-up (heads_up_days before) or the last note
   * (last_note_days before). Each comes once per deadline; a use, a keep or a new deadline clears it.
   */
  notice: Schema.optionalKey(Schema.NullOr(CloudRetentionNotice)),
  /**
   * The team's spending cap paused this machine (cmux-platform SpendCap.ts); pause_reason stays null for it. A start
   * clears it. Absent otherwise, and from a server without the cap.
   */
  paused_by: Schema.optionalKey(Schema.Literal("spend_cap")),
  /**
   * The team reached its spending cap: this running machine pauses at this time unless an admin raises the cap first
   * (the 15-minute warning). A pause, a start or a raised cap clears it.
   */
  spend_cap_pause_at: Schema.optionalKey(Millis),
  /** Who started it, when its create said (cloud.machine.create `origin`). Absent: its create gave none. */
  origin: Schema.optionalKey(CloudMachineOrigin),
  /** When the platform deletes it (ms): its create's `ttl_seconds` after its create. Absent: no ttl. */
  expires_at: Schema.optionalKey(Millis),
  revision: Revision
}).annotate({ identifier: "CloudMachine" })

export const CloudSnapshot = Schema.Struct({
  id: SnapshotId,
  machine: MachineId,
  name: Schema.NullOr(MachineName),
  size_mb: Schema.Int,
  status: Schema.Literals(["creating", "ready", "deleting", "failed"]),
  created_at: Millis,
  /**
   * The archive the platform took of a machine before deleting it (automatic cleanup or archive and delete), kept
   * until `until` (ms) and then deleted. cloud.snapshot.restore makes a new machine from it. Absent: not an archive.
   */
  archive_of: Schema.optionalKey(Schema.NullOr(Schema.Struct({ machine: MachineId, name: Schema.NullOr(MachineName), until: Millis }))),
  revision: Revision
}).annotate({ identifier: "CloudSnapshot" })

/** A team's own cleanup numbers (cloud.retention.set), each within its plan's limit. */
export const CloudRetentionOverrides = Schema.Struct({
  failed_create_hours: Schema.optionalKey(Schema.Int),
  never_used_hours: Schema.optionalKey(Schema.Int),
  idle_pause_minutes: Schema.optionalKey(Schema.Int),
  worked_in_days: Schema.optionalKey(Schema.Int),
  heads_up_days: Schema.optionalKey(Schema.Int),
  last_note_days: Schema.optionalKey(Schema.Int),
  archive_days: Schema.optionalKey(Schema.Int)
}).annotate({ identifier: "CloudRetentionOverrides" })

/**
 * The cleanup in force for the caller's machines: the plan's tier with the team's overrides inside its limits.
 * worked_in_days null: a machine someone worked in is never deleted automatically (paid plans).
 */
export const CloudRetentionSettings = Schema.Struct({
  tier: Schema.String,
  failed_create_hours: Schema.Int,
  never_used_hours: Schema.Int,
  idle_pause_minutes: Schema.Int,
  worked_in_days: Schema.NullOr(Schema.Int),
  heads_up_days: Schema.Int,
  last_note_days: Schema.Int,
  archive_days: Schema.Int
}).annotate({ identifier: "CloudRetentionSettings" })

export const CloudRetention = Schema.Struct({
  /** CLOUD_EVICT: on deletes, warn only stamps dates, off does neither. */
  mode: Schema.Literals(["off", "warn", "on"]),
  settings: Schema.NullOr(CloudRetentionSettings),
  team: CloudRetentionOverrides,
  /** Whether the caller gets the one email heads-up before one of their machines is deleted. */
  email_heads_up: Schema.Boolean
}).annotate({ identifier: "CloudRetention" })

export const CloudPlan = Schema.Struct({
  plan_id: PlanId,
  /** The plan that lifts these limits, for the page's "See plans"; null when there is none. */
  upgrade_plan: Schema.NullOr(PlanId),
  limits: Schema.Struct({
    max_active: Schema.Int,
    max_saved: Schema.Int,
    memory_options_mb: Schema.Array(Schema.Int),
    locked_memory_options_mb: Schema.Array(Schema.Int),
    vm_hours_included: Schema.NullOr(Schema.Number)
  }),
  /**
   * vm_hours_used: null while the VM-hours meter is not wired (unknown, never a made-up 0).
   * vm_hours_used_by_you: the caller's share (machines they created), null while the split is unknown; absent from
   * servers that do not split it (Team plan, per-member budgets).
   */
  usage: Schema.Struct({ active: Schema.Int, saved: Schema.Int, vm_hours_used: Schema.NullOr(Schema.Number), vm_hours_used_by_you: Schema.optionalKey(Schema.NullOr(Schema.Number)), period_end: Millis }),
  /** Automatic machine cleanup (cmux-platform Retention.ts); absent or null from a server without it. */
  retention: Schema.optionalKey(Schema.NullOr(CloudRetention)),
  /**
   * The team's spending cap on Cloud machines (cmux-platform SpendCap.ts `capView`), absent where the cap is off. The
   * last read of the team's spend (state under, near or at_cap; null before the first read; cap_usd null when the
   * team has no cap), when running member machines pause if the team is still at its cap (pause_at, null when none is
   * pending), and when the cap paused them (paused_at, null when it has not).
   */
  spend_cap: Schema.optionalKey(
    Schema.Struct({
      state: Schema.NullOr(Schema.Literals(["under", "near", "at_cap"])),
      spent_usd: Schema.NullOr(Schema.Number),
      cap_usd: Schema.NullOr(Schema.Number),
      period_end: Schema.NullOr(Millis),
      checked_at: Schema.NullOr(Millis),
      pause_at: Schema.NullOr(Millis),
      paused_at: Schema.NullOr(Millis)
    })
  )
}).annotate({ identifier: "CloudPlan" })

/**
 * The caller's kind on one machine, the classic attach answer's `vmKind` (web vmKindForCaller):
 * `owner` for the machine's creator on any team (personal or shared, any size), never an agent token;
 * every other member is `team`. Computed per request, never stored.
 * A client grants owner privileges only on the exact value `owner`.
 */
export const CloudVmKind = Schema.Literals(["owner", "team"])
export type CloudVmKind = typeof CloudVmKind.Type

export const CloudConnectInfo = Schema.Struct({
  machine: MachineId,
  host: HostId,
  /** A restore or re-bind raises it; the link refuses a hello from a lower epoch. */
  epoch: Schema.Int,
  state: CloudMachineStatus,
  /** Native VM membership only; current tunnel, peer policy and serving permissions are separate. */
  network: Schema.optionalKey(CloudVmNetwork),
  peer: Schema.Struct({
    wg_public_key: Schema.String,
    overlay_address: Schema.String,
    vpc_endpoint: Schema.NullOr(Schema.String),
    public_ipv6: Schema.NullOr(Schema.String)
  }),
  /** This install's own Freestyle tunnel into the VM's VPC; null = no tunnel path for this caller. */
  gateway: Schema.NullOr(
    Schema.Struct({ tunnel_id: Schema.String, endpoint: Schema.String, server_public_key: Schema.String, client_address: Schema.String, allowed_ips: Schema.Array(Schema.String) })
  ),
  services: Schema.Array(Schema.Literals(["daemon", "ssh"])),
  daemon: Schema.Struct({ version: Schema.NullOr(Schema.String), capabilities: Schema.Array(Schema.String) }),
  /** The caller's kind on this machine, per request (CloudVmKind). */
  vm_kind: CloudVmKind,
  revision: Revision
}).annotate({ identifier: "CloudConnectInfo" })

export const MachineResult = Schema.Struct({ machine: CloudMachine })
const Deleted = Schema.Struct({ deleted: Schema.Literal(true) })
const MachineParams = Schema.Struct({ machine: MachineId })

/** The Worker's own gates answer these for every op, before the owner sees it. */
const GATES = ["auth.sso_required", "client.too_old", "owner.unreachable"]
const READ = ["auth.forbidden", "auth.unauthenticated", "selector.not_found", "validation.invalid", ...GATES]
const MUTATION = [...mutationErrors, ...GATES]
/** A provider call can fail for now or be cut off; the caller retries the same key after mutation.indeterminate. */
export const PROVIDER = ["cloud.provider.unavailable", "mutation.indeterminate"]
/** Create and delete are limited per team (CLOUD_MUTATION_LIMIT); retryable, retry after a minute. */
export const LIMITED = ["cloud.rate_limited"]
/**
 * A member's start at the team's spending cap (cloud.spend_cap.reached {spent_usd, cap_usd, period_end, pause_at}) or
 * over their own monthly budget (cloud.member_budget.reached {spent_usd, limit_usd}); cmux-platform SpendCap.ts.
 */
export const SPEND_CAP = ["cloud.spend_cap.reached", "cloud.member_budget.reached"]
/**
 * The provider's VM limit for the team, paused machines included (cloud.quota.vm_limit {limit, team_vms, orphans,
 * oldest_vm_age_s, complete}; cmux-platform#1192 Refusals.ts): a final 403 until a machine is deleted. Any op that
 * makes or starts a VM can meet it, the same ops the spending cap refuses.
 */
export const VM_LIMIT = ["cloud.quota.vm_limit"]
export const KEY = " After mutation.indeterminate, retry with the same idempotency key."
/**
 * The G8 approval path (cx-wb5.65, domains/cloud.ts CLOUD_APPROVAL_OPS): a non-agent install
 * never runs these ops itself; the person approves each request in the feed with their own session.
 */
export const APPROVAL = ["approval.pending", "approval.denied", "approval.expired", "approval.too_many_pending"]
export const APPROVAL_DOC =
  " From an install: approval.pending {request, expires_at} (retryable) until the person answers the feed request with their own session; then the same key answers the op's result (replayed: true), approval.denied or approval.expired (ask again with a new key); approval.too_many_pending (retryable) past 5 pending requests per install or 20 per team."
const PERSON = " Agent principals are refused; the client asks a person first."

export const cloudRead = <P extends Schema.Top, R extends Schema.Top>(name: string, params: P, result: R, errors: Array<string>, docs: string, cli: string) =>
  def({ name, owner: "cloud:CloudDO", class: "read", risk: "read", target: "team", principals: ["session", "install"], params, result, errors: [...READ, ...errors], docs, cli: { path: cli, visible: true }, mcp: { expose: "default", group: "cloud" } })

export const cloudMutation = <P extends Schema.Top, R extends Schema.Top>(
  name: string,
  risk: "mutate-own" | "mutate-shared" | "execute" | "money" | "destructive",
  params: P,
  result: R,
  errors: Array<string>,
  docs: string,
  cli: string,
  person = false
) =>
  def({
    name,
    owner: "cloud:CloudDO",
    class: "mutation",
    risk,
    target: "team",
    principals: ["session", "install"],
    params,
    result,
    errors: [...MUTATION, ...errors],
    docs: docs + (person ? PERSON : ""),
    cli: { path: cli, visible: !person },
    mcp: { expose: person ? "never" : "opt_in", group: "cloud" }
  })

export const CloudMachineList = cloudRead(
  "cloud.machine.list",
  Schema.Struct({ cursor: Schema.optionalKey(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(512))), limit: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 100 }))) }),
  Schema.Struct({ machines: Schema.Array(CloudMachine), next_cursor: Schema.NullOr(Schema.String), revision: Revision }),
  [],
  "List the team's Cloud machines one page at a time; no cursor = the first page. `revision` is the team's registry revision when the page was read.",
  "cloud machine list"
)
export const CloudMachineGet = cloudRead("cloud.machine.get", MachineParams, CloudMachine, ["cloud.machine.not_found"], "One Cloud machine.", "cloud machine get")
export const CloudMachineCreate = cloudMutation(
  "cloud.machine.create",
  "money",
  Schema.Struct({
    name: Schema.optionalKey(MachineName),
    size: CloudMachineSize,
    image: Schema.optionalKey(ImageId),
    from_snapshot: Schema.optionalKey(SnapshotId),
    /** Who started it (a workflow run, a lane, an agent, a person): stored on the machine and shown in every list. */
    origin: Schema.optionalKey(CloudMachineOrigin),
    /** Seconds it may live, 5 minutes to 7 days: then the platform deletes it as cloud.machine.delete would. */
    ttl_seconds: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 300, maximum: 604800 })))
  }),
  MachineResult,
  ["cloud.no_snapshot_configured", "cloud.plan.required", "cloud.quota.exceeded", "cloud.size.locked", "cloud.snapshot.not_found", ...SPEND_CAP, ...VM_LIMIT, ...PROVIDER, ...LIMITED, ...APPROVAL],
  "Create a machine (status provisioning; a cloud.machine.upsert follows when it is bound). The plan is checked before any provider call: cloud.plan.required, cloud.quota.exceeded {limit, used, resource, free_up} (at the machines cap, free_up names the oldest machine a person can delete to make room: {machine, name, reason: test|failed_create|never_used|requested}, or null), cloud.size.locked. A same-key retry never makes a second machine. origin {kind?, label, url?, run?, workflow?, lane?} says who started it and ttl_seconds (300 to 604800) when the platform deletes it (expires_at on the machine)." + KEY + APPROVAL_DOC,
  "cloud machine create",
  true
)
export const CloudMachineRename = cloudMutation("cloud.machine.rename", "mutate-shared", Schema.Struct({ machine: MachineId, name: MachineName }), MachineResult, ["cloud.machine.not_found"], "Rename a machine.", "cloud machine rename")
export const CloudMachineStart = cloudMutation("cloud.machine.start", "mutate-shared", MachineParams, MachineResult, ["cloud.machine.not_found", "cloud.machine.not_paused", "cloud.machine.not_bound", "cloud.quota.exceeded", "cloud.plan.required", ...SPEND_CAP, ...VM_LIMIT, ...LIMITED, ...PROVIDER], "Start (resume) a paused machine (a machine that never bound answers cloud.machine.not_bound: delete it): answers status starting; cloud.machine.upsert brings running (or paused again with the error after a final provider failure). It takes an active slot (cloud.quota.exceeded {limit, used, resource, plan}); cloud.machine.not_paused {machine, state} for any other status. A money op: a signed-in person only; limited per team." + KEY, "cloud machine start", true)
export const CloudMachinePause = cloudMutation("cloud.machine.pause", "mutate-shared", MachineParams, MachineResult, ["cloud.machine.not_found", "cloud.machine.not_running", ...LIMITED, ...PROVIDER], "Pause a running machine (memory kept): answers status pausing; cloud.machine.upsert brings paused (or running again with the error). The active slot is freed when it lands; cloud.machine.not_running {machine, state} for any other status. A money op: a signed-in person only; limited per team." + KEY, "cloud machine pause", true)
export const CloudMachineResize = cloudMutation(
  "cloud.machine.resize",
  "money",
  Schema.Struct({ machine: MachineId, size: CloudMachineSize }),
  MachineResult,
  ["cloud.machine.not_found", "cloud.machine.not_running", "cloud.machine.busy", "cloud.size.grow_only", "cloud.size.locked", "cloud.plan.required", ...LIMITED, ...PROVIDER, ...APPROVAL],
  "Grow a machine: vCPU, memory and disk only go up (cloud.size.grow_only {size}); vCPU and memory grow on a running or paused machine (on resume), the disk only on a running one (cloud.machine.not_running {machine, state}); within the plan (cloud.size.locked {plan, ...}). One change at a time (cloud.machine.busy). The answer carries the target size; a final provider failure restores the old size with the error. A money op: a signed-in person only; limited per team." + KEY + APPROVAL_DOC,
  "cloud machine resize",
  true
)
export const CloudMachineDelete = cloudMutation(
  "cloud.machine.delete",
  "destructive",
  MachineParams,
  Deleted,
  ["cloud.machine.not_found", ...PROVIDER, ...LIMITED, ...APPROVAL],
  "Delete a machine and its disk. A provider 404 is success, and the tombstone answers {deleted: true} for 30 days, also to a new key." + KEY + APPROVAL_DOC,
  "cloud machine delete",
  true
)
export const CloudMachineIdlePolicySet = cloudMutation(
  "cloud.machine.idle_policy.set",
  "mutate-shared",
  Schema.Struct({ machine: MachineId, idle_seconds: Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: 604800 })) }),
  MachineResult,
  ["cloud.machine.not_found"],
  "Set this machine's idle policy (ours only; Freestyle's own timer is always off). It applies only with the team policy cloud.idlePause on, from the VM's own activity reports. 0 means no early pause. The 24 h backstop pauses every machine idle for 24 h by its reports, so any value above 24 h acts as 24 h.",
  "cloud machine idle-policy set"
)
/** cloud.machine.keep: pin a machine so nothing deletes it automatically (keep: false unpins it). */
export const CloudMachineKeep = cloudMutation(
  "cloud.machine.keep",
  "mutate-shared",
  Schema.Struct({ machine: MachineId, keep: Schema.Boolean }),
  MachineResult,
  ["cloud.machine.not_found"],
  "Keep a machine: it is never deleted automatically, whatever the plan's retention. keep: false lets the plan's retention apply again. The machine's creator or a team admin only.",
  "cloud machine keep"
)
/**
 * cloud.machine.archive_delete: the one-click "archive and delete" of a paused or failed machine (a paid plan's way
 * to stop paying for a paused machine's disk). The platform archives the disk first (a snapshot with archive_of, kept
 * the plan's archive_days and restorable as a new machine), then deletes the machine once the archive is ready.
 */
export const CloudMachineArchiveDelete = cloudMutation(
  "cloud.machine.archive_delete",
  "destructive",
  MachineParams,
  MachineResult,
  ["cloud.machine.not_found", "cloud.machine.not_paused"],
  "Archive a paused machine's disk, then delete the machine. The archive is a snapshot (archive_of names the machine) kept for the plan's archive days; cloud.snapshot.restore makes a new machine from it. The machine's creator or a team admin only.",
  "cloud machine archive-delete",
  true
)
/**
 * cloud.retention.set: a team admin's overrides of the plan's cleanup numbers (`settings`, null clears them; a
 * non-admin is auth.forbidden), and the caller's own choice of the email heads-up (`email_heads_up`). cloud.plan.get
 * answers both as `retention`.
 */
export const CloudRetentionSet = cloudMutation(
  "cloud.retention.set",
  "mutate-shared",
  Schema.Struct({ settings: Schema.optionalKey(Schema.NullOr(CloudRetentionOverrides)), email_heads_up: Schema.optionalKey(Schema.Boolean) }),
  Schema.Struct({ changed: Schema.Boolean }),
  [],
  "Set this team's cleanup numbers (a team admin; each within the plan's limit, a worked-in window never past the plan's) and whether you get the email heads-up before one of your machines is deleted. cloud.plan.get answers the settings in force as `retention`.",
  "cloud retention set"
)

const AllotmentMicros = Schema.Number.check(Schema.isFinite(), Schema.isGreaterThanOrEqualTo(0))
const AllotmentCount = Schema.Number.check(Schema.isFinite(), Schema.isGreaterThanOrEqualTo(0))
const AllotmentTier = Schema.Literals(["standard", "plus", "max"])
const AllotmentPosition = Schema.Literals(["down", "hold", "up"])
/** What a team's admin set for its allotment; null in the view while nobody has answered a proposal. */
const CloudAllotmentSetting = Schema.Struct({
  commit_micros: AllotmentMicros,
  mode: Schema.Literals(["ask", "auto"]),
  auto_max_micros: Schema.NullOr(AllotmentMicros),
  tiers: Schema.Record(Schema.String, AllotmentTier),
  snoozed_until: Schema.NullOr(Schema.Int),
  changed_at: Schema.Int,
  changed_by: Schema.String
}).annotate({ identifier: "CloudAllotmentSetting" })
/** One member's metered use: this month, and over the last 14 days. */
const CloudAllotmentMember = Schema.Struct({
  member: Schema.String,
  tier: AllotmentTier,
  month_micros: AllotmentMicros,
  usd14_micros: AllotmentMicros,
  active_days14: Schema.Int,
  share_micros: AllotmentMicros,
  rank: AllotmentCount,
  over_share14: Schema.Int,
  plan_limit_ms14: AllotmentCount,
  spare_micros: AllotmentMicros
}).annotate({ identifier: "CloudAllotmentMember" })
const CloudAllotmentReason = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("unused"), members: Schema.Array(Schema.String) }),
  Schema.Struct({ kind: Schema.Literal("over"), member: Schema.String, count: Schema.Int }),
  Schema.Struct({ kind: Schema.Literal("runaway"), member: Schema.String, rate_micros_h: AllotmentMicros }),
  Schema.Struct({ kind: Schema.Literal("tier"), member: Schema.String, to: AllotmentTier, costs_micros: AllotmentMicros })
]).annotate({ identifier: "CloudAllotmentReason" })
const CloudAllotmentAdviceMember = Schema.Struct({
  member: Schema.String,
  minutes: AllotmentCount,
  seat_percent: AllotmentCount,
  active_hours: Schema.Int,
  floor: Schema.Int,
  burst: Schema.Int
}).annotate({ identifier: "CloudAllotmentAdviceMember" })
/**
 * The same use counted in machines and machine-minutes: scale the team's pooled machines up, down or hold. A
 * member's `floor` is the machines they ran at once in the median hour, their `burst` what they reached in 99% of
 * hours; `lendable` machines are held by no floor.
 */
const CloudAllotmentAdvice = Schema.Struct({
  position: AllotmentPosition,
  seats: Schema.Int,
  to_seats: Schema.Int,
  window_hours: Schema.Int,
  floor: Schema.Int,
  burst: Schema.Int,
  peak: Schema.Int,
  lendable: Schema.Int,
  ceiling_hours7: Schema.Int,
  used_minutes: AllotmentCount,
  seat_minutes: AllotmentCount,
  reason: Schema.Union([
    Schema.Struct({ kind: Schema.Literal("ceiling"), hours: Schema.Int, hours7: Schema.Int, peak: Schema.Int, add: Schema.Int }),
    Schema.Struct({ kind: Schema.Literal("spare"), release: Schema.Int, members: Schema.Array(CloudAllotmentAdviceMember) }),
    Schema.Struct({ kind: Schema.Literal("fits") })
  ]),
  summary: Schema.String,
  members: Schema.Array(CloudAllotmentAdviceMember)
}).annotate({ identifier: "CloudAllotmentAdvice" })
/**
 * A team's allotment and what the scheduler proposes for it from metered use (cmux-platform domain/Allotment.ts):
 * scale the pooled monthly commit down, hold it or scale it up, with each member's use. `names` maps the member
 * ids the team directory listed to display names (empty when the directory could not be read).
 */
export const CloudAllotmentView = Schema.Struct({
  allotment: Schema.NullOr(CloudAllotmentSetting),
  decision: Schema.Struct({
    allot_micros: AllotmentMicros,
    forecast_micros: AllotmentMicros,
    position: AllotmentPosition,
    to_commit_micros: AllotmentMicros,
    reasons: Schema.Array(CloudAllotmentReason),
    members: Schema.Array(CloudAllotmentMember),
    order: Schema.Array(Schema.String),
    apply: Schema.Boolean
  }),
  advice: CloudAllotmentAdvice,
  hard_cap_micros: Schema.NullOr(AllotmentMicros),
  as_of: Schema.Int,
  names: Schema.Record(Schema.String, Schema.String)
}).annotate({ identifier: "CloudAllotmentView" })
/**
 * cloud.allotment.get: the caller's team's allotment and the scheduler's proposal, for the app's Settings Compute
 * card. Any team member may read it. A deployment with allotments off answers cloud.allotment.off.
 */
export const CloudAllotmentGet = cloudRead(
  "cloud.allotment.get",
  Schema.Struct({}),
  CloudAllotmentView,
  ["cloud.allotment.off"],
  "This team's Cloud allotment and the scheduler's proposal from metered use: scale the pooled monthly commit down, hold it or scale it up, with each member's use this month and over 14 days, and the reasons (unused seats, starts past the allotment, a runaway). A read.",
  "cloud allotment get"
)

export const CloudMachineConnectInfo = cloudRead(
  "cloud.machine.connect_info",
  Schema.Struct({ machine: Schema.optionalKey(MachineId), host: Schema.optionalKey(HostId) }),
  CloudConnectInfo,
  ["cloud.machine.not_bound", "cloud.machine.not_found"],
  "How `cmux link` reaches a machine (contract 1.7). Give exactly one of machine and host. Peer data comes in every bound state; a paused machine is state paused, not an error. cloud.machine.not_bound while it provisions. A read never mints a credential: the dial token comes from cloud.machine.link_token. vm_kind is the caller's kind on this machine (owner for its creator on any team, never an agent token; every other member is team).",
  "cloud machine connect-info"
)

/**
 * `desktop` is the person's view of the machine's agent display (`cmux.rd/1`, carried over the link). Only the
 * machine's creator may mint it, and only on a machine whose daemon block advertises CLOUD_DESKTOP_CAPABILITY.
 * connect_info never lists it: clients before it read that list strictly, so the mint is its only authority.
 */
const LinkService = Schema.Literals(["daemon", "ssh", "desktop"])
const LinkServices = Schema.Array(LinkService).check(Schema.isMinLength(1), Schema.isMaxLength(3), Schema.isUnique())
/** The bind/status daemon capability of a machine whose image serves the `desktop` link service. */
export const CLOUD_DESKTOP_CAPABILITY = "link-desktop-v1"

export const CloudMachineLinkToken = def({
  name: "cloud.machine.link_token",
  owner: "cloud:CloudDO",
  class: "mutation",
  idempotency: "none",
  risk: "execute",
  target: "team",
  principals: ["install"],
  params: Schema.Struct({ host: HostId, services: LinkServices, native_proof: Schema.optionalKey(ServerNetworkProof) }),
  result: Schema.Struct({
    /** Secret: shown once to the caller, checked by the VM daemon on `hello`. */
    token: Schema.String,
    /** At most 5 minutes after the mint. */
    expires_at: Millis,
    host: HostId,
    epoch: Schema.Int,
    services: LinkServices,
    /** The caller's kind on this machine, also signed into the token (claim `vmk`): the answer of this one dial. */
    vm_kind: CloudVmKind
  }),
  // No key and no revision input, so no idempotency.conflict and no revision.conflict.
  errors: [...MUTATION.filter((code) => code !== "revision.conflict" && code !== "idempotency.conflict"), ...LIMITED, "cloud.link.install_refused", "cloud.machine.not_bound", "cloud.machine.not_found", "cloud.machine.paused"],
  docs: "Mint the dial token `cmux link` sends on `hello` to one host: single host, single install, the asked services (unique, a subset of what connect_info lists, or `desktop`, which connect_info never lists: the machine's creator only, on a machine whose daemon advertises link-desktop-v1) and the current epoch, valid at most 5 minutes. The token carries the caller's vm_kind (claim vmk, the same value as the result's vm_kind), so the owner answer is bound to this dial and ends with the token. No idempotency key: each call mints a fresh token and nothing replays, so a stored answer can never hand a credential out twice; a retry mints another. Every mint is audited by CloudDO and commits no stream event; the token is never cached, logged or kept in the ledger. Install principals only (agent tokens refused), and only cli, mac and ios installs (others: cloud.link.install_refused with details {install_kind, allowed}; the kind is what the install registered, so this keeps well-behaved vm, daemon and web installs out and is not a boundary against the user); limited per install (cloud.rate_limited); a deleting or failed machine answers cloud.machine.not_bound; a paused, pausing or starting machine answers cloud.machine.paused {machine, state} (no automatic start: the client asks the person and calls cloud.machine.start); only `cmux link` calls it: off MCP, hidden on the CLI, never consumed by an app.",
  cli: { path: "cloud machine link-token", visible: false },
  mcp: { expose: "never", group: "cloud" }
})
export const CloudMachineUpgrade = cloudMutation(
  "cloud.machine.upgrade",
  "execute",
  MachineParams,
  MachineResult,
  ["cloud.machine.not_classic", "cloud.machine.not_found", "cloud.upgrade.failed", ...PROVIDER],
  "Move one classic machine onto cmux-next: install the daemon and bind it to the overlay. A failed upgrade leaves a working classic machine (cloud.upgrade.failed)." + KEY,
  "cloud machine upgrade",
  true
)

export const CloudSnapshotList = cloudRead(
  "cloud.snapshot.list",
  Schema.Struct({ machine: Schema.optionalKey(MachineId) }),
  Schema.Struct({ snapshots: Schema.Array(CloudSnapshot) }),
  ["cloud.machine.not_found"],
  "Snapshots of one machine, or of the team.",
  "cloud snapshot list"
)
export const CloudSnapshotCreate = cloudMutation(
  "cloud.snapshot.create",
  "money",
  Schema.Struct({ machine: MachineId, name: Schema.optionalKey(MachineName) }),
  Schema.Struct({ snapshot: CloudSnapshot }),
  ["cloud.machine.not_found", "cloud.machine.not_running", "cloud.quota.exceeded", "cloud.plan.required", ...LIMITED, ...PROVIDER, ...APPROVAL],
  "Take a snapshot of a running or paused, bound machine (else cloud.machine.not_running {machine, state}): answers status creating; cloud.snapshot.upsert brings ready (or failed). It counts against the plan's saved limit (max_saved): cloud.quota.exceeded {limit, used, resource: saved}. A money op: a signed-in person only; limited per team." + KEY + APPROVAL_DOC,
  "cloud snapshot create",
  true
)
export const CloudSnapshotRestore = cloudMutation(
  "cloud.snapshot.restore",
  "money",
  Schema.Struct({ snapshot: SnapshotId, name: Schema.optionalKey(MachineName) }),
  MachineResult,
  ["cloud.no_snapshot_configured", "cloud.plan.required", "cloud.quota.exceeded", "cloud.size.locked", "cloud.snapshot.not_found", ...SPEND_CAP, ...VM_LIMIT, ...LIMITED, ...PROVIDER, ...APPROVAL],
  "Create a new machine booted from a ready snapshot (plan checks as create; a fresh bind like any create). A money op: a signed-in person only; limited per team." + KEY + APPROVAL_DOC,
  "cloud snapshot restore",
  true
)
export const CloudSnapshotDelete = cloudMutation(
  "cloud.snapshot.delete",
  "destructive",
  Schema.Struct({ snapshot: SnapshotId }),
  Deleted,
  ["cloud.snapshot.not_found", "cloud.machine.busy", ...LIMITED, ...PROVIDER, ...APPROVAL],
  "Delete a snapshot (its provider snapshot under the recorded name only); cloud.snapshot.removed follows. A snapshot still being taken answers cloud.machine.busy. A signed-in person only; limited per team." + KEY + APPROVAL_DOC,
  "cloud snapshot delete",
  true
)

export const CloudPlanGet = cloudRead("cloud.plan.get", Schema.Struct({}), CloudPlan, [], "The team's plan: limits and usage this period. Read from the billing owner, never from a request.", "cloud plan get")
/**
 * The team's Cloud usage so far this calendar month (UTC) and what it costs (cmux-platform metering): awake
 * vCPU-seconds and memory GiB-seconds of the machine's size, and GiB-seconds of disk held while paused. `usd` is the
 * billing owner's own price of each meter; a client shows it and computes no price. `gaps`: spans the meter has not
 * counted yet (a VM whose usage is still arriving); empty when every second is in. Spare machines are never usage.
 * `payment_method`: whether the team has a card on file (brand and last four only; no card data enters cmux).
 * `stripe_mode`: "test" while payments run in the processor's test mode.
 */
export const CloudUsageCurrent = Schema.Struct({
  /** The billing month, "YYYY-MM" (UTC). */
  period: Schema.String.check(isPattern(/^\d{4}-\d{2}$/)),
  /** When the meter was last read. */
  as_of: Millis,
  /** When metering began for this team in this period (later than the month's start for a team new this month); null before the first metered second. */
  metered_since: Schema.NullOr(Millis),
  vcpu_seconds: Schema.Number,
  memory_gib_seconds: Schema.Number,
  stored_gib_seconds: Schema.Number,
  usd: Schema.Struct({ vcpu: Schema.Number, memory: Schema.Number, stored: Schema.Number, total: Schema.Number }),
  gaps: Schema.Array(Schema.String),
  payment_method: Schema.Struct({
    attached: Schema.Boolean,
    brand: Schema.optionalKey(Schema.NullOr(Schema.String)),
    last4: Schema.optionalKey(Schema.NullOr(Schema.String.check(isPattern(/^\d{4}$/))))
  }),
  stripe_mode: Schema.Literals(["test", "live"])
}).annotate({ identifier: "CloudUsageCurrent" })
export const CloudUsageCurrentGet = cloudRead(
  "cloud.usage.current",
  Schema.Struct({}),
  CloudUsageCurrent,
  [],
  "The team's Cloud usage so far this month (awake vCPU and memory, disk held while paused), its price from the billing owner, and whether a payment method is on file.",
  "cloud usage current"
)
export const CloudBillingCheckout = cloudMutation(
  "cloud.billing.checkout",
  "money",
  Schema.Struct({ plan: Schema.optionalKey(PlanId) }),
  Schema.Struct({ url: Schema.String.check(isPattern(/^https:\/\//)) }),
  ["cloud.billing.off"],
  "Start a checkout: an https URL the client opens in the browser. With a plan it changes the plan; without one it attaches a payment method. No card data enters cmux. cloud.billing.off: payments are not open for this deployment.",
  "cloud billing checkout",
  true
)
export const CloudShellOpen = cloudMutation(
  "cloud.shell.open",
  "execute",
  Schema.Struct({ machine: MachineId, cols: Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 1000 })), rows: Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 1000 })) }),
  Schema.Struct({ stream: Schema.String }),
  ["cloud.machine.not_found", "cloud.machine.paused", ...PROVIDER],
  "Open the rescue shell: a wire stream id the client opens as a WebSocket (contract 2.6). Works when the VM daemon is down and for classic machines.",
  "cloud shell open"
)
export const CloudMigrationStatus = cloudRead(
  "cloud.migration.status",
  Schema.Struct({}),
  Schema.Struct({ state: Schema.Literals(["none", "available", "moving", "moved"]), classic_count: Schema.Int, imported: Schema.Array(MachineId) }),
  [],
  "Whether this account has machines from cmux Cloud classic to move, and which were imported.",
  "cloud migration status"
)
export const CloudMigrationStart = cloudMutation(
  "cloud.migration.start",
  "mutate-own",
  Schema.Struct({}),
  Schema.Struct({ state: Schema.Literals(["moving", "moved"]) }),
  ["cloud.migration.unavailable"],
  "Move this account's classic machines to cmux-next, one way.",
  "cloud migration start",
  true
)

/**
 * Cloud surge (cmux-platform RFD 0025, src/server/cloud/Surge.ts): a bounded, expiring burst of team
 * machines through the team's Cloud provider. Platform-only: cmux-api's forwarder sends these ops to
 * cmux-platform because they are in this catalog (platform-forward.ts). Same shapes as cmux-platform
 * src/server/cloud/domain/SurgeOps.ts.
 */
export const SURGE_CAP = 100
// The operation catalog reads input fields from the top-level schema, so leave this struct inline.
export const SurgeRequest = Schema.Struct({
  count: Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: SURGE_CAP })),
  ttl_seconds: Schema.Int.check(Schema.isBetween({ minimum: 300, maximum: 3600 }))
})

const SurgePreview = Schema.Struct({
  ...SurgeRequest.fields,
  provider: Schema.NullOr(Schema.String),
  available: Schema.Boolean,
  reason: Schema.String,
  estimated_cost_usd: Schema.NullOr(Schema.Number)
}).annotate({ identifier: "CloudSurgePreview" })

const SurgeSlot = Schema.Struct({
  index: Schema.Int,
  status: Schema.Literals(["created", "queued", "refused"]),
  machine_id: Schema.NullOr(MachineId),
  provider: Schema.NullOr(Schema.String),
  reason: Schema.String,
  retryable: Schema.Boolean
}).annotate({ identifier: "CloudSurgeSlot" })

const SurgeReceipt = Schema.Struct({
  ...SurgeRequest.fields,
  slots: Schema.Array(SurgeSlot)
}).annotate({ identifier: "CloudSurgeReceipt" })

export const CloudSurgePreview = cloudRead(
  "cloud.surge.preview",
  SurgeRequest,
  SurgePreview,
  [],
  "Estimate a bounded Cloud capacity burst at the current running list rate and report whether the team can request it.",
  "cloud surge preview"
)

export const CloudSurgeCreate = {
  ...cloudMutation(
    "cloud.surge.create",
    "money",
    SurgeRequest,
    SurgeReceipt,
    ["cloud.surge.unavailable", "cloud.surge.capacity"],
    "Request an expiring burst through the team's Cloud provider. Each slot reports whether its create was accepted.",
    "cloud surge create",
    true
  ),
  principals: ["session"] as const
}

export const cloudMachineOps = [
  CloudMachineList,
  CloudMachineGet,
  CloudMachineCreate,
  CloudMachineRename,
  CloudMachineStart,
  CloudMachinePause,
  CloudMachineResize,
  CloudMachineDelete,
  CloudMachineIdlePolicySet,
  CloudMachineKeep,
  CloudMachineArchiveDelete,
  CloudRetentionSet,
  CloudAllotmentGet,
  CloudMachineConnectInfo,
  CloudMachineLinkToken,
  CloudMachineUpgrade,
  CloudSnapshotList,
  CloudSnapshotCreate,
  CloudSnapshotRestore,
  CloudSnapshotDelete,
  CloudPlanGet,
  CloudUsageCurrentGet,
  CloudBillingCheckout,
  CloudShellOpen,
  CloudMigrationStatus,
  CloudMigrationStart,
  CloudSurgePreview,
  CloudSurgeCreate
] as const
