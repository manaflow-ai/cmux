import { Schema } from "effect"
import { automationCapabilityOps } from "./automation-caps.ts"
import { MachineId } from "./cloud-machine-ops.ts"
import { ConversationId } from "./ops-home-schemas.ts"
import { DisplayName, HostId, TeamId, UserId } from "./schemas.ts"
import { isPattern } from "./json-checks.ts"

/**
 * Automation shape v1 (spec cloud-and-automations.md "Data"). The SchedulerDO
 * of an owner team holds definitions; runs execute as Cloudflare Workflows.
 * Times are ms since the epoch.
 */

const prefixedId = (prefix: string, identifier: string, description: string) =>
  Schema.String.check(isPattern(new RegExp(`^${prefix}_[a-z0-9]{20}$`))).annotate({ identifier, description })

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
  Schema.Struct({ type: Schema.Literal("op"), op: Schema.Literals(automationCapabilityOps), params: Schema.Unknown }),
  /**
   * One fixed shell command on one of the team's own Cloud machines (org workflows,
   * plans/cmux-next/org-workflows-DESIGN.md). The run journals its output (the stdout tail),
   * so a replay never runs it again. `input_from` names an earlier machine or agent step whose
   * journaled output goes to this command's stdin.
   */
  Schema.Struct({
    type: Schema.Literal("machine"),
    machine: MachineId,
    command: NonEmptyText(4000),
    input_from: Schema.optionalKey(Int(0, 49)),
    /** One provider exec answers within about 300 s; longer work belongs in a durable terminal. */
    timeout_seconds: Int(1, 300)
  }),
  /**
   * One agent turn through acpmux on one of the team's machines. The prompt (and the
   * `input_from` output) goes on stdin, never into the command line; the reply is journaled once.
   */
  Schema.Struct({
    type: Schema.Literal("agent"),
    machine: MachineId,
    harness: Schema.Literals(["claude", "codex", "opencode"]),
    prompt: NonEmptyText(8000),
    input_from: Schema.optionalKey(Int(0, 49)),
    /** One provider exec answers within about 300 s; longer work belongs in a durable terminal. */
    timeout_seconds: Int(1, 300)
  })
]).annotate({ identifier: "Step" })

/**
 * One host a code automation may reach over HTTPS (port 443) through the egress
 * gateway: an exact host name or `*.` plus a domain (subdomains only). Lowercase
 * DNS names with a letter TLD, so IP literals never match.
 */
export const EgressHost = Schema.String.check(
  isPattern(/^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/),
  Schema.isMaxLength(253)
).annotate({ identifier: "EgressHost" })

/** A full Git commit id (40 lowercase hex). Short ids and branch names never pin a run. */
export const CommitSha = Schema.String.check(isPattern(/^[0-9a-f]{40}$/)).annotate({ identifier: "CommitSha" })

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
  path: Schema.String.check(isPattern(/^automations\/[a-z0-9][a-z0-9-]{0,62}$/)),
  export: Schema.optionalKey(Schema.String.check(isPattern(/^[A-Za-z_$][A-Za-z0-9_$]{0,63}$/)))
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
  /**
   * A Chief's own job (plans/cmux-next/chief-automations-DESIGN.md): each run puts `prompt` in the
   * Chief's conversation as the Chief's own note and starts a Cloud Chief turn there, so the job
   * runs in the cloud while the person's computers sleep and the Chief posts the result in that
   * chat. Delivery refuses a Chief whose owner is not the member the run is charged to.
   */
  Schema.Struct({
    type: Schema.Literal("chief"),
    chief: Schema.String.check(isPattern(/^agent_[A-Za-z0-9_.-]{1,64}$/)),
    conversation: ConversationId,
    prompt: NonEmptyText(8000),
    destination: Schema.optionalKey(Schema.Struct({
      type: Schema.Literal("slack"),
      slackTeamId: Schema.String.check(isPattern(/^T[A-Z0-9]+$/)),
      channelId: Schema.String.check(isPattern(/^[CDG][A-Z0-9]+$/))
    }))
  }),
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

/**
 * Team scope and placement (docs/automations-teleport-teams.md). `team` (the default, and every
 * automation made before sharing) is visible to every member; `private` only to its creator, its
 * editors and the team's admins and owners.
 */
