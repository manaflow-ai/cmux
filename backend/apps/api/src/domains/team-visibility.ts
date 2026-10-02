import type { EventFrame, Principal } from "@cmux/ownership"
import type { TeamState } from "./team.ts"

/**
 * What a TeamDO subscriber may see (review MED, decision c). Every member
 * reads the team policy (clients apply its device keys); only owners and
 * admins see policy history, enrollment tokens, every managed device and the
 * audit chain head. A member sees their own managed installs.
 */
const isAdmin = (state: TeamState, p: Principal) => {
  const role = p.user ? state.members[p.user]?.role : undefined
  return role === "owner" || role === "admin"
}

export const teamSubscriberView = (state: TeamState, principal: Principal): TeamState => {
  if (isAdmin(state, principal)) return state
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
  return { ...rest, managed_devices: own, device_status: ownStatus }
}

/** The seed bumps the policy version, so members see it; the sync ack is admin-only bookkeeping. */
const ADMIN_ONLY_PREFIXES = ["team.enrollment_token.", "team.device.", "team.policy.integration_synced"]

export const teamEventVisible = (state: TeamState, event: EventFrame, principal: Principal): boolean => {
  if (!ADMIN_ONLY_PREFIXES.some((p) => event.op.startsWith(p))) return true
  if (isAdmin(state, principal)) return true
  // A member sees events about their own devices.
  return event.op.startsWith("team.device.") && event.actor.user !== undefined && event.actor.user === principal.user
}
