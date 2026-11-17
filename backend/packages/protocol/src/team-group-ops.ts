import { Schema } from "effect"
import { def, mutationErrors } from "./op-def.ts"
import { UserId } from "./schemas.ts"
import { isPattern } from "./json-checks.ts"

/**
 * Cloud groups (plans/cmux-next/cloud-groups-DESIGN.md, slice 1): a sidebar group whose record lives
 * in the team's TeamDO, not on a Mac. TeamDO mints the id (`grp_` + 20 hex, never from a client), so a
 * `cmux://group/<id>` link resolves on every Mac, the iPhone and every Chief, also while the Mac that
 * made it sleeps. Contents stay at their home: each workspace row names where it runs (placement).
 *
 * Slice 1: the creator is the group's only member (role owner). Members and roles come in slice 3.
 */
export const GroupId = Schema.String.check(isPattern(/^grp_[a-z0-9]{20}$/)).annotate({
  identifier: "GroupId",
  description: "A cloud group, minted by TeamDO (grp_ + 20 lowercase hex)."
})

/** A cmux-next workspace id (`ws_` + hex or base32), the id the daemon gave it. */
export const GroupWorkspaceId = Schema.String.check(isPattern(/^ws_[A-Za-z0-9]{8,64}$/)).annotate({ identifier: "GroupWorkspaceId" })

export const GroupName = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(80))

/** Where a workspace runs: this Mac or another enrolled host (`local`/`mini`, by host id or name), or a Cloud VM (`cloud_vm`, by machine id). */
export const GroupPlacement = Schema.Struct({
  kind: Schema.Literals(["local", "mini", "cloud_vm"]),
  host: Schema.optionalKey(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(128))),
  machine: Schema.optionalKey(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(128)))
}).annotate({ identifier: "GroupPlacement" })

export const GroupRole = Schema.Literals(["owner", "edit", "view"])

export const CloudGroup = Schema.Struct({
  id: GroupId,
  name: GroupName,
  created_by: UserId,
  created_at: Schema.Int,
  archived: Schema.Boolean,
  default_placement: Schema.Literals(["local", "mini", "cloud_vm"]),
  item_count: Schema.Int,
  /** The caller's role in this group. */
  role: GroupRole
}).annotate({ identifier: "CloudGroup" })

export const CloudGroupItem = Schema.Struct({
  workspace: GroupWorkspaceId,
  title: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(200))),
  placement: GroupPlacement,
  position: Schema.Int,
  added_by: UserId,
  added_at: Schema.Int
}).annotate({ identifier: "CloudGroupItem" })

const DefaultPlacement = Schema.Literals(["local", "mini", "cloud_vm"])

export const GroupCreate = def({
  name: "group.create",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-own",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({ name: GroupName, default_placement: Schema.optionalKey(DefaultPlacement) }),
  result: CloudGroup,
  errors: [...mutationErrors],
  docs: "Make a cloud group: a sidebar group whose record lives in cmux Cloud, so its link (cmux://group/<id>) opens on every Mac, iPhone and Chief, also while your Mac sleeps. The server picks the id; read it back with group.get or group.list before you link it.",
  cli: { path: "group cloud create", visible: true },
  mcp: { expose: "default", group: "groups" }
})

export const GroupRename = def({
  name: "group.rename",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-own",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({ group: GroupId, name: GroupName }),
  result: CloudGroup,
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Rename a cloud group (its owner only).",
  cli: { path: "group cloud rename", visible: true },
  mcp: { expose: "default", group: "groups" }
})

export const GroupAddWorkspace = def({
  name: "group.add_workspace",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-own",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({
    group: GroupId,
    workspace: GroupWorkspaceId,
    placement: GroupPlacement,
    title: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(200)))
  }),
  result: CloudGroupItem,
  errors: [...mutationErrors, "selector.not_found", "conflict"],
  docs: "Put a workspace in a cloud group and record where it runs (placement: local, mini or cloud_vm). A workspace is in at most one cloud group; adding it again updates its placement and title. The group's owner only.",
  cli: { path: "group cloud add", visible: true },
  mcp: { expose: "default", group: "groups" }
})