export const Sharing = Schema.Literals(["team", "private"]).annotate({ identifier: "Sharing" })
/** What a late fire does: `latest` fires the newest missed slot if younger than 24 h, `all` each (at most 10), `none` nothing. */
export const CatchUp = Schema.Literals(["latest", "all", "none"]).annotate({ identifier: "CatchUp" })
/** Where a teleport goes: the Chief teleport's grammar (`home`, `ssh:<host>[:<dir>]`) plus `cloud`. */
export const TeleportDestination = NonEmptyText(256)
/** A pending single-writer handoff: while it is set, nothing fires the automation. */
export const Handoff = Schema.Struct({
  id: Schema.String.check(isPattern(/^tp_[0-9a-f]{32}$/)),
  to: TeleportDestination,
  epoch: Schema.Int,
  at: Schema.Int
}).annotate({ identifier: "Handoff" })
export type Handoff = typeof Handoff.Type
/** An automation that left this store: it names where it went and never fires here. */
export const MovedAutomation = Schema.Struct({
  id: AutomationId,
  name: DisplayName,
  moved_to: TeleportDestination,
  moved_id: NonEmptyText(64),
  epoch: Schema.Int,
  moved_at: Schema.Int
}).annotate({ identifier: "MovedAutomation" })
export type MovedAutomation = typeof MovedAutomation.Type

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
  next_run_at: Schema.NullOr(Schema.Int),
  /** Absent on automations made before sharing: `team`. */
  sharing: Schema.optionalKey(Sharing),
  /** Members who may change it besides its creator and the team's admins and owners. */
  editors: Schema.optionalKey(Schema.Array(UserId).check(Schema.isMaxLength(50))),
  /** Absent: `latest`. */
  catch_up: Schema.optionalKey(CatchUp),
  /** The one store that fires it; a Cloud automation is `cloud`. */
  home: Schema.optionalKey(Schema.Literal("cloud")),
  /** 1 at create, one more on each teleport. */
  epoch: Schema.optionalKey(Schema.Int),
  /** The newest scheduled time already fired (ms), carried across a teleport. */
  last_slot: Schema.optionalKey(Schema.NullOr(Schema.Int)),
  /** Set while a teleport away from Cloud is in progress (fenced: never fires). */
  handoff: Schema.optionalKey(Handoff),
  /** The handoff that brought it here (import dedupe). */
  origin: Schema.optionalKey(Schema.Struct({ handoff: NonEmptyText(64), from: TeleportDestination, source_id: NonEmptyText(64) }))
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
    /** type `automation`: the first run of the chain (its tree shares one run budget). */
    root_run: Schema.optionalKey(RunId),
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
  budget: Schema.optionalKey(Budget),
  sharing: Schema.optionalKey(Sharing),
  editors: Schema.optionalKey(Schema.Array(UserId).check(Schema.isMaxLength(50))),
  catch_up: Schema.optionalKey(CatchUp)
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
  budget: Schema.optionalKey(Budget),
  sharing: Schema.optionalKey(Sharing),
  editors: Schema.optionalKey(Schema.Array(UserId).check(Schema.isMaxLength(50))),
  catch_up: Schema.optionalKey(CatchUp)
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

/** Keyset cursor of automation.list and run.list (pass the previous page's next_cursor). */
const PageCursor = Schema.String.check(Schema.isMaxLength(32))

export const AutomationListParams = Schema.Struct({
  cursor: Schema.optionalKey(PageCursor),
  limit: Schema.optionalKey(Int(1, 100))
})

export const RunListParams = Schema.Struct({
  automation: Schema.optionalKey(AutomationId),
  state: Schema.optionalKey(RunState),
  cursor: Schema.optionalKey(PageCursor),
  limit: Schema.optionalKey(Int(1, 100))
})

export const RunSelector = Schema.Struct({ run: RunId })

/** A run with the body of the automation version that fired it (later edits never change it). */
export const RunWithBody = Schema.Struct({ ...Run.fields, body: Body }).annotate({ identifier: "RunWithBody" })

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

/**
 * Accept step of a teleport (docs/automations-teleport-teams.md section 2): the spec the source
 * fenced, with the handoff that carries its epoch and last fired slot. One copy per handoff id.
 */
export const AutomationImportParams = Schema.Struct({
  ...AutomationCreateParams.fields,
  handoff: Schema.Struct({
    id: Schema.String.check(isPattern(/^tp_[0-9a-f]{32}$/)),
    from: TeleportDestination,
    source_id: NonEmptyText(64),
    epoch: Int(1, 1_000_000),
    last_slot: Schema.NullOr(Schema.Int)
  })
})

/** Fence step when Cloud is the source: no fire and no run until complete or abort. */
export const AutomationTeleportBeginParams = Schema.Struct({
  automation: AutomationId,
  handoff: Schema.Struct({ id: Schema.String.check(isPattern(/^tp_[0-9a-f]{32}$/)), to: TeleportDestination })
})

/** Release step: the Cloud copy becomes a tombstone naming the destination's id. */
export const AutomationTeleportCompleteParams = Schema.Struct({
  automation: AutomationId,
  handoff: Schema.String.check(isPattern(/^tp_[0-9a-f]{32}$/)),
  moved_id: NonEmptyText(64)
})

/** The destination refused: lift the fence, the Cloud copy fires again. */
export const AutomationTeleportAbortParams = Schema.Struct({
  automation: AutomationId,
  handoff: Schema.String.check(isPattern(/^tp_[0-9a-f]{32}$/))
})

/** What `automation.teleport.begin` answers: the full automation and what the destination needs. */
export const AutomationTeleportBegun = Schema.Struct({
  automation: Automation,
  epoch: Schema.Int,
  last_slot: Schema.NullOr(Schema.Int)
}).annotate({ identifier: "AutomationTeleportBegun" })

/** One automation audit entry: who changed what; never a body or a secret. */
export const AutomationAuditEntry = Schema.Struct({
  n: Schema.Int,
  at: Schema.Int,
  actor: NonEmptyText(200),
  op: NonEmptyText(80),
  automation: AutomationId,
  summary: Text(500)
}).annotate({ identifier: "AutomationAuditEntry" })

export const AutomationAuditListParams = Schema.Struct({
  automation: Schema.optionalKey(AutomationId),
  limit: Schema.optionalKey(Int(1, 500))
})
