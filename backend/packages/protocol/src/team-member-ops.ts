import { Schema } from "effect"
import type { CloudOpDef } from "./op-def.ts"
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
