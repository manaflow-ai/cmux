import { Schema } from "effect"
import { def, mutationErrors } from "./op-def.ts"
import { HostId, Revision, TeamId, UserId } from "./schemas.ts"

/**
 * cmux-next Cloud machines (plans/cmux-next/cloud-client-contract.md 1.2, 1.3 and 1.7;
 * state-placement.md 5). CloudDO, one per team, is the single writer of the team's machine and
 * snapshot registry, the provider-call ledger and the plan checks. Revisions are the CloudDO
 * stream sequence of an entity's last change, so entity and list revisions compare. Each op
 * declares every error code it may answer; a client treats any other code as a protocol break.
 * The shared vectors are backend/catalog/cloud-vectors.json.
 */

export const MachineId = Schema.String.check(Schema.isPattern(/^vm_[a-z0-9]{20}$/)).annotate({ identifier: "MachineId", description: "A Cloud machine." })
export const SnapshotId = Schema.String.check(Schema.isPattern(/^snap_[a-z0-9]{20}$/)).annotate({ identifier: "SnapshotId", description: "A Cloud machine snapshot." })
const PlanId = Schema.String.check(Schema.isPattern(/^[a-z0-9][a-z0-9_-]{0,63}$/))
const ImageId = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(128))
const MachineName = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(80))
const Millis = Schema.Int

export const CloudMachineStatus = Schema.Literals(["provisioning", "starting", "running", "pausing", "paused", "deleting", "failed"]).annotate({ identifier: "CloudMachineStatus" })

export const CloudMachineSize = Schema.Struct({
  cpu: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 64 }))),
  memory_mb: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 512, maximum: 262144 }))),
  disk_mb: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 1024, maximum: 1048576 })))
}).annotate({ identifier: "CloudMachineSize", description: "A machine size. The plan decides which sizes are allowed (cloud.size.locked)." })

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
  revision: Revision
}).annotate({ identifier: "CloudMachine" })

export const CloudSnapshot = Schema.Struct({
  id: SnapshotId,
  machine: MachineId,
  name: Schema.NullOr(MachineName),
  size_mb: Schema.Int,
  status: Schema.Literals(["creating", "ready", "deleting", "failed"]),
  created_at: Millis,
  revision: Revision
}).annotate({ identifier: "CloudSnapshot" })

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
  usage: Schema.Struct({ active: Schema.Int, saved: Schema.Int, vm_hours_used: Schema.Number, period_end: Millis })
}).annotate({ identifier: "CloudPlan" })

export const CloudConnectInfo = Schema.Struct({
  machine: MachineId,
  host: HostId,
  /** A restore or re-bind raises it; the link refuses a hello from a lower epoch. */
  epoch: Schema.Int,
  state: CloudMachineStatus,
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
  revision: Revision
}).annotate({ identifier: "CloudConnectInfo" })

const MachineResult = Schema.Struct({ machine: CloudMachine })
const Deleted = Schema.Struct({ deleted: Schema.Literal(true) })
const MachineParams = Schema.Struct({ machine: MachineId })

/** The Worker's own gates answer these for every op, before the owner sees it. */
const GATES = ["auth.sso_required", "client.too_old", "owner.unreachable"]
const READ = ["auth.forbidden", "auth.unauthenticated", "selector.not_found", "validation.invalid", ...GATES]
const MUTATION = [...mutationErrors, ...GATES]
/** A provider call can fail for now or be cut off; the caller retries the same key after mutation.indeterminate. */
const PROVIDER = ["cloud.provider.unavailable", "mutation.indeterminate"]
/** Create and delete are limited per team (CLOUD_MUTATION_LIMIT); retryable, retry after a minute. */
const LIMITED = ["cloud.rate_limited"]
const KEY = " After mutation.indeterminate, retry with the same idempotency key."
const PERSON = " Agent principals are refused; the client asks a person first."

const cloudRead = <P extends Schema.Top, R extends Schema.Top>(name: string, params: P, result: R, errors: Array<string>, docs: string, cli: string) =>
  def({ name, owner: "cloud:CloudDO", class: "read", risk: "read", target: "team", principals: ["session", "install"], params, result, errors: [...READ, ...errors], docs, cli: { path: cli, visible: true }, mcp: { expose: "default", group: "cloud" } })

