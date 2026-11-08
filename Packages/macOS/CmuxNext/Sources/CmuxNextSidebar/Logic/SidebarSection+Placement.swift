import Foundation

/// How one window's sidebar positions map to the daemon's workspace order
/// (moved from the App's `SidebarMembership`, now
/// `typealias SidebarMembership = SidebarRowSection`, for the App size cap).
/// Each window lists only the workspaces it owns; the daemon keeps one
/// order per machine for all of them, so a slot in a filtered sidebar maps
/// to the global slot next to its visible neighbors.
nonisolated extension SidebarSection {
    /// The daemon root index for local index `localIndex` into `local` (the
    /// window's remaining workspaces of one machine, in order), given that
    /// machine's full remaining order `global`: before the first workspace at
    /// or after that slot that `global` lists, else after the last one before
    /// it, or at the end when it lists none. A shown workspace `global` does
    /// not list yet (a new one whose own placement is still in flight) is no
    /// anchor: placing before it once sent quick Cmd-N presses to the bottom.
    public static func globalIndex(localIndex: Int, local: [String], global: [String]) -> Int {
        var request = RustEditRequest("global_index")
        (request.localIndex, request.local, request.global) = (localIndex, local, global)
        return RustSidebarClient.call("sidebar_edits", request, as: Int.self) ?? global.count
    }

    /// One personal placement (`workspace.place`): `key` goes to `index` in
    /// the personal order counted after `key` itself is removed.
    public struct PersonalPlacement: Hashable, Sendable {
        public var key: String
        public var index: Int

        public init(key: String, index: Int) {
            self.key = key
            self.index = index
        }
    }

    /// The personal placements, in the order to send them, that put
    /// `moving` (in order) at `localIndex` of `shown`: the window's remaining
    /// workspaces (without `moving`) in the order its sidebar shows them.
    /// `rowed` is the personal order of every workspace that has a personal
    /// position (without `moving`).
    ///
    /// A workspace without a personal position shows after every positioned
    /// one (PersonalSidebar.order), so an index into `rowed` cannot name a
    /// slot after one of them. The shown workspaces before the slot that have
    /// no position get one first, at the end of `rowed` in the order they
    /// show (which keeps that order); then the moved workspaces go after the
    /// slot's last shown workspace, or before its first.
    public static func personalPlacements(moving: [String], localIndex: Int, shown: [String], rowed: [String]) -> [PersonalPlacement] {
        var request = RustEditRequest("personal_placements")
        (request.moving, request.localIndex, request.shown, request.rowed) = (moving, localIndex, shown, rowed)
        return (RustSidebarClient.call("sidebar_edits", request, as: [RustPersonalPlacement].self) ?? []).map {
            PersonalPlacement(key: $0.key, index: $0.index)
        }
    }
}