export const GroupArchive = def({
  name: "group.archive",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-own",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({ group: GroupId }),
  result: CloudGroup,
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Archive a cloud group (its owner only). The id stays; links to it still open, read-only.",
  cli: { path: "group cloud archive", visible: true },
  mcp: { expose: "default", group: "groups" }
})

export const GroupGet = def({
  name: "group.get",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({ group: GroupId }),
  result: Schema.Struct({ group: CloudGroup, items: Schema.Array(CloudGroupItem), link: Schema.String, web_link: Schema.String }),
  errors: ["auth.unauthenticated", "auth.forbidden", "selector.not_found"],
  docs: "One cloud group with its workspaces (each with its placement) and its links. Link a group only by an id read back here or from group.list.",
  cli: { path: "group cloud get", visible: true },
  mcp: { expose: "default", group: "groups" }
})

export const GroupList = def({
  name: "group.list",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({
    cursor: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(128))),
    limit: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 200 }))),
    include_archived: Schema.optionalKey(Schema.Boolean)
  }),
  result: Schema.Struct({ team: Schema.String, groups: Schema.Array(CloudGroup), next_cursor: Schema.NullOr(Schema.String) }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "The cloud groups you are a member of, in id order. Archived groups only with include_archived.",
  cli: { path: "group cloud list", visible: true },
  mcp: { expose: "default", group: "groups" }
})

/** One member of a cloud group (cloud-groups-DESIGN.md 6.1): owner manages members; edit may change rows; view reads. */
export const CloudGroupMember = Schema.Struct({
  user: UserId,
  role: GroupRole,
  /** The member's name in the team directory; null once they left the team (they keep no access). */
  display_name: Schema.NullOr(Schema.String),
  /** False once they left the team or became a guest: the group answers them nothing. */
  active: Schema.Boolean
}).annotate({ identifier: "CloudGroupMember" })

export const GroupMemberSet = def({
  name: "group.members.set",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({ group: GroupId, user: UserId, role: GroupRole }),
  result: Schema.Struct({ group: GroupId, members: Schema.Array(CloudGroupMember) }),
  errors: [...mutationErrors, "selector.not_found", "group.member_not_in_team", "group.last_owner"],
  docs: "Add a team member to a cloud group, or change their role (owner, edit or view). The group's owners only; only members of the team who can use its resources (not guests) can be added. The last owner cannot be demoted.",
  cli: { path: "group cloud member set", visible: true },
  mcp: { expose: "default", group: "groups" }
})

export const GroupMemberRemove = def({
  name: "group.members.remove",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({ group: GroupId, user: UserId }),
  result: Schema.Struct({ group: GroupId, members: Schema.Array(CloudGroupMember) }),
  errors: [...mutationErrors, "selector.not_found", "group.last_owner"],
  docs: "Remove someone from a cloud group (its owners; any member may remove themselves). The last owner cannot leave. Their access ends with this op.",
  cli: { path: "group cloud member remove", visible: true },
  mcp: { expose: "default", group: "groups" }
})

export const GroupMembersList = def({
  name: "group.members.list",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({ group: GroupId }),
  result: Schema.Struct({ group: GroupId, members: Schema.Array(CloudGroupMember) }),
  errors: ["auth.unauthenticated", "auth.forbidden", "selector.not_found"],
  docs: "A cloud group's members and their roles (any member of the group reads it).",
  cli: { path: "group cloud member list", visible: true },
  mcp: { expose: "default", group: "groups" }
})

/** Members one group holds; more is refused, never truncated. */
export const GROUP_MAX_MEMBERS = 200

export const GROUP_LINK_PREFIX = "cmux://group/"
/** The hand-off page (API Worker GET /g/<id>): it carries no group data, only the cmux:// link, so any id works on it. */
export const GROUP_WEB_LINK_PREFIX = "https://cloud-api.cmux.dev/g/"

export const teamGroupOps = [GroupCreate, GroupRename, GroupAddWorkspace, GroupArchive, GroupGet, GroupList, GroupMemberSet, GroupMemberRemove, GroupMembersList] as const
