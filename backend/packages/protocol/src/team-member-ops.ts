import { Schema } from "effect"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"
import { DisplayName, TeamId, TeamRole, UserId } from "./schemas.ts"

/**
 * Shared (Stack) teams mirrored into TeamDO (cx-3bi.43; plans/cmux-next/enterprise.md "shared
 * teams"). Stack's team webhooks reach TeamDO, which asks Stack for the current team and
 * membership and commits the answer through these ops. Only TeamDO's own submit (identity
 * system:team) may call them. Not exported to the catalog.
 */
const internal = (name: string, params: Schema.Top, docs: string): CloudOpDef =>
  ({
    name,
    owner: "cloud:TeamDO",
    class: "mutation",
    risk: "mutate-shared",
    target: "team",
    principals: ["system"],
    params,
    result: Schema.Unknown,
    errors: [],
    docs,
    cli: { path: "", visible: false },
    mcp: { expose: "never", group: "internal" }
  }) as CloudOpDef

export const TeamStackMirrorParams = Schema.Struct({
  team: TeamId,
  /** The Stack team id (a UUID); the cmux id is derived from it (stackTeamIdFor). */
  stack_team: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(64)),
  display_name: Schema.optionalKey(DisplayName),
  /** Stack no longer has the team: the mirror is a tombstone for good (Stack never reuses an id). */
  deleted: Schema.optionalKey(Schema.Literal(true))
})

export const TeamMemberProvisionParams = Schema.Struct({
  user: UserId,
  /** The role Stack's team permissions map to (team-roles.ts stackRole, cx-3bi.4); re-read on every sync, so a change in Stack changes it here. */
  role: TeamRole,
  source: Schema.Literal("stack"),
  display_name: DisplayName
})

/** The owner count of a Stack team from before owner_count existed, counted once by TeamDO (re-review P3). */
export const TeamOwnerCountInitParams = Schema.Struct({ count: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)) })

export const teamMemberInternalOps: ReadonlyArray<CloudOpDef> = [
  internal("team.owner_count.init", TeamOwnerCountInitParams, "Internal: sets a Stack team's owner count once (heads from before it was kept); a count of 0 records that the team has no owner."),
  internal("team.stack_mirror", TeamStackMirrorParams, "Internal: TeamDO mirrors a Stack team (create, rename, delete) as Stack answers it now."),
  internal("team.member.provision", TeamMemberProvisionParams, "Internal: adds a member Stack lists, or sets an existing member's role to the one Stack's permissions give now; removal is team.member.remove.")
]

/** One audit record as TeamDO keeps it (spec/enterprise.md 6); `category` billing marks seat and billing changes (spec H12). */
export const TeamAuditEntry = Schema.Struct({
  n: Schema.Int,
  op: Schema.String,
  actor: Schema.String,
  at: Schema.Int,
  category: Schema.Literals(["admin", "billing"]),
  summary: Schema.String,
  detail: Schema.Unknown,
  hash: Schema.String
}).annotate({ identifier: "TeamAuditEntry" })

/**
 * Removes a member from a shared team (cx-3bi.4, spec H12): owners remove anyone but an owner;
 * admins remove members, guests and billing members, never an admin. A Stack team's member is
 * removed in Stack first, so the next sync agrees. Runs through POST /v1/ops only (Stack call).
 */
export const TeamMembersRemove = def({
  name: "team.members.remove",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "destructive",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({ user: UserId }),
  result: Schema.Struct({ user: UserId, removed: Schema.Boolean }),
  errors: [...mutationErrors, "selector.not_found", "owner.unreachable"],
  docs: "Remove a member from the team. Owners remove admins; admins remove members, guests and billing members; an owner must be demoted in Stack first. In a person's session only.",
  cli: { path: "team members remove", visible: true },
  mcp: { expose: "never", group: "team" }
})

/** Pages the team's audit records, newest first: owners and admins read every record, the billing role only billing records (spec H12). */
export const TeamAuditList = def({
  name: "team.audit.list",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({
    team: Schema.optionalKey(TeamId),
    /** The `n` to page below (the previous page's next_cursor). */
    before: Schema.optionalKey(Schema.Int.check(Schema.isGreaterThanOrEqualTo(1))),
    limit: Schema.optionalKey(Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(1), Schema.isLessThanOrEqualTo(200)))
  }),
  result: Schema.Struct({ team: TeamId, entries: Schema.Array(TeamAuditEntry), next_cursor: Schema.NullOr(Schema.Int), revision: Schema.String }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "Read the team's audit records, newest first (owners and admins: all; billing: billing records only).",
  cli: { path: "team audit", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const teamMemberOps = [TeamMembersRemove, TeamAuditList] as const
