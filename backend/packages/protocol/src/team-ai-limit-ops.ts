import { Schema } from "effect"
import { def, mutationErrors } from "./op-def.ts"
import { UserId } from "./schemas.ts"

/**
 * Monthly AI spending limits (cx-ds09i, Lawrence 2026-10-12): every member's own spend on the hosted
 * model router and on metered automation runs, in USD of our provider cost per UTC month.
 *
 * A member's limit is their personal limit (team.ai_limit.member.set), else the team default
 * (team.ai_limit.set), else INFERENCE_USER_MONTHLY_DEFAULT_USD. Team admins (billing.manage) set
 * either to any amount, higher or lower; 0 = no AI; null clears it. TeamDO checks the role.
 */
export const INFERENCE_USER_MONTHLY_DEFAULT_USD = 200

/** A finite amount in USD, 0 or more (the bound only rejects Infinity and NaN), or null (= use the next level). */
const LimitUsd = Schema.NullOr(Schema.Number.check(Schema.isBetween({ minimum: 0, maximum: Number.MAX_SAFE_INTEGER })))

export const TeamAiLimitSetParams = Schema.Struct({ default_usd: LimitUsd })
export const TeamAiLimitMemberSetParams = Schema.Struct({ member: UserId, limit_usd: LimitUsd })

export const TeamAiLimitSet = def({
  name: "team.ai_limit.set",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "money",
  target: "team",
  principals: ["session"],
  params: TeamAiLimitSetParams,
  result: Schema.Struct({ default_usd: Schema.NullOr(Schema.Number) }),
  errors: [...mutationErrors],
  docs: "Set the team's default monthly AI spending limit per member (USD per person per UTC month, any amount; 0 = no AI; null = the cmux default of 200). A member's personal limit wins over it. Team admins and billing members, in a person's session. Recorded in the billing audit.",
  cli: { path: "team ai-limit set", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const TeamAiLimitMemberSet = def({
  name: "team.ai_limit.member.set",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "money",
  target: "team",
  principals: ["session"],
  params: TeamAiLimitMemberSetParams,
  result: Schema.Struct({ member: UserId, limit_usd: Schema.NullOr(Schema.Number) }),
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Set one member's personal monthly AI spending limit (USD per UTC month, any amount; 0 = no AI); null clears it and the member uses the team default again. Team admins and billing members, in a person's session. Recorded in the billing audit.",
  cli: { path: "team ai-limit member-set", visible: true },
  mcp: { expose: "never", group: "team" }
})

const LimitSource = Schema.Literals(["personal", "team", "default"])

export const TeamAiLimitMember = Schema.Struct({
  user: UserId,
  display_name: Schema.String,
  role: Schema.String,
  limit_usd: Schema.Number,
  source: LimitSource,
  spent_usd: Schema.Number
}).annotate({ identifier: "TeamAiLimitMember" })

/**
 * The team line (cx-y79zh S5): the team's AI usage this period against its plan's included amount.
 * Billed: usage above the included amount is billed at cost; the period is the billing period and the
 * amount is per team or per seat (x seats). Not billed: the UTC month; with the stop on, AI calls stop
 * at the included amount until the next month.
 */
export const TeamAiUsageLine = Schema.Struct({
  billed: Schema.Boolean,
  included_usd: Schema.NullOr(Schema.Number),
  per_seat: Schema.Boolean,
  seats: Schema.Int,
  /** -1 when the usage meter did not answer. */
  spent_usd: Schema.Number,
  period_start: Schema.NullOr(Schema.Int),
  period_end: Schema.Int,
  stop_applies: Schema.Boolean,
  stopped: Schema.Boolean
}).annotate({ identifier: "TeamAiUsageLine" })

export const TeamAiLimitGet = def({
  name: "team.ai_limit.get",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({ cursor: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(128))) }),
  result: Schema.Struct({
    team: Schema.String,
    default_usd: Schema.Number,
    is_default: Schema.Boolean,
    resets_at: Schema.Int,
    me: TeamAiLimitMember,
    /** Only for team admins and billing members (billing.manage); 200 per page. */
    members: Schema.optionalKey(Schema.Array(TeamAiLimitMember)),
    /** Only beside members: the team's usage against its included amount. */
    team_usage: Schema.optionalKey(TeamAiUsageLine),
    next_cursor: Schema.optionalKey(Schema.NullOr(Schema.String))
  }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "Monthly AI spending limits: the team default, your own limit and spend this month, and when they reset. Team admins and billing members also get every member's limit and spend, and the team's usage this period against its included amount.",
  cli: { path: "team ai-limit get", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const teamAiLimitOps = [TeamAiLimitSet, TeamAiLimitMemberSet, TeamAiLimitGet] as const
