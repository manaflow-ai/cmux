public import CmuxNextDesign
import Foundation

/// The sidebar's tree edits: the structural ones are the shared Rust rules
/// (`cmux-layout-reducer` `sidebar_edits`); the queries here read the rows the
/// window holds, and a field write sets a row's own value.
public nonisolated enum SidebarEdits {
    /// Where a workspace sits in the tree.
    public struct Location: Hashable, Sendable {
        public var section: Int
        public var node: Int
        /// Index inside the group at `node`, or nil for a loose workspace.
        public var child: Int?
    }

    /// Applies an intent. Returns false when the intent was refused or had
    /// no structural effect (for example `select` or an invalid drop). The
    /// structural edits are the shared Rust rules (`sidebar_edits`); a field
    /// write (a title, a color, an icon) is set here.
    @discardableResult
    public static func apply(_ intent: SidebarIntent, to sections: inout [SidebarSection]) -> Bool {
        switch intent {
        case let .setGroupIcon(id, icon):
            return mutateGroup(id, in: &sections) { $0.icon = icon.flatMap { WorkspaceIcon.parse($0) } }
        case let .renameGroup(id, name):
            return mutateGroup(id, in: &sections) { $0.name = name }
        case let .setGroupColor(id, color):
            return mutateGroup(id, in: &sections) { $0.tint = color }
        case let .rename(id, title):
            return mutateWorkspaces([id], in: &sections) { $0.title = title }
        case let .setColor(ids, color):
            return mutateWorkspaces(ids, in: &sections) { ws in
                ws.color = color // a rail or fill row shows it at once, a favicon or emoji row too
                switch (ws.icon, color) {
                case let (.symbol(name, _)?, color): ws.icon = .symbol(name, tint: color)
                case (.emoji?, _): break // an emoji keeps its own colors
                case let (_, color?): ws.icon = .swatch(color)
                case (.swatch?, nil), (nil, nil): ws.icon = nil
                case (.favicon?, nil), (.pagePlaceholder?, nil): break // a page's favicon (or its globe) is not the user's to clear
                }
            }
        case let .setIcon(ids, icon):
            return mutateWorkspaces(ids, in: &sections) { $0.icon = icon }
        case let .createGroup(id, name, color, _, _, _, _):
            return edit(intent, in: &sections) { made in
                guard made == id else { return nil }
                var group = SidebarGroup(id: id, name: SidebarGroup.named(name), workspaces: [])
                group.tint = color
                return group
            }
        default:
            return edit(intent, in: &sections)
        }
    }

    /// Runs a structural intent through the shared rules; false for one with no tree edit or a refused one.
    /// `made`: a group the edit creates. `prunes` false keeps a group the move empties (a drag's shown result:
    /// an emptied group is still a drop target).
    static func edit(_ intent: SidebarIntent, in sections: inout [SidebarSection], prunes: Bool = true,
                     made: (GroupID) -> SidebarGroup? = { _ in nil }) -> Bool {
        guard let wire = RustEditIntent(intent) else { return false }
        let skeleton = RustSidebarEdits(sections)
        var request = RustEditRequest("edit", sections: skeleton.sections)
        (request.intent, request.prunes) = (wire, prunes)
        guard let reply = RustSidebarClient.call("sidebar_edits", request, as: RustEditReply.self) else { return false }
        if let shown = reply.sections { sections = skeleton.rebuild(shown, from: sections, made: made) }
        return reply.changed
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
        case .item: return nil
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
        if loc.child != nil, case let .group(group) = section.nodes[loc.node] {
            // A group's index counts its member rows: workspaces and link, tab and app items.
            let member = group.members.firstIndex { if case let .workspace(ws) = $0 { ws.id == id } else { false } } ?? 0
            return DropPosition(section: section.id, group: group.id, index: member)
        }
        return DropPosition(section: section.id, index: loc.node)
    }

    /// The given ids in visual (tree) order, dropping unknown ids.
    public static func treeOrder(_ ids: some Collection<WorkspaceID>, in sections: [SidebarSection]) -> [WorkspaceID] {
        let wanted = Set(ids)
        return sections.flatMap(\.workspaces).map(\.id).filter { wanted.contains($0) }
    }

    /// Whether every workspace `ids` names may join group `group`: the group exists and each one
    /// may live in its section (a group holds workspaces of one machine row). The one rule for a
    /// drag, the palette and the CLI (`moveWorkspaceToGroup`), shared (`sidebar_edits` `can_move`).
    public static func canMove(_ ids: [WorkspaceID], toGroup group: GroupID, in sections: [SidebarSection]) -> Bool {
        var request = RustEditRequest("can_move", sections: RustSidebarEdits(sections).sections)
        (request.ids, request.group) = (ids.map(\.rawValue), group.rawValue)
        return RustSidebarClient.call("sidebar_edits", request, as: Bool.self) ?? false
    }

    /// Whether a workspace may live in a section.
    public static func canPlace(_ ws: SidebarWorkspace, in section: SidebarSection) -> Bool {
        switch section.kind {
        case .pinned, .custom: true
        case let .machine(machine): machine.id == ws.machineID
        }
    }

    // MARK: Edits

    /// A drag's in-place result (`SidebarListView.displayLayout`, each layout pass of a drag): `ids` moved to
    /// `position`. It stays here, not a call to the shared rules, because it runs per layout pass; it follows
    /// `sidebar_edits::reorder` (whose tests hold the cases). `prunes` false keeps a group the move empties (an
    /// emptied group is still a drop target); the committed edit goes through ``apply(_:to:)``.
    static func reorder(_ ids: [WorkspaceID], to position: DropPosition, in sections: inout [SidebarSection], prunes: Bool = true) -> Bool {
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
        if prunes { pruneEmptyGroups(in: &sections, keeping: position.group, emptiedFrom: groupsWithMembers(before)) }
        return sections != before
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
                    // The link, tab and app members keep their rows: one after a leaving workspace follows the
                    // workspace member before it now.
                    group.setMembers(group.members.filter { if case let .workspace(ws) = $0 { !ids.contains(ws.id) } else { true } })
                    kept.append(.group(group))
                case .item:
                    kept.append(node)
                }
            }
            sections[s].nodes = kept
        }
        return removed
    }

    public static func insert(_ workspaces: [SidebarWorkspace], at position: DropPosition, in sections: inout [SidebarSection]) {
        guard let s = sections.firstIndex(where: { $0.id == position.section }) else { return }
        if let group = position.group,
           let n = sections[s].nodes.firstIndex(where: { $0.id == .group(group) }),
           case var .group(g) = sections[s].nodes[n] {
            // The index counts member rows (workspaces and link, tab and app items).
            var members = g.members
            members.insert(contentsOf: workspaces.map(SidebarGroupMember.workspace), at: max(0, min(position.index, members.count)))
            g.setMembers(members)
            sections[s].nodes[n] = .group(g)
        } else {
            let index = max(0, min(position.index, sections[s].nodes.count))
            sections[s].nodes.insert(contentsOf: workspaces.map(SidebarNode.workspace), at: index)
        }
    }

    /// Drops the groups a move or close left empty: those of `emptiedFrom` (the groups that held a row before it)
    /// that hold none now. A group that was already empty (a kept group with no open workspace) stays: its header is
    /// still a row and a drop target (Leo 2026-10-20: collapsed groups vanished while a row was dragged).
    static func pruneEmptyGroups(in sections: inout [SidebarSection], keeping: GroupID?, emptiedFrom: Set<GroupID>) {
        for s in sections.indices {
            sections[s].nodes.removeAll { node in
                if case let .group(group) = node {
                    return group.workspaces.isEmpty && group.items.isEmpty && !group.isPinned && group.id != keeping
                        && emptiedFrom.contains(group.id)
                }
                return false
            }
        }
    }

    /// The groups that list at least one row (a workspace or a link, tab or app item).
    static func groupsWithMembers(_ sections: [SidebarSection]) -> Set<GroupID> {
        var held = Set<GroupID>()
        for section in sections {
            for case let .group(group) in section.nodes where !group.workspaces.isEmpty || !group.items.isEmpty { held.insert(group.id) }
        }
        return held
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
            case .item:
                continue
            }
            changed = true
        }
        return changed
    }
}
