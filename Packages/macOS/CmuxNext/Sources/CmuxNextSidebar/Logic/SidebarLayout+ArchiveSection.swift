import CoreGraphics

// Archived rows leave the sidebar (cmux#51635, after Lawrence 19197): every archived workspace, archived link, tab or
// app row, and every group that is archived or whose workspaces are all archived, is drawn by no list. They live in
// Settings > Sidebar > Archived Workspaces, where a person opens, restores or deletes them, as ChatGPT keeps
// archived chats in Settings > Data controls > Archived chats. Before, they folded under an "Archive (N)" row at the
// bottom of the sidebar that, opened, listed them dimmed among the live rows.
// The active workspace keeps its place (Open from the list shows it; a click moves no row); a filter lists every
// match in place, archived ones too. With the session tree a row whose parent was archived draws as a root of its list.
nonisolated extension SidebarLayout {
    /// Whether this layout leaves archived rows out: on, and no filter (a search lists its archived matches in place).
    static func hidesArchived(_ o: SidebarLayoutOptions) -> Bool {
        o.archiveSection && o.filterMatches == nil
    }

    /// `sections` without their archived rows and archived groups (their order and ids unchanged); `active` keeps its
    /// place in its list, with every group above it.
    ///
    /// A group leaves when it is archived, when its parent leaves, or when it holds rows and none of them is live (its
    /// workspaces, its link, tab and app rows and its subgroups' rows, all archived). A group that holds a live row at
    /// any depth stays, so no live row is lost with its folder (the reducer archives a group only when all of it is).
    static func withoutArchived(_ sections: [SidebarSection], keeping active: WorkspaceID?) -> [SidebarSection] {
        sections.map { section in
            // Pinned holds no groups and its rows are the person's picks: it keeps them.
            guard section.id != .pinned, section.id != .custom(SidebarDocStore.pinnedSection) else { return section }
            // Bottom up (a section lists a group before its subgroups): what each group holds, its subgroups' too; a
            // group passes what it holds up to its parent.
            var holdsActive: Set<GroupID> = [], holdsLive: Set<GroupID> = [], holdsRows: Set<GroupID> = []
            for node in section.nodes.reversed() {
                guard case let .group(group) = node else { continue }
                let id = group.id
                if let active, group.workspaces.contains(where: { $0.id == active }) { holdsActive.insert(id) }
                if !group.workspaces.isEmpty || !group.items.isEmpty { holdsRows.insert(id) }
                let ownLive = group.workspaces.contains { !$0.isArchived } || group.items.contains { !$0.item.isArchived }
                if ownLive { holdsLive.insert(id) }
                if group.isArchived { holdsLive.remove(id) }
                guard let parent = group.parent else { continue }
                if holdsActive.contains(id) { holdsActive.insert(parent) }
                if holdsRows.contains(id) { holdsRows.insert(parent) }
                if holdsLive.contains(id) { holdsLive.insert(parent) }
            }
            var kept: Set<GroupID> = []
            var live = section
            live.nodes = section.nodes.compactMap { node in
                switch node {
                case let .workspace(ws):
                    return !ws.isArchived || ws.id == active ? node : nil
                case let .item(item):
                    return item.isArchived ? nil : node
                case var .group(group):
                    let parentKept = group.parent.map(kept.contains) ?? true
                    let stays = holdsActive.contains(group.id)
                        || (parentKept && !group.isArchived && (holdsLive.contains(group.id) || !holdsRows.contains(group.id)))
                    guard stays else { return nil }
                    kept.insert(group.id)
                    group.workspaces.removeAll { $0.isArchived && $0.id != active }
                    group.items.removeAll { $0.item.isArchived }
                    return .group(group)
                }
            }
            return live
        }
    }
}
