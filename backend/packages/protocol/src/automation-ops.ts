import { Schema } from "effect"
import {
  Automation,
  AutomationId,
  TriggerId,
  AutomationCreateParams,
  AutomationDeliverParams,
  AutomationFireParams,
  AutomationSelector,
  AutomationUpdateParams,
  Run,
  RunDispatchedParams,
  RunReportParams,
  RunsListParams
} from "./automations.ts"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"
import { TeamId } from "./schemas.ts"

/**
 * Automation ops (spec cloud-and-automations.md "APIs and ops"). Owner: the
 * SchedulerDO of the caller's team (a personal account is a team of one).
 */

export const AutomationCreate = def({
  name: "automation.create",
  owner: "cloud:SchedulerDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "automation",
  principals: ["session", "install"],
  params: AutomationCreateParams,
  result: Automation,
  errors: [...mutationErrors, "automation.limit", "trigger.invalid"],
  docs: "Create an automation (triggers, body, target policy) in the caller's team.",
  cli: { path: "automation create", visible: true },
  mcp: { expose: "opt_in", group: "automation" }
})

export const AutomationUpdate = def({
  name: "automation.update",
  owner: "cloud:SchedulerDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "automation",
  principals: ["session", "install"],
  params: AutomationUpdateParams,
  result: Automation,
  errors: [...mutationErrors, "selector.not_found", "trigger.invalid", "version.conflict"],
  docs: "Change an automation; the version increments and later runs use the new version.",
  cli: { path: "automation update", visible: true },
  mcp: { expose: "opt_in", group: "automation" }
})

export const AutomationDelete = def({
  name: "automation.delete",
  owner: "cloud:SchedulerDO",
  class: "mutation",
  risk: "destructive",
  target: "automation",
  principals: ["session", "install"],
  params: AutomationSelector,
  result: Schema.Struct({ automation: Schema.String }),
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Delete an automation. Its run history stays.",
  cli: { path: "automation delete", visible: true },
  mcp: { expose: "never", group: "automation" }
})

export const AutomationRunNow = def({
  name: "automation.run",
  owner: "cloud:SchedulerDO",
  class: "mutation",
  risk: "execute",
  target: "automation",
  principals: ["session", "install"],
  params: AutomationSelector,
  result: Run,
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Start a run of an automation now (manual trigger).",
  cli: { path: "automation run", visible: true },
  mcp: { expose: "default", group: "automation" }
})

export const AutomationList = def({
  name: "automation.list",
  owner: "cloud:SchedulerDO",
  class: "read",
  risk: "read",
  target: "automation",
  principals: ["session", "install"],
  params: Schema.Struct({}),
  result: Schema.Struct({ owner: Schema.NullOr(TeamId), automations: Schema.Array(Automation), revision: Schema.String }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "List the automations of the caller's team.",
  cli: { path: "automation list", visible: true },
  mcp: { expose: "default", group: "automation" }
})

export const AutomationGet = def({
  name: "automation.get",
  owner: "cloud:SchedulerDO",
  class: "read",
  risk: "read",
  target: "automation",
  principals: ["session", "install"],
  params: AutomationSelector,
  result: Automation,
  errors: ["auth.unauthenticated", "auth.forbidden", "selector.not_found"],
  docs: "Read one automation.",
  cli: { path: "automation get", visible: true },
  mcp: { expose: "default", group: "automation" }
})

export const AutomationRunsList = def({
  name: "automation.runs.list",
  owner: "cloud:SchedulerDO",
  class: "read",
  risk: "read",
  target: "run",
  principals: ["session", "install"],
  params: RunsListParams,
  result: Schema.Struct({ runs: Schema.Array(Run), revision: Schema.String }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "List recent runs, newest first (the owner keeps every active run and the last 200 finished ones; older history is in the projection).",
  cli: { path: "automation runs", visible: true },
  mcp: { expose: "default", group: "automation" }
})

export const AutomationWebhookGet = def({
  name: "automation.webhook.get",
  owner: "cloud:SchedulerDO",
  class: "read",
  risk: "read",
  target: "automation",
  principals: ["session"],
  params: Schema.Struct({ automation: AutomationId, trigger: TriggerId }),
  result: Schema.Struct({
    automation: AutomationId,
    trigger: TriggerId,
    path: Schema.String,
    secret: Schema.String,
    scheme: Schema.String
  }),
  errors: ["auth.unauthenticated", "auth.forbidden", "selector.not_found"],
  docs: "Read a webhook trigger's endpoint path and signing secret (HMAC-SHA256 over '<x-cmux-timestamp>.<body>', header x-cmux-signature: v1=<hex>). Human sessions only: the secret starts runs.",
  cli: { path: "automation webhook", visible: true },
  mcp: { expose: "never", group: "automation" }
})

export const AutomationSettings = Schema.Struct({
  /** Limit of an agent_prompt run whose automation sets no wall-clock budget (seconds); null = the default 24 h. */
  agent_run_default_seconds: Schema.NullOr(Schema.Int.check(Schema.isBetween({ minimum: 60, maximum: 30 * 24 * 3600 })))
}).annotate({ identifier: "AutomationSettings" })

export const AutomationSettingsGet = def({
  name: "automation.settings.get",
  owner: "cloud:SchedulerDO",
  class: "read",
  risk: "read",
  target: "automation",
  principals: ["session", "install"],
  params: Schema.Struct({}),
  result: AutomationSettings,
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "Read the team's automation settings (default limit of agent runs).",
  cli: { path: "automation settings", visible: true },
  mcp: { expose: "opt_in", group: "automation" }
})

export const AutomationSettingsSet = def({
  name: "automation.settings.set",
  owner: "cloud:SchedulerDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "automation",
  principals: ["session"],
  params: AutomationSettings,
  result: AutomationSettings,
  errors: [...mutationErrors, "team.roles_required"],
  docs: "Change the team's automation settings (team admins). Each automation can still override with budget.wall_clock_seconds.",
  cli: { path: "automation settings set", visible: true },
  mcp: { expose: "never", group: "automation" }
})

export const automationOps = [
  AutomationCreate,
  AutomationUpdate,
  AutomationDelete,
  AutomationRunNow,
  AutomationList,
  AutomationGet,
  AutomationRunsList,
  AutomationWebhookGet,
  AutomationSettingsGet,
  AutomationSettingsSet
] as const

const internal = (name: string, params: Schema.Top, docs: string): CloudOpDef =>
  ({
    name,
    owner: "cloud:SchedulerDO",
    class: "mutation",
    risk: "mutate-own",
    target: "automation",
    principals: ["system"],
    params,
    result: Schema.Unknown,
    errors: [],
    docs,
    cli: { path: "", visible: false },
    mcp: { expose: "never", group: "internal" }
  }) as CloudOpDef

/** Ops only the SchedulerDO itself submits (its alarm, its Workflows). Not exported to the catalog. */
export const schedulerInternalOps: ReadonlyArray<CloudOpDef> = [
  internal("automation.fire", AutomationFireParams, "Internal: a cron trigger fired for one scheduled instant."),
  internal("automation.deliver", AutomationDeliverParams, "Internal: a verified webhook delivery for one trigger."),
  internal("run.report", RunReportParams, "Internal: a run's Workflow reports progress."),
  internal("run.dispatched", RunDispatchedParams, "Internal: the run's Workflow instance exists.")
]