const cloudMutation = <P extends Schema.Top, R extends Schema.Top>(
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
  Schema.Struct({ name: Schema.optionalKey(MachineName), size: CloudMachineSize, image: Schema.optionalKey(ImageId), from_snapshot: Schema.optionalKey(SnapshotId) }),
  MachineResult,
  ["cloud.no_snapshot_configured", "cloud.plan.required", "cloud.quota.exceeded", "cloud.size.locked", "cloud.snapshot.not_found", ...PROVIDER, ...LIMITED],
  "Create a machine (status provisioning; a cloud.machine.upsert follows when it is bound). The plan is checked before any provider call: cloud.plan.required, cloud.quota.exceeded {limit, used}, cloud.size.locked. A same-key retry never makes a second machine." + KEY,
  "cloud machine create",
  true
)
export const CloudMachineRename = cloudMutation("cloud.machine.rename", "mutate-shared", Schema.Struct({ machine: MachineId, name: MachineName }), MachineResult, ["cloud.machine.not_found"], "Rename a machine.", "cloud machine rename")
export const CloudMachineStart = cloudMutation("cloud.machine.start", "mutate-shared", MachineParams, MachineResult, ["cloud.machine.not_found", "cloud.quota.exceeded", ...PROVIDER], "Start (resume) a paused machine. May answer cloud.quota.exceeded {limit, used}." + KEY, "cloud machine start")
export const CloudMachinePause = cloudMutation("cloud.machine.pause", "mutate-shared", MachineParams, MachineResult, ["cloud.machine.not_found", ...PROVIDER], "Pause a running machine." + KEY, "cloud machine pause")
export const CloudMachineResize = cloudMutation(
  "cloud.machine.resize",
  "money",
  Schema.Struct({ machine: MachineId, size: CloudMachineSize }),
  MachineResult,
  ["cloud.machine.not_found", "cloud.quota.exceeded", "cloud.size.locked", ...PROVIDER],
  "Change a machine's size. A larger size may cost money." + KEY,
  "cloud machine resize",
  true
)
export const CloudMachineDelete = cloudMutation(
  "cloud.machine.delete",
  "destructive",
  MachineParams,
  Deleted,
  ["cloud.machine.not_found", ...PROVIDER, ...LIMITED],
  "Delete a machine and its disk. A provider 404 is success, and the tombstone answers {deleted: true} for 30 days, also to a new key." + KEY,
  "cloud machine delete",
  true
)
export const CloudMachineIdlePolicySet = cloudMutation(
  "cloud.machine.idle_policy.set",
  "mutate-shared",
  Schema.Struct({ machine: MachineId, idle_seconds: Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: 604800 })) }),
  MachineResult,
  ["cloud.machine.not_found"],
  "Set when an idle machine pauses; 0 = never.",
  "cloud machine idle-policy set"
)
export const CloudMachineConnectInfo = cloudRead(
  "cloud.machine.connect_info",
  Schema.Struct({ machine: Schema.optionalKey(MachineId), host: Schema.optionalKey(HostId) }),
  CloudConnectInfo,
  ["cloud.machine.not_bound", "cloud.machine.not_found"],
  "How `cmux link` reaches a machine (contract 1.7). Give exactly one of machine and host. Peer data comes in every bound state; a paused machine is state paused, not an error. cloud.machine.not_bound while it provisions. A read never mints a credential: the dial token comes from cloud.machine.link_token.",
  "cloud machine connect-info"
)

const LinkService = Schema.Literals(["daemon", "ssh"])
const LinkServices = Schema.Array(LinkService).check(Schema.isMinLength(1), Schema.isMaxLength(2), Schema.isUnique())

export const CloudMachineLinkToken = def({
  name: "cloud.machine.link_token",
  owner: "cloud:CloudDO",
  class: "mutation",
  idempotency: "none",
  risk: "execute",
  target: "team",
  principals: ["install"],
  params: Schema.Struct({ host: HostId, services: LinkServices }),
  result: Schema.Struct({
    /** Secret: shown once to the caller, checked by the VM daemon on `hello`. */
    token: Schema.String,
    /** At most 5 minutes after the mint. */
    expires_at: Millis,
    host: HostId,
    epoch: Schema.Int,
    services: LinkServices
  }),
  // No key and no revision input, so no idempotency.conflict and no revision.conflict.
  errors: [...MUTATION.filter((code) => code !== "revision.conflict" && code !== "idempotency.conflict"), "cloud.machine.not_bound", "cloud.machine.not_found"],
  docs: "Mint the dial token `cmux link` sends on `hello` to one host: single host, single install, the asked services (unique, a subset of what connect_info lists) and the current epoch, valid at most 5 minutes. No idempotency key: each call mints a fresh token and nothing replays, so a stored answer can never hand a credential out twice; a retry mints another. Every mint is audited by CloudDO and commits no stream event; the token is never cached, logged or kept in the ledger. Install principals only; only `cmux link` calls it: off MCP, hidden on the CLI, never consumed by an app.",
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
  ["cloud.machine.not_found", "cloud.quota.exceeded", ...PROVIDER],
  "Take a snapshot of a machine. It counts against the plan's saved limit (max_saved): cloud.quota.exceeded {limit, used}." + KEY,
  "cloud snapshot create",
  true
)
export const CloudSnapshotRestore = cloudMutation(
  "cloud.snapshot.restore",
  "money",
  Schema.Struct({ snapshot: SnapshotId, name: Schema.optionalKey(MachineName) }),
  MachineResult,
  ["cloud.no_snapshot_configured", "cloud.plan.required", "cloud.quota.exceeded", "cloud.size.locked", "cloud.snapshot.not_found", ...PROVIDER],
  "Create a new machine from a snapshot (plan checks as create)." + KEY,
  "cloud snapshot restore",
  true
)
export const CloudSnapshotDelete = cloudMutation(
  "cloud.snapshot.delete",
  "destructive",
  Schema.Struct({ snapshot: SnapshotId }),
  Deleted,
  ["cloud.snapshot.not_found", ...PROVIDER],
  "Delete a snapshot." + KEY,
  "cloud snapshot delete",
  true
)

export const CloudPlanGet = cloudRead("cloud.plan.get", Schema.Struct({}), CloudPlan, [], "The team's plan: limits and usage this period. Read from the billing owner, never from a request.", "cloud plan get")
export const CloudBillingCheckout = cloudMutation(
  "cloud.billing.checkout",
  "money",
  Schema.Struct({ plan: PlanId }),
  Schema.Struct({ url: Schema.String.check(Schema.isPattern(/^https:\/\//)) }),
  [],
  "Start a plan checkout: an https URL the client opens in the browser. No card data enters cmux.",
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
  CloudMachineConnectInfo,
  CloudMachineLinkToken,
  CloudMachineUpgrade,
  CloudSnapshotList,
  CloudSnapshotCreate,
  CloudSnapshotRestore,
  CloudSnapshotDelete,
  CloudPlanGet,
  CloudBillingCheckout,
  CloudShellOpen,
  CloudMigrationStatus,
  CloudMigrationStart
] as const
