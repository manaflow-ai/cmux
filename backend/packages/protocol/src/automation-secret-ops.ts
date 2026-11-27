import { Schema } from "effect"
import { def, mutationErrors } from "./op-def.ts"
import { isPattern } from "./json-checks.ts"
import { AutomationId } from "./automations.ts"
import { UserId } from "./schemas.ts"

/**
 * Per-automation secrets (AUTOMATIONS-SPEC section 12, models-scout): named values a Cloud command
 * automation's machine steps get as environment variables. The value travels only in the
 * `automation.secret.set` request: SchedulerDO seals it into a side table (integrations/credentials.ts,
 * KMS when configured, else INTEGRATIONS_KEK), bound to team, automation, name and generation, and no
 * op param, event, snapshot, ledger row, read or run record ever holds it. At run time the Workflow
 * opens them inside the step and sends them on the step's stdin, never in its command line.
 */
export const AutomationSecretName = Schema.String.check(isPattern(/^[A-Z][A-Z0-9_]{0,63}$/)).annotate({
  identifier: "AutomationSecretName",
  description: "An environment variable name: capital letters, digits and _, starting with a letter (at most 64)."
})

/** The longest value: a cloud service account key file fits well inside. */
export const AUTOMATION_SECRET_MAX_BYTES = 32 * 1024
/** Secrets one automation may hold. */
export const AUTOMATION_SECRETS_MAX = 20

export const AutomationSecretState = Schema.Struct({
  name: AutomationSecretName,
  /** The last four characters of a value of at least 12, else null. */
  hint: Schema.NullOr(Schema.String),
  generation: Schema.Int,
  updated_at: Schema.Int,
  updated_by: UserId
}).annotate({ identifier: "AutomationSecretState" })

export const AutomationSecretSet = def({
  name: "automation.secret.set",
  owner: "cloud:SchedulerDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "automation",
  principals: ["session"],
  params: Schema.Struct({
    automation: AutomationId,
    name: AutomationSecretName,
    value: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(AUTOMATION_SECRET_MAX_BYTES))
  }),
  result: AutomationSecretState,
  errors: [...mutationErrors, "selector.not_found", "automation_secret.not_configured", "automation_secret.too_many"],
  docs: "Add or replace one secret of an automation (its creator, editors and team admins, in a person's session). Its machine steps get it as the environment variable NAME. The value is never returned.",
  cli: { path: "automation secret set", visible: false },
  mcp: { expose: "never", group: "automation" }
})

export const AutomationSecretRemove = def({
  name: "automation.secret.remove",
  owner: "cloud:SchedulerDO",
  class: "mutation",
  risk: "destructive",
  target: "automation",
  principals: ["session"],
  params: Schema.Struct({ automation: AutomationId, name: AutomationSecretName }),
  result: Schema.Struct({ automation: AutomationId, name: AutomationSecretName, removed: Schema.Boolean }),
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Remove one secret of an automation (its creator, editors and team admins).",
  cli: { path: "automation secret remove", visible: false },
  mcp: { expose: "never", group: "automation" }
})

export const AutomationSecretList = def({
  name: "automation.secret.list",
  owner: "cloud:SchedulerDO",
  class: "read",
  risk: "read",
  target: "automation",
  principals: ["session"],
  params: Schema.Struct({ automation: AutomationId }),
  result: Schema.Struct({ automation: AutomationId, secrets: Schema.Array(AutomationSecretState) }),
  errors: ["auth.unauthenticated", "auth.forbidden", "selector.not_found"],
  docs: "The names of an automation's secrets (who may edit it). Never returns a value.",
  cli: { path: "automation secret list", visible: false },
  mcp: { expose: "never", group: "automation" }
})

export const automationSecretOps = [AutomationSecretSet, AutomationSecretRemove, AutomationSecretList] as const
