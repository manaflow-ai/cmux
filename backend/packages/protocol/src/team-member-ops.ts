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

/** One team a person may act in (x-cmux-team), as user.teams.list answers it (cx-5xew). */
export const UserTeam = Schema.Struct({
  id: TeamId,
  /** The team's name in TeamDO (Stack's name for a shared team); empty for a personal team TeamDO does not have yet. */
  display_name: Schema.String,
  kind: Schema.Literals(["personal", "stack"]),
  /** The caller's role, as TeamDO answers it now (cx-3bi.4: guest and billing too). */
  role: TeamRole,
  /** The team requires its SSO and this session did not sign in through it: selecting it answers auth.sso_required. */
  sso_required: Schema.Boolean
}).annotate({ identifier: "UserTeam" })

/** At most this many shared teams one user.teams.list checks (each is one TeamDO call). */
export const USER_TEAMS_LIST_MAX = 100

export const UserTeamsList = def({
  name: "user.teams.list",
  owner: "cloud:UserDO",
  class: "read",
  risk: "read",
  target: "user",
  principals: ["session"],
  params: Schema.Struct({}),
  result: Schema.Struct({
    /** The personal team first, then the shared teams by id. */
    teams: Schema.Array(UserTeam),
    /** True when a team could not be checked now (its TeamDO, or the personal team's, did not answer) or the user is in more than USER_TEAMS_LIST_MAX shared teams: that team is left out. */
    incomplete: Schema.Boolean,
    revision: Schema.String
  }),
  errors: ["auth.unauthenticated", "auth.forbidden", "owner.unreachable"],
  docs: "List the teams the caller may act in with x-cmux-team (a team not listed answers team.not_member; one with sso_required answers auth.sso_required until the person signs in with its SSO): the personal team and every shared team whose TeamDO confirms the membership now. The UserDO team index is only the candidate list; an entry TeamDO does not confirm is left out.",
  cli: { path: "account teams", visible: true },
  mcp: { expose: "never", group: "account" }
})
