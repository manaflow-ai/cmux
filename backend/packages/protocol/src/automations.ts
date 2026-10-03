import { Schema } from "effect"
import { automationCapabilityOps } from "./automation-caps.ts"
import { DisplayName, HostId, TeamId, UserId } from "./schemas.ts"

/**
 * Automation shape v1 (spec cloud-and-automations.md "Data"). The SchedulerDO
 * of an owner team holds definitions; runs execute as Cloudflare Workflows.
 * Times are ms since the epoch.
 */

const prefixedId = (prefix: string, identifier: string, description: string) =>
  Schema.String.check(Schema.isPattern(new RegExp(`^${prefix}_[a-z0-9]{20}$`))).annotate({ identifier, description })

export const AutomationId = prefixedId("auto", "AutomationId", "An automation definition, owned by its team's SchedulerDO.")
export const TriggerId = prefixedId("trg", "TriggerId", "One trigger of an automation; assigned by the owner.")
export const RunId = prefixedId("run", "RunId", "One automation run; also its Workflow instance id.")

const Int = (minimum: number, maximum: number) => Schema.Int.check(Schema.isBetween({ minimum, maximum }))
const Text = (max: number) => Schema.String.check(Schema.isMaxLength(max))
const NonEmptyText = (max: number) => Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(max))

/** Five-field cron (minute granularity, so the one-minute floor holds) in an IANA time zone. */
export const CronSpec = Schema.Struct({
  expr: NonEmptyText(120),
  tz: NonEmptyText(64)
}).annotate({ identifier: "CronSpec" })

export const TriggerInput = Schema.Union([
  Schema.Struct({ type: Schema.Literal("cron"), expr: NonEmptyText(120), tz: NonEmptyText(64) }),
  Schema.Struct({ type: Schema.Literal("manual") }),
  Schema.Struct({ type: Schema.Literal("webhook") }),
  Schema.Struct({
    type: Schema.Literal("event"),
    source: Schema.Literals(["integration", "machine", "store", "task"]),
    connection: Schema.optionalKey(NonEmptyText(64)),
    event: NonEmptyText(120),
    filter: Schema.optionalKey(Schema.Record(Schema.String, Schema.String))
  }),
  Schema.Struct({ type: Schema.Literal("message"), conversation: NonEmptyText(64), rule: NonEmptyText(500) }),
  Schema.Struct({
    type: Schema.Literal("continue"),
    until: Schema.Array(Schema.Literals(["goal_met", "budget", "stop"])),
    // Floor of one minute, like cron: a body that ends at once must not spin.
    cooldown_seconds: Int(60, 7 * 24 * 3600),
    max_runs: Schema.optionalKey(Int(1, 10_000))
  }),
  Schema.Struct({
    type: Schema.Literal("presence"),
    when: Schema.Literals(["user_active", "user_returns_after"]),
    idle_minutes: Schema.optionalKey(Int(1, 7 * 24 * 60)),
    earliest: Schema.optionalKey(CronSpec)
  })
]).annotate({ identifier: "TriggerInput" })
export type TriggerInput = typeof TriggerInput.Type

/** A stored trigger: the input plus its owner-assigned id and whether this backend fires it yet. */
export const Trigger = Schema.Struct({
  id: TriggerId,
  status: Schema.Literals(["active", "not_yet_supported"]),
  spec: TriggerInput,
  /** Cron triggers: the next scheduled fire. */
  next_at: Schema.NullOr(Schema.Int)
}).annotate({ identifier: "Trigger" })

export const Step = Schema.Union([
  Schema.Struct({ type: Schema.Literal("sleep"), seconds: Int(1, 365 * 24 * 3600) }),
  Schema.Struct({ type: Schema.Literal("note"), text: Text(2000) }),
  /**
   * One cloud op, run as the automation (automation-caps.ts lists the ops). The op's own
   * schema validates `params` when the step runs; the step's key makes a retry replay.
   */
  Schema.Struct({ type: Schema.Literal("op"), op: Schema.Literals(automationCapabilityOps), params: Schema.Unknown })
]).annotate({ identifier: "Step" })

/**
 * One host a code automation may reach over HTTPS (port 443) through the egress
 * gateway: an exact host name or `*.` plus a domain (subdomains only). Lowercase
 * DNS names with a letter TLD, so IP literals never match.
 */
