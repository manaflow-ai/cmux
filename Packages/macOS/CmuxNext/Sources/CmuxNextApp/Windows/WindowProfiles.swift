import CmuxNextDaemon

/// Which of a window's workspaces its current room shows
/// (plans/cmux-next/data-model.md 3.2 and 4). Rooms are personal state of
/// the home session (the local daemon); their rules (follow sessions, pin
/// workspaces) apply to the workspaces of every session. Without personal
/// state (a home daemon lacking `profiles-v1`) there is one implicit room
/// that shows everything (read-only fallback). A workspace no session
/// reports yet (just created for a window) shows.
@MainActor
enum WindowProfiles {
    /// The home session's room rules, or nil in the fallback.
    static func membership(_ machines: MachineRegistry) -> RoomMembership? {
        let personal = machines.local.store.personal
        guard personal.isLoaded else { return nil }
        var membership = RoomMembership(follows: personal.follows)
        for pin in personal.pins {
            membership.pins[RoomMembership.Workspace(session: pin.sessionID, key: pin.workspaceKey.rawValue)] = pin.profile
        }
        return membership
    }

    /// `workspaceID` qualified by the session that owns it.
    static func qualified(_ workspaceID: String, machines: MachineRegistry) -> RoomMembership.Workspace? {
        guard let (workspace, daemon) = machines.workspace(id: workspaceID), let session = daemon.store.registryID else { return nil }
        return RoomMembership.Workspace(session: session, key: workspace.key?.rawValue ?? workspace.id)
    }

    static func shows(_ workspaceID: String, profile: ProfileID, machines: MachineRegistry,
                      membership: RoomMembership?) -> Bool {
        guard let membership, let workspace = qualified(workspaceID, machines: machines) else { return true }
        return membership.contains(workspace, in: profile)
    }

    static func visible(_ members: [String], profile: ProfileID, machines: MachineRegistry) -> [String] {
        let membership = membership(machines)
        return members.filter { shows($0, profile: profile, machines: machines, membership: membership) }
    }

    /// The room a workspace is in for "select it and switch the window":
    /// its pin, else the first following room in room order, else nil when
    /// it shows in every room (fallback) or in `current`.
    static func room(of workspaceID: String, current: ProfileID, machines: MachineRegistry) -> ProfileID? {
        guard let membership = membership(machines), let workspace = qualified(workspaceID, machines: machines) else { return nil }
        let rooms = membership.rooms(of: workspace)
        guard !rooms.contains(current) else { return nil }
        return machines.local.store.profileIDs.first(where: rooms.contains)
    }

    /// The room a window falls back to when its current one has no
    /// workspace left there: the most recent it showed that still has one,
    /// else any room with one (room order). Nil when none has one.
    static func fallback(for state: WindowState, members: [String], machines: MachineRegistry) -> ProfileID? {
        let order = state.profileRecency + machines.local.store.profileIDs
        return order.first { profile in
            profile != state.profileID && !visible(members, profile: profile, machines: machines).isEmpty
        }
    }

    /// Workspaces of `daemon` in `room`, in daemon order.
    static func workspaces(of daemon: DaemonService, in room: ProfileID, machines: MachineRegistry) -> [WorkspaceModel] {
        let membership = membership(machines)
        return daemon.store.workspaces.filter { shows($0.id, profile: room, machines: machines, membership: membership) }
    }
}
