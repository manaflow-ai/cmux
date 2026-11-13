import { Schema } from "effect"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"
import { TeamId, UserId } from "./schemas.ts"

/**
 * The team's members policy for model connections (Settings > Models, cmux-tui/docs/model-connections.md):
 * whether members may use their own connections (subscriptions, keys) for the team's Cloud threads, and
 * whether a member may choose what happens when a connection runs out. Owners and admins change it in a
 * person's session; every member reads it. TeamDO keeps it in a side table beside the shared agent keys
 * (team-models-policy.ts); it holds no secret. Enforcement in the platform route is a follow-up.
 */
export const TeamModelsPolicyState = Schema.Struct({
  team: TeamId,
  /** Whether the person asking may change it (an owner or admin, in their own session). */
  can_edit: Schema.Boolean,
  /** Members' own connections serve their Cloud threads (default true). */
  own_connections: Schema.Boolean,
  /** Members choose what a thread does when its connection runs out (default false). */
  choose_runout: Schema.Boolean,
  /** Bumped by every change; 0 while the defaults apply. */
  revision: Schema.Int,
  updated_at: Schema.NullOr(Schema.Int),
  updated_by: Schema.NullOr(UserId)
}).annotate({ identifier: "TeamModelsPolicyState" })

export const TeamModelsPolicyGet = def({
  name: "team.models_policy.get",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({ team: Schema.optionalKey(TeamId) }),
  result: TeamModelsPolicyState,
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "The team's members policy for model connections (members): whether members' own connections serve their Cloud threads, and whether they choose what happens when one runs out.",
  cli: { path: "team models-policy get", visible: false },
  mcp: { expose: "never", group: "team" }
})

export const TeamModelsPolicySet = def({
  name: "team.models_policy.set",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({
    own_connections: Schema.optionalKey(Schema.Boolean),
    choose_runout: Schema.optionalKey(Schema.Boolean)
  }),
  result: TeamModelsPolicyState,
  errors: mutationErrors,
  docs: "Change the team's members policy for model connections (owners and admins, in a person's session). A field left out keeps its value.",
  cli: { path: "team models-policy set", visible: false },
  mcp: { expose: "never", group: "team" }
})

export const teamModelsPolicyOps = [TeamModelsPolicyGet, TeamModelsPolicySet] as const

/** TeamDO's own audit record of a members policy change (the fields it set and who set them). */
export const teamModelsPolicyInternalOps: ReadonlyArray<CloudOpDef> = [
  {
    name: "team.models_policy.audit",
    owner: "cloud:TeamDO",
    class: "mutation",
    risk: "mutate-shared",
    target: "team",
    principals: ["system"],
    params: Schema.Struct({
      own_connections: Schema.Boolean,
      choose_runout: Schema.Boolean,
      revision: Schema.Int,
      by: Schema.String
    }),
    result: Schema.Unknown,
    errors: [],
    docs: "Internal: an owner or admin changed the team's members policy for model connections; audit only.",
    cli: { path: "", visible: false },
    mcp: { expose: "never", group: "internal" }
  } as CloudOpDef
]
