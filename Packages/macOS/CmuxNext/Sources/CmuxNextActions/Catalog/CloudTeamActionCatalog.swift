/// Team Cloud sessions (cloud multiplayer, lane D): the team's Cloud chats and workspaces as every member
/// sees them (`team.cloud.session.*` in TeamDO), the `cmux://cloud/session|workspace/<team>/<vm>/<id>`
/// link (contract C5), Follow, Reassign to and Archive, and a cloud group's members (`group.members.*`).
/// The Team section's rows and buttons, the workspace and tab menus, the palette, `cmux cloud …` and its
/// MCP tools all run these actions; the handlers are CmuxNextCloudUI's CloudTeamActions.swift.
/// A session is `--session` (its `cloud:<team>/<vm>/<id>` key or its link), else the Cloud workspace or
/// chat tab the run targets, else the focused one.
nonisolated enum CloudTeamActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        var actions: [ActionDescriptor] = [
            ActionDescriptor(
                id: "cloud.team.sessions",
                title: t("action.cloud.team.sessions", "List Team Cloud Sessions"),
                description: "Lists the team's Cloud chats and workspaces, newest activity first: --scope mine (assigned to you), team (default: everyone's) or following; --by USER (assigned to that member); --archived (the archived ones instead); --limit 1-200 (default 50) and --cursor from next_cursor. Returns team, sessions [{key, vm, session, kind (chat, workspace), title, owner, owner_name, assignee, assignee_name, machine_state (running, asleep, waking, unresponsive, gone), activity (working, needs_attention, idle), last_activity_at (ms), created_at, archived, followers [USER], follower_count, following, assigned_to_you, viewers [USER] (who has it open now), can_reassign, can_archive, link}] and next_cursor. Errors: cloud.signed_out, auth.forbidden (not a member of the team, or a guest), validation.invalid, cloud.unreachable.",
                keywords: ["team", "cloud", "sessions", "workspaces", "chats", "shared", "teammates", "multiplayer"],
                category: .cloud, symbol: "person.2", arguments: [scope, by, archived, cursor, limit], cliName: "cloud team-sessions",
                surfacePlan: family
            ),
            ActionDescriptor(
                id: "cloud.team.session",
                title: t("action.cloud.team.session", "Show Team Cloud Session"),
                description: "Reads one team Cloud session (--session KEY|LINK, else the targeted or focused Cloud workspace or chat). Returns session, shaped as one row of cloud team-sessions. Errors: selector.not_found or cloud_session.not_found (closed or removed), cloud_session.not_cloud (the target is not a Cloud workspace or chat), cloud_session.invalid (--session is not a key or link), auth.forbidden or team.not_member, cloud.signed_out, cloud.unreachable.",
                keywords: ["team", "cloud", "session", "status", "who"], category: .cloud, symbol: "person.2",
                arguments: [session], targets: [.workspace, .tab], cliName: "cloud team-session", surfacePlan: family
            ),
            ActionDescriptor(
                id: "cloud.team.copyLink",
                title: t("action.cloud.team.copyLink", "Copy Cloud Session Link"),
                description: "Copies the link to a team Cloud session (--session, else the targeted or focused Cloud workspace or chat tab): cmux://cloud/workspace/TEAM/VM/WORKSPACE for a workspace, cmux://cloud/session/TEAM/VM/SESSION for a chat. Any member of the team opens it with `cmux link open`; anyone else is refused. Returns link, key (cloud:TEAM/VM/ID), kind and copied (false for a script's run, which prints it instead). Errors: cloud_session.not_cloud, cloud.signed_out.",
                keywords: ["link", "url", "copy", "share", "cloud", "team", "teammate"],
                category: .cloud, symbol: "link", surfaces: [.palette, .contextMenu],
                arguments: [session], targets: [.workspace, .tab], cliName: "cloud copy-session-link",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [
                    ActionSurfaceCatalog.p(.workspaceRow, .inspect, 406, folder: .copy),
                    ActionSurfaceCatalog.p(.tab, .inspect, 502, folder: .copy),
                ])
            ),
            ActionDescriptor(
                id: "cloud.team.follow",
                title: t("action.cloud.team.follow", "Follow"),
                description: "Follows a team Cloud session (--session, else the targeted or focused Cloud workspace or chat): it shows under Following in the Team section for you on every Mac. Following twice is a no-op. Returns session. Errors: cloud_session.assigned_to_you (your own work is already yours), cloud_session.not_found, cloud_session.not_cloud, auth.forbidden, cloud.signed_out, cloud.unreachable.",
                keywords: ["follow", "watch", "eye", "team", "cloud", "subscribe"], category: .cloud, symbol: "eye",
                surfaces: [.palette, .contextMenu], arguments: [session], targets: [.workspace, .tab], cliName: "cloud follow",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ActionSurfaceCatalog.p(.workspaceRow, .identity, 312, folder: .options)])
            ),
            ActionDescriptor(
                id: "cloud.team.unfollow",
                title: t("action.cloud.team.unfollow", "Unfollow"),
                description: "Stops following a team Cloud session (--session, else the targeted or focused one). Unfollowing one you do not follow is a no-op. Returns session. Errors: as cloud follow.",
                keywords: ["unfollow", "stop watching", "eye", "team", "cloud"], category: .cloud, symbol: "eye.slash",
                surfaces: [.palette, .contextMenu], arguments: [session], targets: [.workspace, .tab], cliName: "cloud unfollow",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ActionSurfaceCatalog.p(.workspaceRow, .identity, 313, folder: .options)])
            ),
            ActionDescriptor(
                id: "cloud.team.reassign",
                title: t("action.cloud.team.reassign", "Reassign to…"),
                description: "Moves a team Cloud session (--session, else the targeted or focused one) to another member's assigned work (--to USER, a member's user id from cloud team-members or a row's owner). Its owner (who pays for the machine) does not change; followers keep following, and the previous assignee follows it. Only its assignee, its owner or a team admin may; a turn that is running goes on. Returns session. Errors: cloud_session.not_yours, cloud_session.assignee_not_member (a guest or someone outside the team), cloud_session.not_found, auth.forbidden, cloud.signed_out, cloud.unreachable.",
                keywords: ["reassign", "assign", "hand off", "handoff", "transfer", "teammate", "team", "cloud"],
                category: .cloud, symbol: "person.crop.circle.badge.arrow.forward", surfaces: [.palette],
                arguments: [session, to], targets: [.workspace, .tab], cliName: "cloud reassign",
                // The Team section's row menu lists the members to pick (Reassign to ▸); the workspace menu has no picker.
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "cloud.team.archive",
                title: t("action.cloud.team.archive", "Archive Cloud Session"),
                description: "Archives a team Cloud session for the whole team (--session, else the targeted or focused one), or brings it back with --archived false. Its machine and files are untouched. Only its assignee, its owner or a team admin may. Returns session. Errors: cloud_session.not_yours, cloud_session.not_found, auth.forbidden, cloud.signed_out, cloud.unreachable.",
                keywords: ["archive", "unarchive", "hide", "team", "cloud"], category: .cloud, symbol: "archivebox",
                surfaces: [.palette], arguments: [session, archive], targets: [.workspace, .tab], cliName: "cloud archive-session",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "cloud.team.showSection",
                title: t("action.cloud.team.showSection", "Show Team Section"),
                description: "Adds the Team section to the bottom of the sidebar: the team's Cloud workspaces and chats under Assigned to Me, Team, Following and Archived, each with its follow (eye) toggle and a menu with Reassign To, Copy Link and Archive. A sidebar that has it already keeps the one it has. Errors: cloud.signed_out.",
                keywords: ["team", "cloud", "sidebar", "section", "sessions", "shared"], category: .cloud, symbol: "person.2",
                surfaces: [.palette], cliName: "cloud show-team-section",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "cloud.team.members",
                title: t("action.cloud.team.members", "List Team Members"),
                description: "Lists the members a team Cloud session can be reassigned to: members [{user, name, role (owner, admin, member, billing, guest), you}] of the active team, guests last. Errors: auth.forbidden, cloud.signed_out, cloud.unreachable.",
                keywords: ["team", "members", "people", "teammates"], category: .cloud, symbol: "person.3",
                cliName: "cloud team-members", surfacePlan: family
            ),
            ActionDescriptor(
                id: "cloud.group.members",
                title: t("action.cloud.group.members", "List Cloud Group Members"),
                description: "Lists a cloud group's members (--group grp_…): group and members [{user, role (owner, edit, view), display_name, active (false for someone no longer in the team)}], owners first. Errors: group.not_found, auth.forbidden, cloud.signed_out, cloud.unreachable.",
                keywords: ["group", "members", "people", "roles"], category: .cloud, symbol: "person.3",
                arguments: [group], cliName: "cloud group-members", surfacePlan: family
            ),
            ActionDescriptor(
                id: "cloud.group.memberSet",
                title: t("action.cloud.group.memberSet", "Add Cloud Group Member"),
                description: "Adds a team member to a cloud group, or changes their role (--group grp_… --user USER --role owner|edit|view). Only a group owner may; the last owner cannot step down. Returns group. Errors: group.member_not_in_team (a guest or someone outside the team), group.last_owner, group.too_many_members (200), group.not_found, auth.forbidden, cloud.signed_out, cloud.unreachable.",
                keywords: ["group", "member", "add", "role", "share"], category: .cloud, symbol: "person.badge.plus",
                arguments: [group, user, role], cliName: "cloud group-member-set", surfacePlan: family
            ),
            ActionDescriptor(
                id: "cloud.group.memberRemove",
                title: t("action.cloud.group.memberRemove", "Remove Cloud Group Member"),
                description: "Removes a member from a cloud group (--group grp_… --user USER); anyone may remove themselves, only an owner may remove someone else, and the last owner stays. Returns group and removed. Errors: group.last_owner, group.not_found, auth.forbidden, cloud.signed_out, cloud.unreachable.",
                keywords: ["group", "member", "remove", "leave"], category: .cloud, symbol: "person.badge.minus",
                arguments: [group, user], cliName: "cloud group-member-remove", surfacePlan: family
            ),
        ]
        // Every run answers its record (or the link) to the CLI and MCP.
        for index in actions.indices { actions[index].waitsForResult = true }
        return actions
    }

    /// The Team section offers these in place (its filters, its rows); the CLI and MCP name them.
    static var family: ActionSurfacePlan {
        ActionSurfacePlan(palette: .exempt(.familyMember), cli: .offered, contextMenuExemption: .familyMember)
    }

    /// `--session`: a `cloud:<team>/<vm>/<id>` key or a `cmux://cloud/…` link.
    static var session: ActionArgument {
        ActionArgument(name: "session", title: t("argument.cloudTeam.session", "Session or Link"), kind: .string, isRequired: false)
    }

    static var scope: ActionArgument {
        ActionArgument(name: "scope", title: t("argument.cloudTeam.scope", "Show"), kind: .enumeration([
            ActionEnumCase(value: "mine", title: t("argument.cloudTeam.scope.mine", "Assigned to Me")),
            ActionEnumCase(value: "team", title: t("argument.cloudTeam.scope.team", "Team")),
            ActionEnumCase(value: "following", title: t("argument.cloudTeam.scope.following", "Following")),
        ]), isRequired: false)
    }

    static var by: ActionArgument {
        ActionArgument(name: "by", title: t("argument.cloudTeam.by", "Assigned To"), kind: .string, isRequired: false)
    }

    static var archived: ActionArgument {
        ActionArgument(name: "archived", title: t("argument.cloudTeam.archived", "Archived"), kind: .bool, isRequired: false)
    }

    /// Archive's `--archived` (default true; false brings the session back).
    static var archive: ActionArgument {
        ActionArgument(name: "archived", title: t("argument.cloudTeam.archived", "Archived"), kind: .bool, isRequired: false)
    }

    static var cursor: ActionArgument {
        ActionArgument(name: "cursor", title: t("argument.cloudTeam.cursor", "Cursor"), kind: .string, isRequired: false)
    }

    static var limit: ActionArgument {
        ActionArgument(name: "limit", title: t("argument.cloudTeam.limit", "Limit"), kind: .int(1...200), isRequired: false)
    }

    static var to: ActionArgument {
        ActionArgument(name: "to", title: t("argument.cloudTeam.to", "Teammate"), kind: .string)
    }

    static var group: ActionArgument {
        ActionArgument(name: "group", title: t("argument.cloudTeam.group", "Group"), kind: .string)
    }

    static var user: ActionArgument {
        ActionArgument(name: "user", title: t("argument.cloudTeam.user", "Member"), kind: .string)
    }

    static var role: ActionArgument {
        ActionArgument(name: "role", title: t("argument.cloudTeam.role", "Role"), kind: .enumeration([
            ActionEnumCase(value: "owner", title: t("argument.cloudTeam.role.owner", "Owner")),
            ActionEnumCase(value: "edit", title: t("argument.cloudTeam.role.edit", "Can edit")),
            ActionEnumCase(value: "view", title: t("argument.cloudTeam.role.view", "Can view")),
        ]))
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "ActionCatalog", bundle: .module)
    }
}
