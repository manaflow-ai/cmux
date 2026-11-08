import { Schema } from "effect"
import { def, mutationErrors } from "./op-def.ts"
import { TeamId, UserId } from "./schemas.ts"
import { isPattern } from "./json-checks.ts"

/**
 * Team-visible Cloud sessions (cloud multiplayer, lane D): every Cloud workspace and chat of a team,
 * listed for each member of the team (Conductor Cloud's Home: "browse everyone's work"), with who
 * made it (owner), who it is assigned to (assignee), where it runs (vm), its status, last activity,
 * followers and who has it open now (viewers).
 *
 * The record lives in the team's TeamDO, so the list answers while the owner's Mac sleeps. The owner's
 * app (or the VM's daemon, signed in as the owner) publishes each session it runs; a publish never
 * changes owner, assignee, archived or followers. A session is addressed as `cloud:<team>/<vm>/<session>`
 * (contract C5) and linked as `cmux://cloud/session/<team>/<vm>/<session>` (a chat) or
 * `cmux://cloud/workspace/<team>/<vm>/<workspace>` (a workspace).
 *
 * Who may do what (checked in TeamDO, never in a client):
 * - read, follow, mark viewing: any member with the `team.resources` grant (owner, admin, member);
 *   guests and billing members do not see the team's Cloud work, and a person removed from the team
 *   is refused on the next call (access is revoked live, no cache).
 * - reassign, archive: the session's owner, its assignee, or a team owner or admin (`team.manage`).
 * - publish, remove: the session's owner or assignee (remove also `team.manage`).
 * - follow is refused for a session assigned to you (it is already under "Assigned to me").
 */

/** A Cloud machine id (`vm_` + 20 lowercase hex, CloudDO's MachineId; older records `vm-…`). */
export const CloudSessionVm = Schema.String.check(isPattern(/^vm[_-][A-Za-z0-9]{1,64}$/)).annotate({
  identifier: "CloudSessionVm",
  description: "The Cloud machine the session runs on."
})
/** An acpmux chat session id or a VM daemon's workspace id (`ws_…`). */
export const CloudSessionId = Schema.String.check(isPattern(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/)).annotate({
  identifier: "CloudSessionId",
  description: "The chat's acpmux session id, or the workspace's id on its VM."
})
export const CloudSessionKind = Schema.Literals(["workspace", "chat"]).annotate({ identifier: "CloudSessionKind" })
/**
 * Where the session's machine is: `running` (reachable), `asleep` (paused or idle-paused; files and
 * chat history are kept), `waking` (a resume is on its way), `unresponsive` (failed or unreachable),
 * `gone` (the machine was deleted).
 */
export const CloudSessionMachineState = Schema.Literals(["running", "asleep", "waking", "unresponsive", "gone"]).annotate({ identifier: "CloudSessionMachineState" })
/** What the session's agent is doing: `working` (a turn runs), `needs_attention` (waits on a person), `idle`. */
export const CloudSessionActivity = Schema.Literals(["working", "needs_attention", "idle"]).annotate({ identifier: "CloudSessionActivity" })

const Title = Schema.String.check(Schema.isMaxLength(200))
const Harness = Schema.String.check(isPattern(/^[a-z0-9-]{1,64}$/))
const SessionRef = { vm: CloudSessionVm, session: CloudSessionId }

export const CloudSessionView = Schema.Struct({
  /** `cloud:<team>/<vm>/<session>` (C5). */
  key: Schema.String,
  team: TeamId,
  vm: CloudSessionVm,
  session: CloudSessionId,
  kind: CloudSessionKind,
  /** A chat's workspace on the VM, when known. */
  workspace: Schema.optionalKey(CloudSessionId),
  title: Title,
  harness: Schema.optionalKey(Harness),
  /** Who made it and whose plan its turns spend (the session owner). Never changes. */
  owner: UserId,
  owner_name: Schema.NullOr(Schema.String),
  /** Who is responsible for it now (Reassign to). Starts as the owner. */
  assignee: UserId,
  /** Null when the assignee is no longer a member of the team. */
  assignee_name: Schema.NullOr(Schema.String),
  machine_state: CloudSessionMachineState,
  activity: CloudSessionActivity,
  last_activity_at: Schema.Int,
  created_at: Schema.Int,
  archived: Schema.Boolean,
  /** Followers who are still members (at most 20, the caller's first when following). */
  followers: Schema.Array(UserId),
  follower_count: Schema.Int,
  /** Whether the caller follows it. */
  following: Schema.Boolean,
  /** Whether it is assigned to the caller. */
  assigned_to_you: Schema.Boolean,
  /** Members who had it open in the last 90 s (at most 20). */
  viewers: Schema.Array(UserId),
  /** What the caller may change (the server checks again on each op). */
  can_reassign: Schema.Boolean,
  can_archive: Schema.Boolean,
  /** `cmux://cloud/session/…` for a chat, `cmux://cloud/workspace/…` for a workspace. */
  link: Schema.String
}).annotate({ identifier: "CloudSessionView" })

const sessionErrors = ["cloud_session.not_found"]

