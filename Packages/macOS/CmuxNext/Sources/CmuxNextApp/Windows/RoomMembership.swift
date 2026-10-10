import CmuxNextDaemon

/// Which room each workspace is in (plans/cmux-next/data-model.md 3.2): a
/// room follows whole sessions and pins single workspaces. A workspace is
/// in room R when it is pinned to R, or R follows its session and it is
/// pinned to no room. A workspace in no room shows in `default`, so nothing
/// is ever unreachable. Pure value type; the App builds it from the home
/// session's personal state.
struct RoomMembership: Equatable, Sendable {
    /// A workspace qualified by the session (`registry_id`) that owns it.
    struct Workspace: Hashable, Sendable {
        var session: String
        var key: String
    }

    /// Sessions each room follows.
    var follows: [ProfileID: Set<String>] = [:]
    /// The one room each pinned workspace is pinned to.
    var pins: [Workspace: ProfileID] = [:]

    /// The rooms that show `workspace`, never empty.
    func rooms(of workspace: Workspace) -> Set<ProfileID> {
        if let pinned = pins[workspace] { return [pinned] }
        let followers = Set(follows.filter { $0.value.contains(workspace.session) }.keys)
        return followers.isEmpty ? [.defaultProfile] : followers
    }

    func contains(_ workspace: Workspace, in room: ProfileID) -> Bool {
        rooms(of: workspace).contains(room)
    }

    /// Whether Delete Space on `room` closes `workspace`
    /// (SPACE-DELETE-CLOSES-ITS-WORKSPACES): no other room shows it. The
    /// daemon applies the same rule (`room_archive::closing_keys`).
    func closes(_ workspace: Workspace, deleting room: ProfileID) -> Bool {
        room != .defaultProfile && rooms(of: workspace) == [room]
    }

    /// Pins `workspace` to `room` (Move Workspace to Room), replacing any
    /// other pin.
    mutating func pin(_ workspace: Workspace, to room: ProfileID) {
        pins[workspace] = room
    }

    /// A room left the list: its pins go to `target`, or are removed (the
    /// workspaces return to their followers); it stops following.
    mutating func removeRoom(_ room: ProfileID, movingPinsTo target: ProfileID?) {
        follows[room] = nil
        for (workspace, pinned) in pins where pinned == room { pins[workspace] = target }
    }

    /// Membership for a daemon that has no personal state yet (before the
    /// home session serves rules): `default` follows every session.
    static func followingAll(_ sessions: [String]) -> RoomMembership {
        RoomMembership(follows: [.defaultProfile: Set(sessions)])
    }
}
