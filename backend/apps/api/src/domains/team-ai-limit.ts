import type { ReduceContext, Reject, RowReader } from "@cmux/ownership"
import { INFERENCE_USER_MONTHLY_DEFAULT_USD, TeamAiLimitMemberSet, TeamAiLimitSet } from "@cmux/protocol"
import { decodeParams, reject } from "./common.ts"
import { appendAudit } from "./team-audit.ts"
import { listMembers, memberOf, roleOf, type RowsWithScan } from "./team-members.ts"
import { roleHas } from "./team-roles.ts"
import type { TeamState } from "./team.ts"

/**
 * Monthly AI spending limits in TeamDO (cx-ds09i, Lawrence 2026-10-12): the team default
 * (`ai_user_monthly_limit_usd`, null = INFERENCE_USER_MONTHLY_DEFAULT_USD) and personal limits
 * per member (`ai_member_limits`). Only members whose role holds billing.manage (owner, admin,
 * billing) may change them, in a person's session: this reducer checks it, whatever the UI shows.
 * Every change is a billing audit record with the member, the value before and after, and the actor.
 */
export const AI_LIMIT_OP = "team.ai_limit.set"
export const AI_LIMIT_MEMBER_OP = "team.ai_limit.member.set"
export const AI_LIMIT_OPS: ReadonlySet<string> = new Set([AI_LIMIT_OP, AI_LIMIT_MEMBER_OP])

/** The billing role holds no team.resources grant, so authorize admits these ops by billing.manage instead (team.ts). */
export const mayManageBilling = (role: string | undefined) => roleHas(role, "billing.manage")

export type LimitSource = "personal" | "team" | "default"

/** A member's limit in force and where it comes from: personal, else the team default, else the cmux default. */
export const memberLimit = (state: TeamState | null | undefined, user: string): { limit_usd: number; source: LimitSource } => {
  const own = state?.ai_member_limits?.[user]
  if (typeof own === "number") return { limit_usd: own, source: "personal" }
  const team = state?.ai_user_monthly_limit_usd
  if (typeof team === "number") return { limit_usd: team, source: "team" }
  return { limit_usd: INFERENCE_USER_MONTHLY_DEFAULT_USD, source: "default" }
}

type Reduced = { ok: true; state: TeamState; value: unknown; changed?: boolean; outbox?: ReadonlyArray<unknown> } | ({ ok: false } & Reject)
const fmt = (v: number | null | undefined) => (typeof v === "number" ? `${v} USD` : "the default")

const guard = (state: TeamState, ctx: ReduceContext): Reject | undefined => {
  if (!state.team) return { code: "validation.invalid", message: "team not initialized" }
  const p = ctx.principal
  if (p.kind !== "session" || p.agent) return { code: "auth.forbidden", message: "AI spending limits change only in a person's session" }
  if (!mayManageBilling(roleOf(state, ctx.rows as RowReader, p.user))) return { code: "auth.forbidden", message: "only team owners, admins and billing members may change AI spending limits" }
  return undefined
}

export const reduceAiLimit = (state: TeamState, op: string, params: unknown, ctx: ReduceContext): Reduced => {
  const refused = guard(state, ctx)
  if (refused) return reject(refused.code, refused.message)
  if (op === AI_LIMIT_OP) {
    const d = decodeParams<typeof TeamAiLimitSet.params.Type>(TeamAiLimitSet, params)
    if (!d.ok) return d
    const before = state.ai_user_monthly_limit_usd ?? null
    const after = d.value.default_usd
    if (before === after) return { ok: true, state, value: { default_usd: after }, changed: false }
    const a = appendAudit({ ...state, ai_user_monthly_limit_usd: after }, state.team!.id, ctx, op, `team AI limit per member: ${fmt(before)} -> ${fmt(after)}`, { before, after }, "billing")
    return { ok: true, state: a.state, value: { default_usd: after }, outbox: [a.outbox] }
  }
  const d = decodeParams<typeof TeamAiLimitMemberSet.params.Type>(TeamAiLimitMemberSet, params)
  if (!d.ok) return d
  const { member, limit_usd: after } = d.value
  if (!memberOf(state, ctx.rows as RowReader, member)) return reject("selector.not_found", "not a member of this team")
  const before = state.ai_member_limits?.[member] ?? null
  if (before === after) return { ok: true, state, value: { member, limit_usd: after }, changed: false }
  const { [member]: _old, ...rest } = state.ai_member_limits ?? {}
  const limits = after === null ? rest : { ...rest, [member]: after }
  const a = appendAudit({ ...state, ai_member_limits: limits }, state.team!.id, ctx, op, `AI limit of ${member}: ${before === null ? "the team default" : `${before} USD`} -> ${after === null ? "the team default" : `${after} USD`}`, { member, before, after }, "billing")
  return { ok: true, state: a.state, value: { member, limit_usd: after }, outbox: [a.outbox] }
}