export const EgressHost = Schema.String.check(
  Schema.isPattern(/^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/),
  Schema.isMaxLength(253)
).annotate({ identifier: "EgressHost" })

/** A full Git commit id (40 lowercase hex). Short ids and branch names never pin a run. */
export const CommitSha = Schema.String.check(Schema.isPattern(/^[0-9a-f]{40}$/)).annotate({ identifier: "CommitSha" })

/**
 * Where an automation's code lives (decisions A12, C1): a directory
 * `automations/<slug>` of the owner team's code.storage repository at one
 * commit. The repository is not a field: each team has exactly one, derived
 * from the owner team by the backend, so a ref can never name another team's
 * repository. The CLI bundles to `<path>/dist/index.js` in the same commit;
 * `export` names the WorkflowEntrypoint class in that module.
 */
export const CodeRef = Schema.Struct({
  commit: CommitSha,
  path: Schema.String.check(Schema.isPattern(/^automations\/[a-z0-9][a-z0-9-]{0,62}$/)),
  export: Schema.optionalKey(Schema.String.check(Schema.isPattern(/^[A-Za-z_$][A-Za-z0-9_$]{0,63}$/)))
}).annotate({ identifier: "CodeRef" })
export type CodeRef = typeof CodeRef.Type

/** The bundle a code ref runs: one ES module the CLI builds into the same commit. */
export const codeBundlePath = (ref: Pick<CodeRef, "path">) => `${ref.path}/dist/index.js`

export const Body = Schema.Union([
  Schema.Struct({
    type: Schema.Literal("agent_prompt"),
    instructions: NonEmptyText(20_000),
    model: Schema.optionalKey(NonEmptyText(80)),
    effort: Schema.optionalKey(Schema.Literals(["low", "medium", "high", "xhigh"])),
    workspace: Schema.Struct({
      mode: Schema.Literals(["fresh_worktree", "repo"]),
      repo: Schema.optionalKey(NonEmptyText(300)),
      ref: Schema.optionalKey(NonEmptyText(200))
    }),
    conversation: Schema.Literals(["fresh", "continue"])
  }),
  Schema.Struct({ type: Schema.Literal("steps"), steps: Schema.Array(Step).check(Schema.isMinLength(1), Schema.isMaxLength(50)) }),
  /** Chief-written Workflows code (decision A11) at a pinned commit; runs on Tier 1 Dynamic Workers. */
  Schema.Struct({
    type: Schema.Literal("code"),
    ref: CodeRef,
    /** Hosts the code may fetch through the egress gateway (none = no network). Part of the body, so a run pins it. */
    egress: Schema.optionalKey(Schema.Array(EgressHost).check(Schema.isMaxLength(20)))
  })
]).annotate({ identifier: "Body" })
export type Body = typeof Body.Type

export const TargetPolicy = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("cloud_vm") }),
  Schema.Struct({ kind: Schema.Literal("host"), host: HostId, fallback: Schema.Literals(["cloud_vm", "wait", "fail"]) })
]).annotate({ identifier: "TargetPolicy" })

export const Concurrency = Schema.Struct({
  max: Int(1, 10),
  on_limit: Schema.Literals(["queue", "skip"])
}).annotate({ identifier: "Concurrency" })

export const Budget = Schema.Struct({
  wall_clock_seconds: Schema.optionalKey(Int(1, 365 * 24 * 3600)),
  vm_minutes: Schema.optionalKey(Int(1, 1_000_000)),
  model_spend_usd: Schema.optionalKey(Schema.Number.check(Schema.isBetween({ minimum: 0, maximum: 100_000 }))),
  tool_calls: Schema.optionalKey(Int(1, 1_000_000))
}).annotate({ identifier: "Budget" })

export const Automation = Schema.Struct({
  id: AutomationId,
  owner: TeamId,
  name: DisplayName,
  description: Text(2000),
  enabled: Schema.Boolean,
  version: Schema.Int,
  triggers: Schema.Array(Trigger),
  body: Body,
  target: TargetPolicy,
  concurrency: Concurrency,
  budget: Budget,
  created_by: UserId,
  created_at: Schema.Int,
  updated_at: Schema.Int,
  next_run_at: Schema.NullOr(Schema.Int)
}).annotate({ identifier: "Automation" })
export type Automation = typeof Automation.Type

