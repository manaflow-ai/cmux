import type { ReduceContext, Reject, RowReader } from "@cmux/ownership"
import { TeamAiLimitSet } from "@cmux/protocol"
import { decodeParams, reject } from "./common.ts"
import { appendAudit } from "./team-audit.ts"
import { roleOf } from "./team-members.ts"
import { roleHas } from "./team-roles.ts"
import type { TeamState } from "./team.ts"

/**
 * team.ai_limit.set (cx-ds09i): the per-user monthly AI spending limit of this team, in TeamDO
 * team state (`ai_user_monthly_limit_usd`, null = the deployment default). Members whose role
 * holds billing.manage (owner, admin, billing) may change it, in a person's session; every change
 * is a billing audit record with the value before and after and the actor.
 */
export const AI_LIMIT_OP = "team.ai_limit.set"

/** The billing role holds no team.resources grant, so authorize admits this op by billing.manage instead (team.ts). */
export const mayManageBilling = (role: string | undefined) => roleHas(role, "billing.manage")

export const reduceAiLimitSet = (state: TeamState, params: unknown, ctx: ReduceContext): { ok: true; state: TeamState; value: unknown; changed?: boolean; outbox?: ReadonlyArray<unknown> } | ({ ok: false } & Reject) => {
  if (!state.team) return reject("validation.invalid", "team not initialized")
  const p = ctx.principal
  if (p.kind !== "session" || p.agent) return reject("auth.forbidden", "the AI spending limit changes only in a person's session")
  if (!mayManageBilling(roleOf(state, ctx.rows as RowReader, p.user))) return reject("auth.forbidden", "only team owners, admins and billing members may change the AI spending limit")
  const d = decodeParams<typeof TeamAiLimitSet.params.Type>(TeamAiLimitSet, params)
  if (!d.ok) return d
  const before = state.ai_user_monthly_limit_usd ?? null
  const after = d.value.user_monthly_limit_usd
  const value = { user_monthly_limit_usd: after }
  if (before === after) return { ok: true, state, value, changed: false }
  const fmt = (v: number | null) => (v === null ? "the default" : `${v} USD`)
  const a = appendAudit({ ...state, ai_user_monthly_limit_usd: after }, state.team.id, ctx, AI_LIMIT_OP, `monthly AI limit per member: ${fmt(before)} -> ${fmt(after)}`, { before, after }, "billing")
  return { ok: true, state: a.state, value, outbox: [a.outbox] }
}
