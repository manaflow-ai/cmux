import { Schema } from "effect"
import { APPROVAL, APPROVAL_DOC, CloudMachine, CloudMachineSize, KEY, LIMITED, MachineName, PROVIDER, SnapshotId, cloudMutation, cloudRead } from "./cloud-machine-ops.ts"
import { Revision, UserId } from "./schemas.ts"
import { isPattern } from "./json-checks.ts"

/**
 * Cloud environments (plans/cmux-next/cloud-environments-DESIGN.md): a repository, a setup script
 * and variables that CloudDO builds once into a snapshot, so a new machine in the environment boots
 * ready. CloudDO owns the rows next to the team's machines and snapshots; a build's snapshot is an
 * ordinary team snapshot (it counts against max_saved). Secret variables name a vault item; until
 * the hosted vault exists, a build or a boot of an environment with one answers
 * cloud.environment.secrets_unavailable.
 */

export const EnvironmentId = Schema.String.check(isPattern(/^env_[a-z0-9]{20}$/)).annotate({ identifier: "EnvironmentId", description: "A Cloud environment." })
const VarName = Schema.String.check(isPattern(/^[A-Za-z_][A-Za-z0-9_]{0,127}$/))

export const CloudEnvironmentVariable = Schema.Union([
  Schema.Struct({ name: VarName, value: Schema.String.check(Schema.isMaxLength(32768)) }),
  Schema.Struct({ name: VarName, secret: Schema.String.check(isPattern(/^[A-Za-z0-9._-]{1,128}$/)) })
]).annotate({ identifier: "CloudEnvironmentVariable", description: "A plain variable (baked into the snapshot) or a secret (a vault item name; the value never enters the snapshot)." })

const Millis = Schema.Int
const Repo = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(300))
const SetupScript = Schema.String.check(Schema.isMaxLength(65536))
const Variables = Schema.Array(CloudEnvironmentVariable).check(Schema.isMaxLength(100))

export const CloudEnvironmentBuildRecord = Schema.Struct({
  state: Schema.Literals(["building", "ready", "failed"]),
  started_at: Millis,
  finished_at: Schema.NullOr(Millis),
  error: Schema.NullOr(Schema.Struct({ code: Schema.String, message: Schema.String })),
  /** The last 4 KB of the setup output of a failed build; null otherwise. */
  log_tail: Schema.NullOr(Schema.String),
  /** Where a finished build spent its time (ms). */
  timings: Schema.NullOr(Schema.Struct({ boot_ms: Schema.Int, ready_ms: Schema.Int, setup_ms: Schema.Int, snapshot_ms: Schema.Int, warm_ms: Schema.Int, total_ms: Schema.Int }))
}).annotate({ identifier: "CloudEnvironmentBuildRecord" })

export const CloudEnvironment = Schema.Struct({
  id: EnvironmentId,
  name: MachineName,
  /** `owner/name[@ref]`, or null for an environment without a repository. */
  repo: Schema.NullOr(Repo),
  setup_script: SetupScript,
  env: Variables,
  creator: UserId,
  /**
   * unbuilt: never built; building: a build runs; ready: new machines boot from the snapshot;
   * stale: the snapshot no longer matches the inputs or the image (machines boot cold until the
   * next build); failed: the last build failed and there is no usable snapshot.
   */
  status: Schema.Literals(["unbuilt", "building", "ready", "stale", "failed"]),
  /** The snapshot new machines boot from while status is ready; it is also in cloud.snapshot.list. */
  snapshot: Schema.NullOr(SnapshotId),
  last_build: Schema.NullOr(CloudEnvironmentBuildRecord),
  created_at: Millis,
  revision: Revision
}).annotate({ identifier: "CloudEnvironment" })

const EnvironmentResult = Schema.Struct({ environment: CloudEnvironment })
const EnvironmentParams = Schema.Struct({ environment: EnvironmentId })
const INVALID = "cloud.environment.invalid"
const NOT_FOUND = "cloud.environment.not_found"
const SECRETS = "cloud.environment.secrets_unavailable"

