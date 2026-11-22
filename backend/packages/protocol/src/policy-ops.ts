import { Schema } from "effect"
import { def, mutationErrors } from "./op-def.ts"
import { PolicyChange, TeamPolicy, TeamPolicyVersion } from "./policy.ts"
import { TeamId } from "./schemas.ts"

/** Team policy ops (spec/enterprise.md section 4.3), owner TeamDO. */
const PolicyVersionNumber = Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0))
const PolicyReason = Schema.String.check(Schema.isMaxLength(500))

export const TeamPolicyGet = def({
  name: "team.policy.get",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team_policy",
  principals: ["session", "install"],
  params: Schema.Struct({ version: Schema.optionalKey(PolicyVersionNumber) }),
  result: Schema.Struct({
    team: TeamId,
    policy: TeamPolicy,
    /** ConnectionDO holds an SSO or MDM lock that overrides the integration keys (reported, E2). */
    integration_managed_by: Schema.NullOr(Schema.Literals(["sso", "mdm"])),
    revision: Schema.String
  }),
  errors: ["auth.unauthenticated", "auth.forbidden", "selector.not_found"],
  docs: "Read the team policy (current or a retained past version). Every member may read it; clients apply its device-scoped keys.",
  cli: { path: "team policy get", visible: true },
  mcp: { expose: "opt_in", group: "team" }
})

export const TeamPolicyHistory = def({
  name: "team.policy.history",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team_policy",
  principals: ["session", "install"],
  params: Schema.Struct({ limit: Schema.optionalKey(Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(1), Schema.isLessThanOrEqualTo(20))) }),
  result: Schema.Struct({ team: TeamId, versions: Schema.Array(TeamPolicyVersion), revision: Schema.String }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "List the last 20 team policy versions, newest first, with actor, reason and changed keys (owners and admins).",
  cli: { path: "team policy history", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const TeamPolicyUpdate = def({
  name: "team.policy.update",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team_policy",
  principals: ["session", "install"],
  params: Schema.Struct({
    changes: Schema.Array(PolicyChange).check(Schema.isMinLength(1), Schema.isMaxLength(64)),
    expected_version: PolicyVersionNumber,
    reason: Schema.optionalKey(PolicyReason)
  }),
  result: TeamPolicy,
  errors: [...mutationErrors, "policy.invalid"],
  docs: "Set or clear team policy keys as one new version (owners and admins). expected_version is the compare-and-swap; a stale version fails with revision.conflict.",
  cli: { path: "team policy set", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const TeamPolicyRollback = def({
  name: "team.policy.rollback",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team_policy",
  principals: ["session", "install"],
  params: Schema.Struct({ version: PolicyVersionNumber, expected_version: PolicyVersionNumber, reason: Schema.optionalKey(PolicyReason) }),
  result: TeamPolicy,
  errors: [...mutationErrors, "selector.not_found", "policy.invalid"],
  docs: "Apply a retained past version's values as a new version (owners and admins).",
  cli: { path: "team policy rollback", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const TeamIntegrationReleaseLock = def({
  name: "team.integration.release_lock",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team_policy",
  principals: ["session"],
  params: Schema.Struct({ reason: Schema.optionalKey(PolicyReason) }),
  result: Schema.Struct({ released: Schema.Literals(["sso", "mdm"]) }),
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Release the SSO or MDM lock on the team's integration policy (owners and admins; audited). The team policy then applies again.",
  cli: { path: "team integration release-lock", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const policyOps = [TeamIntegrationReleaseLock, TeamPolicyGet, TeamPolicyHistory, TeamPolicyUpdate, TeamPolicyRollback] as const
