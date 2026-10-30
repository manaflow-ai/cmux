public import CmuxNextSidebar

/// A drawn gap captured before an asynchronous create. Neighbors keep their
/// identity when a newer store snapshot inserts rows before the drop.
public struct WorkspaceGap: Hashable, Sendable {
    public let section: SectionID
    public let group: GroupID?
    private let before: SidebarNode.ID?
    private let after: SidebarNode.ID?

    public init?(_ position: DropPosition, in sections: [SidebarRowSection], moving: Set<String> = []) {
        guard let members = Self.members(section: position.section, group: position.group, in: sections, moving: moving) else { return nil }
        let index = min(max(position.index, 0), members.count)
        section = position.section
        group = position.group
        before = index < members.count ? members[index] : nil
        after = index > 0 ? members[index - 1] : nil
    }

    public func position(moving: Set<String>, in sections: [SidebarRowSection]) -> DropPosition? {
        guard let members = Self.members(section: section, group: group, in: sections, moving: moving) else { return nil }
        let index: Int
        if let before, let found = members.firstIndex(of: before) { index = found }
        else if let after, let found = members.firstIndex(of: after) { index = found + 1 }
        else if before == nil, after == nil { index = 0 }
        else { return nil } // Both neighbors disappeared; do not reuse their old numeric slot.
        return DropPosition(section: section, group: group, index: index)
    }

    private static func members(section: SectionID, group: GroupID?, in sections: [SidebarRowSection], moving: Set<String>) -> [SidebarNode.ID]? {
        guard let section = sections.first(where: { $0.id == section }) else { return nil }
        let ids: [SidebarNode.ID]
        if let group {
            guard let found = section.nodes.compactMap({ node -> SidebarGroup? in
                if case let .group(value) = node { return value }
                return nil
            }).first(where: { $0.id == group }) else { return nil }
            ids = found.members.map { member in
                switch member {
                case let .workspace(workspace): .workspace(workspace.id)
                case let .item(item): .item(item.id)
                }
            }
        } else { ids = section.nodes.map(\.id) }
        return ids.filter { id in
            if case let .workspace(workspace) = id { return !moving.contains(workspace.rawValue) }
            return true
        }
    }
}