/** team.member.remove: the member's personal limit leaves with them (the removal's audit names it). */
export const withoutMemberLimit = (state: TeamState, user: string): { state: TeamState; cleared: number | null } => {
  const own = state.ai_member_limits?.[user]
  if (typeof own !== "number") return { state, cleared: null }
  const { [user]: _gone, ...rest } = state.ai_member_limits ?? {}
  return { state: { ...state, ai_member_limits: rest }, cleared: own }
}

/**
 * The limit a code run's member gets (TeamDO.aiUserLimit): 0 for someone who is not a member now or
 * whose role holds no team.resources, so a removed or demoted member's automations stop at the next
 * start or step (review P3). Runs from before
 * attribution count as UNATTRIBUTED_USER and get the team default.
 */
export const codeRunLimit = (state: TeamState | undefined, rows: RowsWithScan | undefined, user: string): number => {
  if (user === "unattributed") return memberLimit(state, user).limit_usd
  // A member whose role no longer uses the team (guest, billing only) gets 0 too (review P3).
  return state && roleHas(memberOf(state, rows, user)?.role, "team.resources") ? memberLimit(state, user).limit_usd : 0
}

const PAGE = 200

/**
 * team.ai_limit.get, TeamDO's half (the Worker adds spend from UsageMeterDO): the caller's own
 * limit, and for billing.manage every member's limit, a page at a time. A guest reads nothing.
 */
export const aiLimitViewOf = (state: TeamState | undefined, rows: RowsWithScan | undefined, entity: string, user: string, cursor: string | undefined, person = true):
  | { ok: true; team: string; default_usd: number; is_default: boolean; me: { user: string; display_name: string; role: string; limit_usd: number; source: LimitSource }; members?: Array<{ user: string; display_name: string; role: string; limit_usd: number; source: LimitSource }>; next_cursor?: string | null }
  | { ok: false; code: string; message: string } => {
  if (!state?.team || state.team.id !== entity || state.team.deleted_at !== undefined) return { ok: false, code: "auth.forbidden", message: "not a member of this team" }
  const self = memberOf(state, rows, user)
  if (!self) return { ok: false, code: "auth.forbidden", message: "not a member of this team" }
  // Every member's spend is for a person's session of a billing.manage member only; an agent or an install reads its own line (review P3).
  const admin = person && mayManageBilling(self.role)
  if (!admin && !roleHas(self.role, "team.resources")) return { ok: false, code: "auth.forbidden", message: `the ${self.role} role may not read AI limits` }
  const team = state.ai_user_monthly_limit_usd
  const view = (m: { user: string; display_name: string; role: string }) => ({ user: m.user, display_name: m.display_name, role: m.role, ...memberLimit(state, m.user) })
  const base = { ok: true as const, team: entity, default_usd: typeof team === "number" ? team : INFERENCE_USER_MONTHLY_DEFAULT_USD, is_default: typeof team !== "number", me: view(self) }
  if (!admin) return base
  const page = listMembers(state, rows, cursor, PAGE)
  return { ...base, members: page.items.map(view), next_cursor: page.next }
}
