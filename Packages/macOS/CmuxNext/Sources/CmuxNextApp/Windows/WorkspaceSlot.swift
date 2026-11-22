import CmuxNextBridge
import CmuxNextSidebar
import Foundation

/// A place in one window's sidebar, named by meaning instead of by index,
/// so it can be resolved against the sidebar as it is when the move runs
/// (a new workspace is placed only once its daemon reports it).
///
/// Every workspace verb that changes sidebar order reduces to a slot and
/// then to one `SidebarBridge.place` call: personal order in the home
/// session when it serves personal state, else `move-workspace-to-group`
/// on the owning daemon (plans/cmux-next/data-model.md 1.2c).
enum WorkspaceSlot: Hashable, Sendable {
    /// First in the container of `anchor` (its group, else the loose rows);
    /// without an anchor, first among the section's loose rows.
    case top(anchor: String?)
    /// Last in the container of `anchor`; without an anchor, after the
    /// section's last loose row (loose rows always list before groups).
    case bottom(anchor: String?)
    /// Right before `anchor`, in its container.
    case above(String)
    /// Right after `anchor`, in its container.
    case below(String)
    /// Last in `group`.
    case endOfGroup(GroupID)
    /// A position the sidebar already resolved without the workspace (a
    /// tab dropped on a gap makes a new workspace there).
    case at(DropPosition)

    /// The drop position that puts `moving` at this slot of `section` in
    /// `sections`, counted after `moving`'s own rows are removed
    /// (`DropPosition`). Nil when the anchor or group is not listed there.
    func position(moving: Set<String>, section: SectionID, in sections: [SidebarRowSection]) -> DropPosition? {
        guard let listed = sections.first(where: { $0.id == section }) else { return nil }
        let nodes = listed.nodes.filter { node in
            if case let .workspace(workspace) = node { return !moving.contains(workspace.id.rawValue) }
            return true
        }
        switch self {
        case .top(let anchor?), .bottom(let anchor?):
            if let group = Self.group(containing: anchor, in: nodes) {
                return DropPosition(section: section, group: group.id, index: isTop ? 0 : Self.members(group, moving).count)
            }
            return Self.loose(isTop, nodes: nodes, section: section)
        case .top(nil), .bottom(nil):
            return Self.loose(isTop, nodes: nodes, section: section)
        case .above(let anchor), .below(let anchor):
            let offset = if case .below = self { 1 } else { 0 }
            if let group = Self.group(containing: anchor, in: nodes) {
                guard let index = Self.members(group, moving).firstIndex(of: anchor) else { return nil }
                return DropPosition(section: section, group: group.id, index: index + offset)
            }
            guard let index = nodes.firstIndex(where: { $0.workspaceID == anchor }) else { return nil }
            return DropPosition(section: section, index: index + offset)
        case .at(let position):
            return position.section == section ? position : nil
        case .endOfGroup(let group):
            guard let node = nodes.lazy.compactMap(\.group).first(where: { $0.id == group }) else { return nil }
            return DropPosition(section: section, group: group, index: Self.members(node, moving).count)
        }
    }

    private var isTop: Bool {
        if case .top = self { return true }
        return false
    }

    /// First slot, or the slot after the last loose row.
    private static func loose(_ top: Bool, nodes: [SidebarNode], section: SectionID) -> DropPosition {
        guard !top, let last = nodes.lastIndex(where: { $0.workspaceID != nil }) else {
            return DropPosition(section: section, index: 0)
        }
        return DropPosition(section: section, index: last + 1)
    }

    private static func group(containing id: String, in nodes: [SidebarNode]) -> SidebarGroup? {
        nodes.lazy.compactMap(\.group).first { $0.workspaces.contains { $0.id.rawValue == id } }
    }

    private static func members(_ group: SidebarGroup, _ moving: Set<String>) -> [String] {
        group.workspaces.map(\.id.rawValue).filter { !moving.contains($0) }
    }
}

private extension SidebarNode {
    var workspaceID: String? {
        if case let .workspace(workspace) = self { return workspace.id.rawValue }
        return nil
    }

    var group: SidebarGroup? {
        if case let .group(group) = self { return group }
        return nil
    }
}

/// How Sort Workspaces orders one container (the loose rows, or one group).
/// Groups keep their place and their members; only the order inside each
/// container changes.
enum WorkspaceSortKey: String, CaseIterable, Sendable {
    case name
    case lastUsed
    case directory

    /// `ids` sorted by this key: `name` by display name (Finder order),
    /// `directory` by first terminal directory then name, `lastUsed` by the
    /// window's recency (most recent first, never shown ones last in their
    /// current order).
    func sorted(_ ids: [String], names: [String: String], directories: [String: String], recency: [String]) -> [String] {
        let position = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let recent = Dictionary(recency.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func byName(_ lhs: String, _ rhs: String) -> Bool {
            let order = (names[lhs] ?? lhs).localizedStandardCompare(names[rhs] ?? rhs)
            return order == .orderedSame ? position[lhs, default: 0] < position[rhs, default: 0] : order == .orderedAscending
        }
        switch self {
        case .name:
            return ids.sorted(by: byName)
        case .directory:
            return ids.sorted { lhs, rhs in
                switch (directories[lhs], directories[rhs]) {
                case let (l?, r?) where l != r: l.localizedStandardCompare(r) == .orderedAscending
                case (_?, nil): true
                case (nil, _?): false
                default: byName(lhs, rhs)
                }
            }
        case .lastUsed:
            return ids.sorted { lhs, rhs in
                switch (recent[lhs], recent[rhs]) {
                case let (l?, r?): l < r
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): position[lhs, default: 0] < position[rhs, default: 0]
                }
            }
        }
    }
}