export const CloudEnvironmentList = cloudRead(
  "cloud.environment.list",
  Schema.Struct({}),
  Schema.Struct({ environments: Schema.Array(CloudEnvironment) }),
  [],
  "The team's Cloud environments, oldest first, with each one's build status.",
  "cloud environment list"
)
export const CloudEnvironmentSet = cloudMutation(
  "cloud.environment.set",
  "mutate-shared",
  Schema.Struct({
    /** Absent: create one; present: edit it (only the given fields change). */
    environment: Schema.optionalKey(EnvironmentId),
    name: Schema.optionalKey(MachineName),
    repo: Schema.optionalKey(Schema.NullOr(Repo)),
    setup_script: Schema.optionalKey(SetupScript),
    env: Schema.optionalKey(Variables)
  }),
  EnvironmentResult,
  [NOT_FOUND, INVALID, "cloud.quota.exceeded"],
  "Create an environment (name required) or edit one. The inputs are checked as a whole: cloud.environment.invalid {field, message} (a GitHub repo as owner/name[@ref] or a github.com URL without credentials, a setup script up to 64 KB, at most 100 variables with names the machine does not own). An edit to the repo, the script or the variables makes a built snapshot stale; a rename does not. At most 20 environments per team (cloud.quota.exceeded {limit, used, resource: environments}).",
  "cloud environment set",
  true
)
export const CloudEnvironmentDelete = cloudMutation(
  "cloud.environment.delete",
  "destructive",
  EnvironmentParams,
  Schema.Struct({ deleted: Schema.Literal(true) }),
  [NOT_FOUND, "cloud.environment.busy", ...LIMITED, ...APPROVAL],
  "Delete an environment and its snapshot (cloud.snapshot.removed follows). Machines booted from it keep running. A build still running answers cloud.environment.busy." + KEY + APPROVAL_DOC,
  "cloud environment delete",
  true
)
export const CloudEnvironmentBuildOp = cloudMutation(
  "cloud.environment.build",
  "money",
  EnvironmentParams,
  Schema.Struct({ environment: CloudEnvironment, built: Schema.Boolean }),
  [NOT_FOUND, SECRETS, "cloud.environment.busy", "cloud.plan.required", "cloud.quota.exceeded", ...LIMITED, ...PROVIDER, ...APPROVAL],
  "Build the environment's snapshot: a builder machine from the deployment's image clones the repo, runs the setup script, and is snapshotted and deleted. Answers at once with status building (built: true); the build takes minutes, and cloud.environment.list shows ready or failed with the log tail. A snapshot that still matches answers built: false and changes nothing. The new snapshot counts against max_saved (cloud.quota.exceeded {resource: saved}); it replaces the previous one when it is ready. One build per environment at a time (cloud.environment.busy). A money op: a signed-in person only; limited per team." + KEY + APPROVAL_DOC,
  "cloud environment build",
  true
)
export const CloudEnvironmentBoot = cloudMutation(
  "cloud.environment.boot",
  "money",
  Schema.Struct({ environment: EnvironmentId, name: Schema.optionalKey(MachineName), size: CloudMachineSize }),
  Schema.Struct({ machine: CloudMachine, boot: Schema.Literals(["snapshot", "cold"]) }),
  [NOT_FOUND, SECRETS, "cloud.no_snapshot_configured", "cloud.plan.required", "cloud.quota.exceeded", "cloud.size.locked", "cloud.snapshot.not_found", ...LIMITED, ...PROVIDER, ...APPROVAL],
  "Create a machine in the environment (the plan checks of cloud.machine.create). boot snapshot: it boots the environment's ready snapshot and runs nothing. boot cold (no build yet, or a stale one): it boots the deployment's image and starts the setup on the machine in the background (~/.cmux/environment-build.log; ~/.cmux/environment.json when it finished). A money op: a signed-in person only; limited per team." + KEY + APPROVAL_DOC,
  "cloud environment boot",
  true
)

export const cloudEnvironmentOps = [CloudEnvironmentList, CloudEnvironmentSet, CloudEnvironmentDelete, CloudEnvironmentBuildOp, CloudEnvironmentBoot] as const
