import CmuxNextBridge
import CmuxNextSidebar

/// Which rows one window's sidebar shows, and how its positions map to the
/// daemon's workspace order. Each window lists only the workspaces it owns
/// (`WindowRegistry`); the daemon keeps one order per machine for all of
/// them, so a slot in a filtered sidebar maps to the global slot next to its
/// visible neighbors.
enum SidebarMembership {
    /// `sections` with only `members`' workspaces. A group stays when it
    /// holds a member here, or when it is empty everywhere (an empty group
    /// belongs to no window, so every window can drop into it). Section
    /// headers always stay: they carry the machine's "new workspace".
    static func filter(_ sections: [SidebarRowSection], members: Set<String>) -> [SidebarRowSection] {
        sections.map { section in
            var section = section
            section.nodes = section.nodes.compactMap { node in
                switch node {
                case let .workspace(workspace):
                    return members.contains(workspace.id.rawValue) ? node : nil
                case var .group(group):
                    let wasEmpty = group.workspaces.isEmpty
                    group.workspaces.removeAll { !members.contains($0.id.rawValue) }
                    return group.workspaces.isEmpty && !wasEmpty ? nil : .group(group)
                }
            }
            return section
        }
    }

    /// `sections` with the `pinned` workspaces (`workspace-pin-v1`) moved,
    /// in sidebar order, into a Pinned section at the top. Groups stay where
    /// they are, even when every member is pinned, so they can still be
    /// renamed and dropped into. No pinned workspace, no Pinned section.
    static func pinnedFirst(_ sections: [SidebarRowSection], pinned: Set<String>) -> [SidebarRowSection] {
        let moving = sections.flatMap(\.workspaces).filter { pinned.contains($0.id.rawValue) }
        guard !moving.isEmpty else { return sections }
        var result = sections.map { section in
            var section = section
            section.nodes = section.nodes.compactMap { node in
                switch node {
                case let .workspace(workspace):
                    return pinned.contains(workspace.id.rawValue) ? nil : node
                case var .group(group):
                    group.workspaces.removeAll { pinned.contains($0.id.rawValue) }
                    return .group(group)
                }
            }
            return section
        }
        let nodes = moving.map(SidebarNode.workspace)
        if let index = result.firstIndex(where: { $0.id == .pinned }) {
            result[index].nodes += nodes
        } else {
            result.insert(SidebarRowSection(kind: .pinned, nodes: nodes), at: 0)
        }
        return result
    }

    /// The daemon root index for local index `localIndex` into `local` (the
    /// window's remaining workspaces of one machine, in order), given that
    /// machine's full remaining order `global`: before the workspace at that
    /// slot, after the window's last one, or at the end when it has none.
    static func globalIndex(localIndex: Int, local: [String], global: [String]) -> Int {
        if localIndex < local.count, let anchor = global.firstIndex(of: local[localIndex]) { return anchor }
        if let last = local.last, let index = global.firstIndex(of: last) { return index + 1 }
        return global.count
    }

    /// One personal placement (`workspace.place`): `key` goes to `index` in
    /// the personal order counted after `key` itself is removed.
    struct PersonalPlacement: Hashable {
        var key: String
        var index: Int
    }

    /// The personal placements, in the order to send them, that put
    /// `moving` (in order) at `localIndex` of `shown`: the window's remaining
    /// workspaces (without `moving`) in the order its sidebar shows them.
    /// `rowed` is the personal order of every workspace that has a personal
    /// position (without `moving`).
    static func personalPlacements(moving: [String], localIndex: Int, shown: [String], rowed: [String]) -> [PersonalPlacement] {
        let index = globalIndex(localIndex: localIndex, local: shown, global: rowed)
        return moving.enumerated().map { PersonalPlacement(key: $1, index: index + $0) }
    }
}
