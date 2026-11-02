public import CmuxNextSidebar
import Foundation

/// A place in one window's sidebar, named by meaning instead of by index,
/// so it can be resolved against the sidebar as it is when the move runs
/// (a new workspace is placed only once its daemon reports it).
///
/// Every workspace verb that changes sidebar order reduces to a slot and
/// then to one `SidebarBridge.place` call: personal order in the home
/// session when it serves personal state, else `move-workspace-to-group`
/// on the owning daemon (plans/cmux-next/data-model.md 1.2c).
public enum WorkspaceSlot: Hashable, Sendable {
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
    /// A sidebar gap's neighbors, captured before its asynchronous create.
    case gap(WorkspaceGap)

    /// The drop position that puts `moving` at this slot of `section` in
    /// `sections`, counted after `moving`'s own rows are removed
    /// (`DropPosition`). Nil when the anchor or group is not listed there.
    public func position(moving: Set<String>, section: SectionID, in sections: [SidebarRowSection]) -> DropPosition? {
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
        case .gap(let gap):
            return gap.section == section ? gap.position(moving: moving, in: sections) : nil
        case .endOfGroup(let group):
            guard let node = nodes.lazy.compactMap(\.group).first(where: { $0.id == group }) else { return nil }
            return DropPosition(section: section, group: group, index: Self.members(node, moving).count)
        }
    }

    /// ``position(moving:section:in:)`` in the section that lists `anchor`
    /// (loose or in a group), so the slot names `anchor`'s own container.
    /// Nil when `sections` do not list `anchor`: resolved against another
    /// section, `top`/`bottom` fell back to its loose rows and a grouped
    /// workspace left its group (a notification's move to the top did that).
    public func position(moving: Set<String>, besides anchor: String, in sections: [SidebarRowSection]) -> DropPosition? {
        guard let home = Self.section(listing: anchor, in: sections) else { return nil }
        return position(moving: moving, section: home, in: sections)
    }

    /// Why Move Workspace Above/Below cannot drop a row (``beside(_:below:moving:in:onDocument:)``).
    public enum BesideRefusal: Error, Equatable {
        /// `moving` is `anchor`, or the sidebar does not list both in one section (a move across
        /// sections is a pin or a section change, which have their own verbs).
        case elsewhere
        /// Both are in Pinned or a custom section, which reorder only on the sidebar document
        /// (off it, a reorder there would pin the rows).
        case needsDocument
    }

    /// Move Workspace Above/Below (cmux#29907): where `moving` drops right before
    /// (`below` false) or after `anchor`, in the anchor's container (its group, else
    /// the loose rows), as a row drag drops it.
    public static func beside(_ anchor: String, below: Bool, moving: String, in sections: [SidebarRowSection],
                              onDocument: Bool) -> Result<DropPosition, BesideRefusal> {
        guard moving != anchor,
              let home = section(listing: anchor, in: sections), section(listing: moving, in: sections) == home
        else { return .failure(.elsewhere) }
        if case .machine = home {} else if !onDocument { return .failure(.needsDocument) }
        let slot: WorkspaceSlot = below ? .below(anchor) : .above(anchor)
        return slot.position(moving: [moving], section: home, in: sections).map { .success($0) } ?? .failure(.elsewhere)
    }

    /// The Move Workspace verbs' reorder: `ids` (rows of `anchor`'s section, in sidebar
    /// order; the others stay) as one block at this slot of `anchor`'s container, or
    /// just `anchor` when none of `ids` is there. Nil when `sections` do not list
    /// `anchor` (the move would land it loose, out of its group), or the section is
    /// Pinned or a custom one while the sidebar document is off.
    public func reorder(_ ids: [String], anchor: String, in sections: [SidebarRowSection], onDocument: Bool)
        -> (moving: [SidebarWorkspaceID], position: DropPosition)? {
        guard let home = SidebarEdits.locate(SidebarWorkspaceID(anchor), in: sections)?.section else { return nil }
        var moving = SidebarEdits.treeOrder(ids.map(SidebarWorkspaceID.init), in: sections).filter {
            SidebarEdits.locate($0, in: sections)?.section == home
        }
        if moving.isEmpty { moving = [SidebarWorkspaceID(anchor)] }
        guard let position = position(moving: Set(moving.map(\.rawValue)), besides: anchor, in: sections),
              sections[home].machine != nil || onDocument else { return nil }
        return (moving, position)
    }

    /// The group that lists workspace `id` in `sections`, if any.
    public static func group(listing id: String, in sections: [SidebarRowSection]) -> SidebarGroup? {
        sections.lazy.compactMap { group(containing: id, in: $0.nodes) }.first
    }

    /// The section that lists workspace `id`, loose or in a group.
    private static func section(listing id: String, in sections: [SidebarRowSection]) -> SectionID? {
        sections.first { section in
            section.nodes.contains { node in
                switch node {
                case let .workspace(workspace): workspace.id.rawValue == id
                case let .group(group): group.workspaces.contains { $0.id.rawValue == id }
                case .item: false
                }
            }
        }?.id
    }

    /// Right below `anchor` when `sections` list it in a group, so a new workspace joins that group (an
    /// agent's spawn joins its own workspace's group); nil when `anchor` is loose or not listed.
    public static func belowGrouped(_ anchor: String, in sections: [SidebarRowSection]) -> WorkspaceSlot? {
        sections.contains { group(containing: anchor, in: $0.nodes) != nil } ? .below(anchor) : nil
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

    /// The group's member rows (a group's index counts its link, tab and app items too), without `moving`.
    private static func members(_ group: SidebarGroup, _ moving: Set<String>) -> [String] {
        group.members.map { member in
            switch member {
            case let .workspace(workspace): workspace.id.rawValue
            case let .item(item): "item:" + item.id
            }
        }.filter { !moving.contains($0) }
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
public enum WorkspaceSortKey: String, CaseIterable, Sendable {
    case name
    case lastUsed
    case directory

    /// The containers Sort orders in `section`: its loose rows (group nil), then each group's
    /// member rows, in sidebar order. With `only`, just that group (Sort Group).
    public static func containers(of section: SidebarRowSection, only: GroupID? = nil) -> [(group: GroupID?, ids: [String])] {
        var all: [(group: GroupID?, ids: [String])] = [(nil, section.nodes.compactMap(\.workspaceID))]
        for case let .group(group) in section.nodes { all.append((group.id, group.workspaces.map(\.id.rawValue))) }
        return only.map { only in all.filter { $0.group == only } } ?? all
    }

    /// `ids` sorted by this key: `name` by display name (Finder order),
    /// `directory` by first terminal directory then name, `lastUsed` by the
    /// window's recency (most recent first, never shown ones last in their
    /// current order).
    public func sorted(_ ids: [String], names: [String: String], directories: [String: String], recency: [String]) -> [String] {
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
