/// Which workspace rows one window's sidebar lists (moved from the App's
/// `SidebarMembership`, which keeps the daemon-order mapping): pure
/// functions over the sections, so the App target stays under its size cap.
nonisolated extension SidebarSection {
    /// `sections` with only `members`' workspaces. A group belongs to the
    /// window that lists its workspaces (#25776, as in cmux classic): it
    /// stays when it, or a group under it, holds a member here, or when none
    /// of its tree holds a workspace at all (an empty group, or one of links
    /// only, belongs to no window, so every window can drop into it). A group
    /// whose workspaces only another window lists leaves with its link
    /// members. Section headers always stay: they carry the machine's "new workspace".
    public static func filter(_ sections: [SidebarSection], members: Set<String>) -> [SidebarSection] {
        let groups = sections.flatMap(\.nodes).compactMap { node -> SidebarGroup? in if case let .group(group) = node { group } else { nil } }
        let anywhere = holding(groups) { !$0.workspaces.isEmpty }
        let here = holding(groups) { $0.workspaces.contains { members.contains($0.id.rawValue) } }
        return sections.map { section in
            var section = section
            section.nodes = section.nodes.compactMap { node in
                switch node {
                case let .workspace(workspace):
                    return members.contains(workspace.id.rawValue) ? node : nil
                case var .group(group):
                    guard here.contains(group.id) || !anywhere.contains(group.id) else { return nil }
                    group.workspaces.removeAll { !members.contains($0.id.rawValue) }
                    return .group(group)
                case .item:
                    return node
                }
            }
            return section
        }
    }

    /// The groups for which `holds` is true, with every group above one.
    private static func holding(_ groups: [SidebarGroup], _ holds: (SidebarGroup) -> Bool) -> Set<GroupID> {
        let parents = Dictionary(groups.map { ($0.id, $0.parent) }, uniquingKeysWith: { first, _ in first })
        var result = Set<GroupID>()
        for group in groups where holds(group) {
            var id: GroupID? = group.id
            while let current = id, result.insert(current).inserted { id = parents[current] ?? nil }
        }
        return result
    }

    /// `sections` with the `pinned` workspaces (`workspace-pin-v1`) moved,
    /// in sidebar order, into a Pinned section at the top. Groups stay in
    /// their section, even when every member is pinned, so they can still be
    /// renamed and dropped into; a pinned group lists first in its section
    /// (daemons without the sidebar document). No pinned workspace, no Pinned section.
    public static func pinnedFirst(_ sections: [SidebarSection], pinned: Set<String>) -> [SidebarSection] {
        let sections = sections.map(\.pinnedGroupsFirst)
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
                case .item:
                    return node
                }
            }
            return section
        }
        let nodes = moving.map(SidebarNode.workspace)
        if let index = result.firstIndex(where: { $0.id == .pinned }) {
            result[index].nodes += nodes
        } else {
            result.insert(SidebarSection(kind: .pinned, nodes: nodes), at: 0)
        }
        return result
    }

    /// This section with its pinned groups first, in their order (the document lists pinned groups first;
    /// pinning-DESIGN.md). Everything else keeps its order.
    var pinnedGroupsFirst: SidebarSection {
        let isPinnedGroup = { (node: SidebarNode) -> Bool in if case .group(let group) = node { group.isPinned } else { false } }
        guard nodes.contains(where: isPinnedGroup) else { return self }
        var section = self
        section.nodes = nodes.filter(isPinnedGroup) + nodes.filter { !isPinnedGroup($0) }
        return section
    }

    /// `sections` without the `hidden` workspaces (those the sidebar's top
    /// region shows as tiles or top rows). Groups stay, like `pinnedFirst`.
    public static func hiding(_ sections: [SidebarSection], workspaces hidden: Set<String>) -> [SidebarSection] {
        guard !hidden.isEmpty else { return sections }
        return sections.map { section in
            var section = section
            section.nodes = section.nodes.compactMap { node in
                switch node {
                case let .workspace(workspace):
                    return hidden.contains(workspace.id.rawValue) ? nil : node
                case var .group(group):
                    group.workspaces.removeAll { hidden.contains($0.id.rawValue) }
                    return .group(group)
                case .item:
                    return node
                }
            }
            return section
        }
    }

    /// `sections` with every live row marked `.stale` (the daemon's launch
    /// snapshot, before the live tree).
    public static func stale(_ sections: [SidebarSection]) -> [SidebarSection] {
        marking(sections) { $0.rowState = .stale }
    }

    /// `sections` without placeholder rows, which no daemon knows: a new
    /// workspace's slot is resolved against the rows it will sit among.
    public static func withoutPlaceholders(_ sections: [SidebarSection]) -> [SidebarSection] {
        sections.map { section in
            var section = section
            section.nodes = section.nodes.compactMap { node in
                switch node {
                case let .workspace(workspace):
                    return workspace.rowState.isPending ? nil : node
                case var .group(group):
                    group.workspaces.removeAll(where: \.rowState.isPending)
                    return .group(group)
                case .item:
                    return node
                }
            }
            return section
        }
    }

    private static func marking(_ sections: [SidebarSection], _ change: (inout SidebarWorkspace) -> Void) -> [SidebarSection] {
        sections.map { section in
            var section = section
            section.nodes = section.nodes.map { node in
                switch node {
                case var .workspace(ws):
                    change(&ws)
                    return .workspace(ws)
                case var .group(group):
                    for index in group.workspaces.indices { change(&group.workspaces[index]) }
                    return .group(group)
                case .item:
                    return node
                }
            }
            return section
        }
    }
}
