import { Schema } from "effect"
import { def, mutationErrors } from "./op-def.ts"

/**
 * The team's per-user monthly AI spending limit (cx-ds09i, Lawrence 2026-10-12): every member's
 * own spend on the hosted model router and on metered automation runs, in USD of our provider
 * cost per UTC month. null = the deployment default (INFERENCE_USER_MONTHLY_DEFAULT_USD, 200).
 * 0 = no AI for members. At most 10000.
 */
export const TeamAiLimitSetParams = Schema.Struct({
  user_monthly_limit_usd: Schema.NullOr(Schema.Number.check(Schema.isBetween({ minimum: 0, maximum: 10_000 })))
})

export const TeamAiLimitSet = def({
  name: "team.ai_limit.set",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "money",
  target: "team",
  principals: ["session"],
  params: TeamAiLimitSetParams,
  result: Schema.Struct({ user_monthly_limit_usd: Schema.NullOr(Schema.Number) }),
  errors: [...mutationErrors],
  docs: "Set the monthly AI spending limit for each member of the team (USD per person per UTC month; null = the default of 200). Owners, admins and billing members, in a person's session only. Recorded in the billing audit.",
  cli: { path: "team ai-limit set", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const teamAiLimitOps = [TeamAiLimitSet] as const