export const RunState = Schema.Literals(["queued", "running", "sleeping", "waiting", "succeeded", "failed", "cancelled", "skipped", "dead"]).annotate({
  identifier: "RunState"
})
export type RunState = typeof RunState.Type

export const RunError = Schema.Struct({ code: Schema.String, message: Schema.String }).annotate({ identifier: "RunError" })

export const Run = Schema.Struct({
  id: RunId,
  automation: AutomationId,
  automation_version: Schema.Int,
  owner: TeamId,
  trigger: Schema.Struct({
    id: Schema.NullOr(TriggerId),
    type: Schema.String,
    scheduled_at: Schema.optionalKey(Schema.Int),
    delivery_id: Schema.optionalKey(Schema.String),
    /** type `automation`: the run whose code or op step started this run, and the chain depth (1 = started by a run another trigger started). */
    parent_run: Schema.optionalKey(RunId),
    depth: Schema.optionalKey(Schema.Int)
  }),
  state: RunState,
  step: Schema.Int,
  created_at: Schema.Int,
  started_at: Schema.NullOr(Schema.Int),
  finished_at: Schema.NullOr(Schema.Int),
  error: Schema.NullOr(RunError),
  outcome: Schema.NullOr(Schema.Struct({ goal_met: Schema.Boolean, summary: Schema.optionalKey(Text(2000)) }))
}).annotate({ identifier: "Run" })
export type Run = typeof Run.Type

export const AutomationCreateParams = Schema.Struct({
  name: DisplayName,
  description: Schema.optionalKey(Text(2000)),
  enabled: Schema.optionalKey(Schema.Boolean),
  triggers: Schema.Array(TriggerInput).check(Schema.isMinLength(1), Schema.isMaxLength(10)),
  body: Body,
  target: Schema.optionalKey(TargetPolicy),
  concurrency: Schema.optionalKey(Concurrency),
  budget: Schema.optionalKey(Budget)
})

export const AutomationUpdateParams = Schema.Struct({
  automation: AutomationId,
  /** Optimistic check on the automation's own version (the owner-wide revision is `expected_revision`). */
  expected_version: Schema.optionalKey(Schema.Int),
  name: Schema.optionalKey(DisplayName),
  description: Schema.optionalKey(Text(2000)),
  enabled: Schema.optionalKey(Schema.Boolean),
  triggers: Schema.optionalKey(Schema.Array(TriggerInput).check(Schema.isMinLength(1), Schema.isMaxLength(10))),
  body: Schema.optionalKey(Body),
  target: Schema.optionalKey(TargetPolicy),
  concurrency: Schema.optionalKey(Concurrency),
  budget: Schema.optionalKey(Budget)
})

export const AutomationSelector = Schema.Struct({ automation: AutomationId })

/** Activate another commit of a code automation (the CLI's `deploy`). */
export const AutomationDeployParams = Schema.Struct({
  automation: AutomationId,
  commit: CommitSha,
  /** Optimistic check on the automation's own version. */
  expected_version: Schema.optionalKey(Schema.Int)
})

export const RunsListParams = Schema.Struct({
  automation: Schema.optionalKey(AutomationId),
  limit: Schema.optionalKey(Int(1, 200))
})

/** Internal ops (owner `system` principal only; never on HTTP, MCP or the CLI). */
export const AutomationFireParams = Schema.Struct({
  automation: AutomationId,
  trigger: TriggerId,
  scheduled_at: Schema.Int
})

export const AutomationDeliverParams = Schema.Struct({
  automation: AutomationId,
  trigger: TriggerId,
  delivery_id: NonEmptyText(200)
})

export const RunReportParams = Schema.Struct({
  run: RunId,
  state: RunState,
  step: Schema.Int,
  error: Schema.optionalKey(RunError),
  outcome: Schema.optionalKey(Schema.Struct({ goal_met: Schema.Boolean, summary: Schema.optionalKey(Text(2000)) }))
})

export const RunDispatchedParams = Schema.Struct({ run: RunId })

/**
 * TeamDO's push of the run class of agents.allowedClasses (enterprise P17-4): whether the team
 * allows automation runs, at a TeamPolicy version. SchedulerDO keeps the newest version.
 */
export const RunPolicyApplyParams = Schema.Struct({
  version: Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0)),
  runs_allowed: Schema.Boolean
})
