import { roleOf, type RowsWithScan } from "./domains/team-members.ts"
import { currentPolicy, enforcedOn, ssoServable, type PolicyValues } from "./domains/team-policy.ts"
import { connectionForDomain } from "./domains/team-sso.ts"
import type { TeamState } from "./domains/team.ts"

/** TeamDO.signInRules result (policy-gate.ts). */
export interface SignInRules {
  readonly sso_required: boolean
  readonly minimum_version: string | null
  readonly allowed_classes: ReadonlyArray<string>
}

/**
 * Sign-in rules of a team for one user (enterprise P17-4): whether a Stack session needs this
 * team's SSO (sso.enforce with mode enforced, while an active connection serves a verified domain;
 * owners exempt unless sso.enforceForOwners), the minimum client version, and the agent classes
 * grants may be minted for. `user` need not be a member: the Worker also asks the team that owns
 * the user's email `domain` (policy-gate.ts), which binds only while a connection serves that
 * domain.
 */
export const signInRulesOf = (state: TeamState, rows: RowsWithScan | undefined, user: string, domain?: string): SignInRules => {
  const policy = currentPolicy(state).values as PolicyValues
  const values = policy as Record<string, { value: unknown } | undefined>
  const role = roleOf(state, rows, user)
  // Bound by its email domain: only while an active connection serves that very domain, or its user could never sign in.
  const servable = domain === undefined ? ssoServable(state) : connectionForDomain(state, domain) !== undefined
  const enforce = enforcedOn(policy, "sso.enforce") && servable
  const owners = enforcedOn(policy, "sso.enforceForOwners")
  const min = values["updates.minimumVersion"]?.value
  const classes = values["agents.allowedClasses"]?.value
  return {
    sso_required: enforce && (role !== "owner" || owners),
    minimum_version: typeof min === "string" ? min : null,
    allowed_classes: Array.isArray(classes) ? (classes as Array<string>) : ["mux", "agent", "run"]
  }
}
