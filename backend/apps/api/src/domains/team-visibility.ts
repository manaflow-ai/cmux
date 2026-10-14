import type { EventFrame, Principal, RowReader } from "@cmux/ownership"
import { can } from "./team-members.ts"
import type { TeamState } from "./team.ts"

/**
 * What a TeamDO subscriber may see (review MED, decision c). Every member
 * reads the team policy (clients apply its device keys); only owners and
 * admins see policy history, enrollment tokens, every managed device and the
 * audit chain head. A member sees their own managed installs.
 */
const isAdmin = (state: TeamState, p: Principal, rows?: RowReader) => can(state, rows, p.user, "team.manage")
const canManageBilling = (state: TeamState, p: Principal, rows?: RowReader) => can(state, rows, p.user, "billing.manage")

export const teamSubscriberView = (state: TeamState, principal: Principal, rows?: RowReader): TeamState => {
  if (isAdmin(state, principal, rows)) return state
  const {
    policy_history: _history,
    enrollment_tokens: _tokens,
    audit_head: _head,
    audit_count: _count,
    integration_seeded: _seeded,
    integration_synced_hash: _hash,
    integration_synced_version: _version,
    sso_connections: _sso,
    domains: _domains,
    ...rest
  } = state
  const own = Object.fromEntries(Object.entries(state.managed_devices ?? {}).filter(([, d]) => d.user === principal.user))
  const ownStatus = Object.fromEntries(Object.entries(state.device_status ?? {}).filter(([, d]) => d.user === principal.user))
  // Personal AI limits (cx-ds09i review P2): a member without billing.manage sees only their own.
  const ownLimit = principal.user !== undefined && typeof state.ai_member_limits?.[principal.user] === "number" ? { [principal.user]: state.ai_member_limits[principal.user]! } : {}
  return { ...rest, managed_devices: own, device_status: ownStatus, ...(state.ai_member_limits || canManageBilling(state, principal, rows) ? { ai_member_limits: canManageBilling(state, principal, rows) ? (state.ai_member_limits ?? {}) : ownLimit } : {}) }
}

/** The seed bumps the policy version, so members see it; the sync ack is admin-only bookkeeping. */
const ADMIN_ONLY_PREFIXES = ["team.enrollment_token.", "team.device.", "team.policy.integration_synced", "sso.", "domain."]

export const teamEventVisible = (state: TeamState, event: EventFrame, principal: Principal, rows?: RowReader): boolean => {
  // A personal AI limit change reaches billing.manage members and the member it names, nobody else (cx-ds09i review P2).
  if (event.op === "team.ai_limit.member.set") return canManageBilling(state, principal, rows) || (principal.user !== undefined && (event.params as { member?: unknown } | null)?.member === principal.user)
  if (!ADMIN_ONLY_PREFIXES.some((p) => event.op.startsWith(p))) return true
  if (isAdmin(state, principal, rows)) return true
  // A member sees events about their own devices.
  return event.op.startsWith("team.device.") && event.actor.user !== undefined && event.actor.user === principal.user
}