export const CloudSessionPublish = def({
  name: "team.cloud.session.publish",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-own",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({
    ...SessionRef,
    kind: CloudSessionKind,
    title: Title,
    workspace: Schema.optionalKey(CloudSessionId),
    harness: Schema.optionalKey(Harness),
    machine_state: CloudSessionMachineState,
    activity: CloudSessionActivity,
    /** Epoch ms; the stored value only moves forward. */
    last_activity_at: Schema.Int
  }),
  result: CloudSessionView,
  errors: [...mutationErrors, ...sessionErrors, "cloud_session.not_yours"],
  docs: "Publish one of your Cloud workspaces or chats to your team (title, machine state, activity). The first publish makes you its owner and assignee; later ones by its owner or assignee update it. A publish never changes the assignee, followers or archived.",
  cli: { path: "cloud team publish", visible: false },
  mcp: { expose: "never", group: "cloud" }
})

export const CloudSessionRemove = def({
  name: "team.cloud.session.remove",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct(SessionRef),
  result: Schema.Struct({ removed: Schema.Boolean }),
  errors: [...mutationErrors, "cloud_session.not_yours"],
  docs: "Take a closed Cloud workspace or chat off the team's list (its owner or assignee, or a team owner or admin). Its followers stop following it.",
  cli: { path: "cloud team remove", visible: false },
  mcp: { expose: "never", group: "cloud" }
})

export const CloudSessionFollow = def({
  name: "team.cloud.session.follow",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-own",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({ ...SessionRef, follow: Schema.Boolean }),
  result: CloudSessionView,
  errors: [...mutationErrors, ...sessionErrors, "cloud_session.assigned_to_you"],
  docs: "Follow (or stop following) a teammate's Cloud workspace or chat: it shows under Following in your sidebar. A session assigned to you cannot be followed.",
  cli: { path: "cloud follow", visible: true },
  mcp: { expose: "default", group: "cloud" }
})

export const CloudSessionReassign = def({
  name: "team.cloud.session.reassign",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({ ...SessionRef, to: UserId }),
  result: CloudSessionView,
  errors: [...mutationErrors, ...sessionErrors, "cloud_session.assignee_not_member"],
  docs: "Reassign a Cloud workspace or chat to another member of the team (its assignee, its owner, or a team owner or admin). Followers keep following; the previous assignee follows it; turns still spend the owner's plan.",
  cli: { path: "cloud reassign", visible: true },
  mcp: { expose: "default", group: "cloud" }
})

export const CloudSessionArchive = def({
  name: "team.cloud.session.archive",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({ ...SessionRef, archived: Schema.Boolean }),
  result: CloudSessionView,
  errors: [...mutationErrors, ...sessionErrors],
  docs: "Archive (or restore) a Cloud workspace or chat on the team's list (its assignee, its owner, or a team owner or admin). Archived sessions show only under Archived.",
  cli: { path: "cloud archive-session", visible: true },
  mcp: { expose: "default", group: "cloud" }
})

export const CloudSessionViewing = def({
  name: "team.cloud.session.viewing",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-own",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({ ...SessionRef, viewing: Schema.Boolean }),
  result: Schema.Struct({ viewing: Schema.Boolean, viewers: Schema.Array(UserId) }),
  errors: [...mutationErrors, ...sessionErrors],
  docs: "Say you have a Cloud workspace or chat open (or closed it). Teammates see you among its viewers for 90 s after the last call; the app repeats it every 60 s while it shows.",
  cli: { path: "cloud team viewing", visible: false },
  mcp: { expose: "never", group: "cloud" }
})

export const CloudSessionScope = Schema.Literals(["mine", "team", "following"]).annotate({ identifier: "CloudSessionScope" })

export const CloudSessionList = def({
  name: "team.cloud.session.list",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({
    /** `mine`: assigned to you; `team`: everyone's (or `by`'s); `following`: what you follow. Default `team`. */
    scope: Schema.optionalKey(CloudSessionScope),
    /** Only sessions assigned to this member (`team` scope). */
    by: Schema.optionalKey(UserId),
    /** Archived sessions only (default: only the ones not archived). */
    archived: Schema.optionalKey(Schema.Boolean),
    cursor: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(256))),
    limit: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 200 })))
  }),
  result: Schema.Struct({ team: TeamId, sessions: Schema.Array(CloudSessionView), next_cursor: Schema.NullOr(Schema.String) }),
  errors: ["auth.unauthenticated", "auth.forbidden", "validation.invalid"],
  docs: "The team's Cloud workspaces and chats, most recently active first: yours (mine), everyone's (team, optionally by one member) or the ones you follow (following); archived only with archived=true.",
  cli: { path: "cloud team-sessions", visible: true },
  mcp: { expose: "default", group: "cloud" }
})

export const CloudSessionGet = def({
  name: "team.cloud.session.get",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct(SessionRef),
  result: Schema.Struct({ session: CloudSessionView }),
  errors: ["auth.unauthenticated", "auth.forbidden", "team.not_member", "selector.not_found"],
  docs: "One Cloud workspace or chat of the team, for a member opening its link. A person outside the team is refused auth.forbidden (or team.not_member); a closed or removed one is selector.not_found.",
  cli: { path: "cloud team-session", visible: true },
  mcp: { expose: "default", group: "cloud" }
})

export const CLOUD_SESSION_LINK_PREFIX = "cmux://cloud/session/"
export const CLOUD_WORKSPACE_LINK_PREFIX = "cmux://cloud/workspace/"

export const teamCloudSessionOps = [CloudSessionPublish, CloudSessionRemove, CloudSessionFollow, CloudSessionReassign, CloudSessionArchive, CloudSessionViewing, CloudSessionList, CloudSessionGet] as const
