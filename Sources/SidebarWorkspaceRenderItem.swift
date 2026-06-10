import Foundation

/// One drawable item in the workspace sidebar.
@MainActor
enum SidebarWorkspaceRenderItem {
    case groupHeader(WorkspaceGroup, memberWorkspaceIds: [UUID])
    case workspace(Workspace)

    var id: String {
        switch self {
        case .groupHeader(let group, _):
            // Share identity with the anchor workspace's row. The group header
            // *is* the anchor workspace's sidebar slot, so promoting a
            // workspace in place (or ungrouping) keeps the same ForEach
            // identity at that position and only swaps the row's content
            // between a `.workspace` row and a `.groupHeader`. That lets
            // SwiftUI animate the morph instead of insert+delete, and it stops
            // the LazyVStack from dropping the materialized row when the slot
            // changes kind — the bug that previously forced a whole-list
            // `.id(groupAnchorSignature)` rebuild (and reset sidebar scroll).
            return "workspace.\(group.anchorWorkspaceId.uuidString)"
        case .workspace(let workspace):
            return "workspace.\(workspace.id.uuidString)"
        }
    }

    /// The workspace UUID this row occupies, used for the row's SwiftUI `.id()`
    /// so `ScrollViewReader.scrollTo(selectedWorkspaceId)` can find it. Applied
    /// on the row *wrapper* (not the inner header/workspace branches) so the
    /// `_ConditionalContent` swap between a workspace row and a group header
    /// still runs its `.transition` and animates the promote/ungroup morph.
    /// A group header occupies its anchor workspace's slot, so both kinds map
    /// to the same UUID, keeping the slot identity stable across the morph.
    var scrollAnchorWorkspaceId: UUID {
        switch self {
        case .groupHeader(let group, _):
            return group.anchorWorkspaceId
        case .workspace(let workspace):
            return workspace.id
        }
    }
    static func renderItems(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup]
    ) -> [SidebarWorkspaceRenderItem] {
        guard !tabs.isEmpty else { return [] }
        var memberWorkspaceIdsByGroupId: [UUID: [UUID]] = [:]
        for tab in tabs {
            if let gid = tab.groupId {
                memberWorkspaceIdsByGroupId[gid, default: []].append(tab.id)
            }
        }
        var items: [SidebarWorkspaceRenderItem] = []
        items.reserveCapacity(tabs.count + groupsById.count)
        var lastEmittedGroupId: UUID? = nil
        var emittedHeaders: Set<UUID> = []
        var collapsedByGroupId: [UUID: Bool] = [:]
        var skipChildrenUntilNextGroup = false
        for tab in tabs {
            let groupId = tab.groupId
            if groupId != lastEmittedGroupId {
                lastEmittedGroupId = groupId
                skipChildrenUntilNextGroup = false
                if let groupId, let group = groupsById[groupId] {
                    if !emittedHeaders.contains(groupId) {
                        let memberWorkspaceIds = memberWorkspaceIdsByGroupId[groupId] ?? []
                        items.append(.groupHeader(group, memberWorkspaceIds: memberWorkspaceIds))
                        emittedHeaders.insert(groupId)
                        collapsedByGroupId[groupId] = group.isCollapsed
                    }
                    // If legacy reorder paths ever leave a group's members in
                    // two runs, keep honoring the same collapse decision.
                    skipChildrenUntilNextGroup = collapsedByGroupId[groupId] ?? false
                }
            }
            // Anchor workspaces are represented exclusively by the group header.
            if let groupId, let group = groupsById[groupId], group.anchorWorkspaceId == tab.id {
                continue
            }
            if groupId == nil || !skipChildrenUntilNextGroup {
                items.append(.workspace(tab))
            }
        }
        return items
    }
}
