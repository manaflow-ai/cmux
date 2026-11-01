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
    /// Each pinned workspace's one room, by session then key: `PersonalStore.pinnedRooms` as is, so a membership costs
    /// nothing to make. A session is listed only with a pin, so `pins.isEmpty` means no workspace is pinned.
    var pins: [String: [String: ProfileID]] = [:]

    /// The room `workspace` is pinned to, if any.
    func pinned(_ workspace: Workspace) -> ProfileID? { pins[workspace.session]?[workspace.key] }

    /// The rooms that show `workspace`, never empty.
    func rooms(of workspace: Workspace) -> Set<ProfileID> {
        if let pinned = pinned(workspace) { return [pinned] }
        let followers = Set(follows.filter { $0.value.contains(workspace.session) }.keys)
        return followers.isEmpty ? [.defaultProfile] : followers
    }

    /// `rooms(of:).contains(room)` without building the set (the control snapshot asks it per workspace).
    func contains(_ workspace: Workspace, in room: ProfileID) -> Bool {
        if let pinned = pinned(workspace) { return pinned == room }
        var followed = false
        for (follower, sessions) in follows where sessions.contains(workspace.session) {
            if follower == room { return true }
            followed = true
        }
        return !followed && room == .defaultProfile
    }

    /// Whether no room in `shown` (the rooms the open windows show) shows `workspace`: its space is
    /// hidden, so it hibernates on the shorter clock (design/spaces.md, "Hibernation and the perf plan").
    func isHidden(_ workspace: Workspace, shown: Set<ProfileID>) -> Bool {
        !shown.contains { contains(workspace, in: $0) }
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
        pins[workspace.session, default: [:]][workspace.key] = room
    }
}
