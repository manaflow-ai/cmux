import { Schema } from "effect"
import { def, mutationErrors } from "./op-def.ts"
import { TeamId } from "./schemas.ts"

/**
 * Automation usage (spec automations-billing.md, decisions A18, A21). One
 * UsageMeterDO per team is the only writer of the team's usage ledger: tails,
 * the wrapped step, the egress gateway and capability calls record into it, and
 * it refuses further work at the team's hard USD cap. Stripe, PlanetScale and
 * dashboards are projections; Cloudflare analytics only reconcile.
 */

/** Billable meters. Units are fixed per meter (see `meterUnit`). */
export const Meter = Schema.Literals([
  "automation.steps",
  "automation.cpu_ms",
  "automation.invocations",
  "automation.dynamic_workers",
  "egress.requests",
  "model.spend_usd"
]).annotate({ identifier: "Meter" })
export type Meter = typeof Meter.Type

export const meterUnit: Readonly<Record<Meter, string>> = {
  "automation.steps": "step",
  "automation.cpu_ms": "ms",
  "automation.invocations": "invocation",
  "automation.dynamic_workers": "worker_day",
  "egress.requests": "request",
  "model.spend_usd": "usd"
}

/** Where a record came from (for reconciliation and debugging; never changes the price). */
export const UsageSource = Schema.Literals(["tail", "step", "egress", "capability", "scheduler", "coderouter"]).annotate({ identifier: "UsageSource" })

/** One ledger record. `key` makes recording idempotent: the same key is counted once, forever within the retention. */
export const UsageRecord = Schema.Struct({
  key: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(200)),
  meter: Meter,
  quantity: Schema.Number.check(Schema.isBetween({ minimum: 0, maximum: 1e12 })),
  source: UsageSource,
  observed_at: Schema.Int,
  run: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(64))),
  automation: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(64))),
  step: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(256))),
  attempt: Schema.optionalKey(Schema.Int),
  commit: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(64)))
}).annotate({ identifier: "UsageRecord" })
export type UsageRecord = typeof UsageRecord.Type

export const UsageMeterLine = Schema.Struct({
  meter: Meter,
  unit: Schema.String,
  quantity: Schema.Number,
  usd: Schema.Number
}).annotate({ identifier: "UsageMeterLine" })

/** Why work stops: the team's cap, or no cap configured on this deployment. */
export const UsageStopReason = Schema.Literals(["cap.reached", "cap.not_configured"]).annotate({ identifier: "UsageStopReason" })
export type UsageStopReason = typeof UsageStopReason.Type

export const UsageSummary = Schema.Struct({
  owner: Schema.NullOr(TeamId),
  /** UTC month, YYYY-MM. */
  month: Schema.String,
  meters: Schema.Array(UsageMeterLine),
  total_usd: Schema.Number,
  /** The cap in force: the team's own cap, never above the deployment ceiling. */
  cap_usd: Schema.Number,
  /** The deployment's ceiling per team per month (staff-set; 0 = automations off). */
  ceiling_usd: Schema.Number,
  /** The team's own lower cap, when set. */
  team_cap_usd: Schema.NullOr(Schema.Number),
  stopped: Schema.NullOr(UsageStopReason)
}).annotate({ identifier: "UsageSummary" })
export type UsageSummary = typeof UsageSummary.Type

export const UsageSummaryGet = def({
  name: "usage.summary",
  owner: "cloud:UsageMeterDO",
  class: "read",
  risk: "read",
  target: "usage",
  principals: ["session", "install"],
  params: Schema.Struct({}),
  result: UsageSummary,
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "This month's automation usage of the caller's team, its cost estimate and the hard cap that stops runs.",
  cli: { path: "usage", visible: true },
  mcp: { expose: "default", group: "usage" }
})

export const UsageCapSetParams = Schema.Struct({
  /** A monthly cap for the team, or null to use the deployment ceiling. The cap in force is never above the ceiling. */
  cap_usd: Schema.NullOr(Schema.Number.check(Schema.isBetween({ minimum: 0, maximum: 1_000_000 })))
})

export const UsageCapSet = def({
  name: "usage.cap.set",
  owner: "cloud:UsageMeterDO",
  class: "mutation",
  risk: "money",
  target: "usage",
  principals: ["session"],
  params: UsageCapSetParams,
  result: Schema.Struct({ owner: Schema.NullOr(TeamId), team_cap_usd: Schema.NullOr(Schema.Number) }),
  errors: [...mutationErrors, "team.roles_required"],
  docs: "Set the team's own monthly hard cap for automations (team admins). The cap in force is the lower of it and the deployment ceiling.",
  cli: { path: "usage cap set", visible: true },
  mcp: { expose: "never", group: "usage" }
})

export const usageOps = [UsageSummaryGet, UsageCapSet] as const
