import { Schema } from "effect"
import { def, type CloudOpDef } from "./op-def.ts"
import { DisplayName, TeamId, UserId } from "./schemas.ts"

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
  /** Stack membership gives `member`; other roles come from team roles (cx-3bi.4). */
  role: Schema.Literals(["owner", "admin", "member"]),
  source: Schema.Literal("stack"),
  display_name: DisplayName
})

export const teamMemberInternalOps: ReadonlyArray<CloudOpDef> = [
  internal("team.stack_mirror", TeamStackMirrorParams, "Internal: TeamDO mirrors a Stack team (create, rename, delete) as Stack answers it now."),
  internal("team.member.provision", TeamMemberProvisionParams, "Internal: adds a member Stack lists (an existing member keeps their role); removal is team.member.remove.")
]

/** One team a person may act in (x-cmux-team), as user.teams.list answers it (cx-5xew). */
export const UserTeam = Schema.Struct({
  id: TeamId,
  /** The team's name in TeamDO (Stack's name for a shared team); empty for a personal team TeamDO does not have yet. */
  display_name: Schema.String,
  kind: Schema.Literals(["personal", "stack"]),
  /** The caller's role, as TeamDO answers it now. */
  role: Schema.Literals(["owner", "admin", "member"])
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
    /** True when a team could not be checked now (its TeamDO did not answer) or the user is in more than USER_TEAMS_LIST_MAX shared teams: that team is left out. */
    incomplete: Schema.Boolean,
    revision: Schema.String
  }),
  errors: ["auth.unauthenticated", "auth.forbidden", "owner.unreachable"],
  docs: "List the teams the caller may act in with x-cmux-team: the personal team and every shared team whose TeamDO confirms the membership now. The UserDO team index is only the candidate list; an entry TeamDO does not confirm is left out.",
  cli: { path: "account teams", visible: true },
  mcp: { expose: "never", group: "account" }
})
