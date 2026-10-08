public import CmuxNextDesign
import Foundation

/// Pure tree edits behind every structural intent. `SidebarModel.apply(_:)`
/// calls these; they are also what the tests exercise.
public nonisolated enum SidebarEdits {
    /// Where a workspace sits in the tree.
    public struct Location: Hashable, Sendable {
        public var section: Int
        public var node: Int
        /// Index inside the group at `node`, or nil for a loose workspace.
        public var child: Int?
    }

    /// Applies an intent. Returns false when the intent was refused or had
    /// no structural effect (for example `select` or an invalid drop).
    @discardableResult
    public static func apply(_ intent: SidebarIntent, to sections: inout [SidebarSection]) -> Bool {
        switch intent {
        case .select, .selectTab, .moveTab, .newWorkspace, .openGroup, .switchProfile, .newProfile, .reorderProfile, .activateItem, .installUpdate, .setAutomaticUpdates,
             .openUpdateLink, .tryTip, .dismissTip, .layout, .toggleLayoutSection, .dropOnLayoutSection:
            return false
        case let .setGroupPinned(id, pinned):
            return mutateGroup(id, in: &sections) { $0.isPinned = pinned }
        case let .setGroupIcon(id, icon):
            return mutateGroup(id, in: &sections) { $0.icon = icon.flatMap { WorkspaceIcon.parse($0) } }
        case let .closeGroup(id):
            return closeGroup(id, in: &sections)
        case let .reorder(ids, position):
            return reorder(ids, to: position, in: &sections)
        case let .move(ids, group):
            return move(ids, toGroup: group, in: &sections)
        case let .reorderGroup(group, index):
            return reorderGroup(group, index: index, in: &sections)
        case let .createGroup(id, name, color, ids, anchor, collapsed):
            guard createGroup(id, name: name, color: color, workspaces: ids, anchor: anchor, in: &sections) else { return false }
            if collapsed { _ = mutateGroup(id, in: &sections) { $0.isCollapsed = true } }
            return true
        case let .renameGroup(id, name):
            return mutateGroup(id, in: &sections) { $0.name = name }
        case let .setGroupColor(id, color):
            return mutateGroup(id, in: &sections) { $0.color = color }
        case let .ungroup(id):
            return ungroup(id, in: &sections)
        case let .toggleCollapse(target):
            return toggleCollapse(target, in: &sections)
        case let .close(ids):
            let removed = removeWorkspaces(Set(ids), from: &sections)
            pruneEmptyGroups(in: &sections, keeping: nil)
            return !removed.isEmpty
        case let .rename(id, title):
            return mutateWorkspaces([id], in: &sections) { $0.title = title }
        case let .setColor(ids, color):
            return mutateWorkspaces(ids, in: &sections) { ws in
                switch (ws.icon, color) {
                case let (.symbol(name, _)?, color): ws.icon = .symbol(name, tint: color)
                case (.emoji?, _): break // an emoji keeps its own colors
                case let (_, color?): ws.icon = .swatch(color)
                case (.swatch?, nil), (nil, nil): ws.icon = nil
                }
            }
        case let .setIcon(ids, icon):
            return mutateWorkspaces(ids, in: &sections) { $0.icon = icon }
        case let .setPinned(ids, pinned):
            return setPinned(ids, pinned, in: &sections)
        }
    }

    // MARK: Queries

    public static func locate(_ id: WorkspaceID, in sections: [SidebarSection]) -> Location? {
        for (s, section) in sections.enumerated() {
            for (n, node) in section.nodes.enumerated() {
                switch node {
                case let .workspace(ws) where ws.id == id:
                    return Location(section: s, node: n, child: nil)
                case let .group(group):
                    if let c = group.workspaces.firstIndex(where: { $0.id == id }) {
                        return Location(section: s, node: n, child: c)
                    }
                default:
                    continue
                }
            }
        }
        return nil
    }

    public static func workspace(_ id: WorkspaceID, in sections: [SidebarSection]) -> SidebarWorkspace? {
        guard let loc = locate(id, in: sections) else { return nil }
        switch sections[loc.section].nodes[loc.node] {
        case let .workspace(ws): return ws
        case let .group(group): return loc.child.map { group.workspaces[$0] }
        }
    }

    /// Section index and node index of a group.
    public static func locateGroup(_ id: GroupID, in sections: [SidebarSection]) -> (section: Int, node: Int)? {
        for (s, section) in sections.enumerated() {
            if let n = section.nodes.firstIndex(where: { $0.id == .group(id) }) {
                return (s, n)
            }
        }
        return nil
    }

    /// The slot a workspace occupies now, in "after removal" coordinates
    /// for a block whose first item (in tree order) is `id`.
    public static func position(of id: WorkspaceID, in sections: [SidebarSection]) -> DropPosition? {
        guard let loc = locate(id, in: sections) else { return nil }
        let section = sections[loc.section]
        if let child = loc.child, case let .group(group) = section.nodes[loc.node] {
            return DropPosition(section: section.id, group: group.id, index: child)
        }
        return DropPosition(section: section.id, index: loc.node)
    }

    /// The given ids in visual (tree) order, dropping unknown ids.
    public static func treeOrder(_ ids: some Collection<WorkspaceID>, in sections: [SidebarSection]) -> [WorkspaceID] {
        let wanted = Set(ids)
        return sections.flatMap(\.workspaces).map(\.id).filter { wanted.contains($0) }
    }

    /// Whether a workspace may live in a section.
    public static func canPlace(_ ws: SidebarWorkspace, in section: SidebarSection) -> Bool {
        switch section.kind {
        case .pinned: true
        case let .machine(machine): machine.id == ws.machineID
        }
    }

    // MARK: Edits

    static func reorder(_ ids: [WorkspaceID], to position: DropPosition, in sections: inout [SidebarSection]) -> Bool {
        guard let s = sections.firstIndex(where: { $0.id == position.section }) else { return false }
        if position.group != nil, sections[s].machine == nil { return false }
        let ordered = treeOrder(ids, in: sections)
        guard !ordered.isEmpty else { return false }
        let moving = ordered.compactMap { workspace($0, in: sections) }
        guard moving.allSatisfy({ canPlace($0, in: sections[s]) }) else { return false }
        if let group = position.group {
            guard sections[s].nodes.contains(where: { $0.id == .group(group) }) else { return false }
        }

        let before = sections
        let removed = removeWorkspaces(Set(ordered), from: &sections)
        insert(removed, at: position, in: &sections)
        pruneEmptyGroups(in: &sections, keeping: position.group)
        return sections != before
    }

    static func move(_ ids: [WorkspaceID], toGroup group: GroupID, in sections: inout [SidebarSection]) -> Bool {
        guard let (s, n) = locateGroup(group, in: sections),
              case let .group(g) = sections[s].nodes[n] else { return false }
        let moving = Set(ids)
        let remaining = g.workspaces.count(where: { !moving.contains($0.id) })
        return reorder(ids, to: DropPosition(section: sections[s].id, group: group, index: remaining), in: &sections)
    }

    static func reorderGroup(_ group: GroupID, index: Int, in sections: inout [SidebarSection]) -> Bool {
        guard let (s, n) = locateGroup(group, in: sections) else { return false }
        let node = sections[s].nodes.remove(at: n)
        let clamped = max(0, min(index, sections[s].nodes.count))
        sections[s].nodes.insert(node, at: clamped)
        return clamped != n
    }

    static func createGroup(
        _ id: GroupID,
        name: String,
        color: GroupColor,
        workspaces ids: [WorkspaceID],
        anchor target: WorkspaceID? = nil,
        in sections: inout [SidebarSection]
    ) -> Bool {
        let ordered = treeOrder(ids, in: sections)
        // The group forms at `target` (an onto-drop's target row), else at
        // the first workspace in tree order.
        guard let first = target.flatMap({ ordered.contains($0) ? $0 : nil }) ?? ordered.first,
              let anchor = locate(first, in: sections),
              sections[anchor.section].machine != nil,
              locateGroup(id, in: sections) == nil else { return false }
        let s = anchor.section
        // Only workspaces from the anchor's section join. Loose members
        // before the insertion point leave it, so it moves up by their count
        // (emptied groups stay until the prune below).
        let sameSection = ordered.filter { locate($0, in: sections)?.section == s }
        let joining = Set(sameSection)
        var insertion = anchor.child == nil ? anchor.node : anchor.node + 1
        insertion -= sections[s].nodes.prefix(insertion).count(where: { node in
            if case let .workspace(ws) = node { return joining.contains(ws.id) }
            return false
        })
        let removed = removeWorkspaces(joining, from: &sections)
        let group = SidebarGroup(id: id, name: SidebarGroup.named(name), color: color, workspaces: removed)
        sections[s].nodes.insert(.group(group), at: min(insertion, sections[s].nodes.count))
        pruneEmptyGroups(in: &sections, keeping: id)
        return true
    }

    static func ungroup(_ id: GroupID, in sections: inout [SidebarSection]) -> Bool {
        guard let (s, n) = locateGroup(id, in: sections),
              case let .group(group) = sections[s].nodes[n] else { return false }
        sections[s].nodes.replaceSubrange(n...n, with: group.workspaces.map(SidebarNode.workspace))
        return true
    }

    static func closeGroup(_ id: GroupID, in sections: inout [SidebarSection]) -> Bool {
        guard let (s, n) = locateGroup(id, in: sections),
              case var .group(group) = sections[s].nodes[n] else { return false }
        if group.isPinned {
            group.workspaces = []
            group.isCollapsed = true
            sections[s].nodes[n] = .group(group)
        } else {
            sections[s].nodes.remove(at: n)
        }
        return true
    }

    static func toggleCollapse(_ target: CollapseTarget, in sections: inout [SidebarSection]) -> Bool {
        switch target {
        case let .section(id):
            guard let s = sections.firstIndex(where: { $0.id == id }) else { return false }
            sections[s].isCollapsed.toggle()
            return true
        case let .group(id):
            return mutateGroup(id, in: &sections) { $0.isCollapsed.toggle() }
        }
    }

    static func setPinned(_ ids: [WorkspaceID], _ pinned: Bool, in sections: inout [SidebarSection]) -> Bool {
        let ordered = treeOrder(ids, in: sections)
        guard !ordered.isEmpty else { return false }
        if pinned {
            if !sections.contains(where: { $0.id == .pinned }) {
                sections.insert(SidebarSection(kind: .pinned, nodes: []), at: 0)
            }
            let s = sections.firstIndex(where: { $0.id == .pinned })!
            let moving = Set(ordered)
            let remaining = sections[s].nodes.count(where: { node in
                if case let .workspace(ws) = node { return !moving.contains(ws.id) }
                return true
            })
            return reorder(ordered, to: DropPosition(section: .pinned, index: remaining), in: &sections)
        }
        guard let pinnedIndex = sections.firstIndex(where: { $0.id == .pinned }) else { return false }
        let pinnedIDs = Set(sections[pinnedIndex].workspaces.map(\.id))
        let unpinning = ordered.filter { pinnedIDs.contains($0) }
        var changed = false
        let byMachine = Dictionary(grouping: unpinning) { workspace($0, in: sections)!.machineID }
        for (machine, machineIDs) in byMachine.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            changed = reorder(machineIDs, to: DropPosition(section: .machine(machine), index: 0), in: &sections) || changed
        }
        return changed
    }

    // MARK: Primitives

    /// Removes workspaces and returns them in tree order. Emptied groups stay
    /// so section-level indices computed before removal remain valid.
    static func removeWorkspaces(_ ids: Set<WorkspaceID>, from sections: inout [SidebarSection]) -> [SidebarWorkspace] {
        var removed: [SidebarWorkspace] = []
        for s in sections.indices {
            var kept: [SidebarNode] = []
            for node in sections[s].nodes {
                switch node {
                case let .workspace(ws):
                    if ids.contains(ws.id) { removed.append(ws) } else { kept.append(node) }
                case var .group(group):
                    removed.append(contentsOf: group.workspaces.filter { ids.contains($0.id) })
                    group.workspaces.removeAll { ids.contains($0.id) }
                    kept.append(.group(group))
                }
            }
            sections[s].nodes = kept
        }
        return removed
    }

    static func insert(_ workspaces: [SidebarWorkspace], at position: DropPosition, in sections: inout [SidebarSection]) {
        guard let s = sections.firstIndex(where: { $0.id == position.section }) else { return }
        if let group = position.group,
           let n = sections[s].nodes.firstIndex(where: { $0.id == .group(group) }),
           case var .group(g) = sections[s].nodes[n] {
            let index = max(0, min(position.index, g.workspaces.count))
            g.workspaces.insert(contentsOf: workspaces, at: index)
            sections[s].nodes[n] = .group(g)
        } else {
            let index = max(0, min(position.index, sections[s].nodes.count))
            sections[s].nodes.insert(contentsOf: workspaces.map(SidebarNode.workspace), at: index)
        }
    }

    /// Drops groups left empty by a move or close.
    static func pruneEmptyGroups(in sections: inout [SidebarSection], keeping: GroupID?) {
        for s in sections.indices {
            sections[s].nodes.removeAll { node in
                if case let .group(group) = node {
                    return group.workspaces.isEmpty && !group.isPinned && group.id != keeping
                }
                return false
            }
        }
    }

    @discardableResult
    static func mutateGroup(_ id: GroupID, in sections: inout [SidebarSection], _ body: (inout SidebarGroup) -> Void) -> Bool {
        guard let (s, n) = locateGroup(id, in: sections),
              case var .group(group) = sections[s].nodes[n] else { return false }
        body(&group)
        sections[s].nodes[n] = .group(group)
        return true
    }

    @discardableResult
    static func mutateWorkspaces(_ ids: [WorkspaceID], in sections: inout [SidebarSection], _ body: (inout SidebarWorkspace) -> Void) -> Bool {
        var changed = false
        for id in ids {
            guard let loc = locate(id, in: sections) else { continue }
            switch sections[loc.section].nodes[loc.node] {
            case var .workspace(ws):
                body(&ws)
                sections[loc.section].nodes[loc.node] = .workspace(ws)
            case var .group(group):
                guard let c = loc.child else { continue }
                body(&group.workspaces[c])
                sections[loc.section].nodes[loc.node] = .group(group)
            }
            changed = true
        }
        return changed
    }
}
