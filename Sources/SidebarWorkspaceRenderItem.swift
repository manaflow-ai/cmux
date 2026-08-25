import CmuxWorkspaces
import Foundation

/// Stable value identity for one drawable item in the workspace sidebar.
///
/// Keep live `Workspace` / `WorkspaceGroup` references out of this value. A
/// `LazyVStack` copies and diffs its `ForEach` data while placing rows; carrying
/// the models through that path made scrolling copy the live sidebar graph and
/// blurred the ownership boundary between layout data and observed state.
/// Models are resolved from the parent-owned render context only when SwiftUI
/// asks to realize a row.
@MainActor
enum SidebarWorkspaceRenderItem {
    case groupHeader(groupId: UUID, anchorWorkspaceId: UUID)
    case workspace(workspaceId: UUID)

    var id: SidebarWorkspaceRenderItemID {
        switch self {
        case .groupHeader(let groupId, _):
            return .group(groupId)
        case .workspace(let workspaceId):
            return .workspace(workspaceId)
        }
    }

    var rowWorkspaceId: UUID {
        switch self {
        case .groupHeader(_, let anchorWorkspaceId):
            return anchorWorkspaceId
        case .workspace(let workspaceId):
            return workspaceId
        }
    }

    static func renderItems(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup],
        orderedGroups: [WorkspaceGroup]? = nil
    ) -> [SidebarWorkspaceRenderItem] {
        guard !tabs.isEmpty || !groupsById.isEmpty else { return [] }
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
                        items.append(.groupHeader(
                            groupId: group.id,
                            anchorWorkspaceId: group.anchorWorkspaceId
                        ))
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
                items.append(.workspace(workspaceId: tab.id))
            }
        }

        // Empty pinned groups have no tab row from which a header can be
        // discovered. Emit them as first-class header-only rows, keeping the
        // model's group order within each pin tier. Empty unpinned groups are
        // placed after live rows; they are uncommon (normal close paths remove
        // them) but remain renderable until an explicit mutation removes them.
        let ordered = orderedGroups
            ?? groupsById.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let memberGroupIds = Set(tabs.compactMap(\.groupId))
        let emptyGroups = ordered.filter { !memberGroupIds.contains($0.id) }
        guard !emptyGroups.isEmpty else { return items }

        var emptyBeforeGroup: [UUID: [WorkspaceGroup]] = [:]
        var trailingPinned: [WorkspaceGroup] = []
        var trailingUnpinned: [WorkspaceGroup] = []
        for (index, group) in ordered.enumerated() where !memberGroupIds.contains(group.id) {
            // Empty pinned headers must never be inserted in the unpinned
            // section (and vice versa). Keep pinned empties in the global
            // pinned bucket; only an unpinned empty can be anchored directly
            // before a later live unpinned group.
            let nextLiveUnpinnedGroup = ordered.dropFirst(index + 1).first {
                memberGroupIds.contains($0.id) && !$0.isPinned
            }
            if !group.isPinned, let nextLiveUnpinnedGroup {
                emptyBeforeGroup[nextLiveUnpinnedGroup.id, default: []].append(group)
            } else if group.isPinned {
                trailingPinned.append(group)
            } else {
                trailingUnpinned.append(group)
            }
        }

        var rendered: [SidebarWorkspaceRenderItem] = []
        rendered.reserveCapacity(items.count + emptyGroups.count)
        for item in items {
            if case .groupHeader(let groupId, _) = item,
               let preceding = emptyBeforeGroup[groupId] {
                rendered.append(contentsOf: preceding.map {
                    .groupHeader(groupId: $0.id, anchorWorkspaceId: $0.anchorWorkspaceId)
                })
            }
            rendered.append(item)
        }
        if !trailingPinned.isEmpty {
            let firstUnpinnedIndex = rendered.firstIndex { item in
                switch item {
                case .groupHeader(let groupId, _):
                    return groupsById[groupId]?.isPinned == false
                case .workspace(let workspaceId):
                    return tabs.first(where: { $0.id == workspaceId })?.isPinned == false
                }
            } ?? rendered.count
            rendered.insert(contentsOf: trailingPinned.map {
                .groupHeader(groupId: $0.id, anchorWorkspaceId: $0.anchorWorkspaceId)
            }, at: firstUnpinnedIndex)
        }
        rendered.append(contentsOf: trailingUnpinned.map {
            .groupHeader(groupId: $0.id, anchorWorkspaceId: $0.anchorWorkspaceId)
        })
        return rendered
    }

    /// Workspace ids represented by ordinary rows, in their rendered order.
    ///
    /// Group headers represent their anchor workspace for interaction, but are
    /// containers rather than numbered workspace rows.
    static func numberedWorkspaceIds(
        from renderItems: [SidebarWorkspaceRenderItem]
    ) -> [UUID] {
        renderItems.compactMap { item in
            guard case .workspace(let workspaceId) = item else { return nil }
            return workspaceId
        }
    }

    static func numberedWorkspaceIndexById(
        from renderItems: [SidebarWorkspaceRenderItem]
    ) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        result.reserveCapacity(renderItems.count)
        for item in renderItems {
            guard case .workspace(let workspaceId) = item else { continue }
            result[workspaceId] = result.count
        }
        return result
    }

    static func numberedWorkspaceIds(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup]
    ) -> [UUID] {
        numberedWorkspaceIds(from: renderItems(tabs: tabs, groupsById: groupsById))
    }

    static func memberWorkspaceIdsByGroupId(tabs: [Workspace]) -> [UUID: [UUID]] {
        var result: [UUID: [UUID]] = [:]
        for tab in tabs {
            if let groupId = tab.groupId {
                result[groupId, default: []].append(tab.id)
            }
        }
        return result
    }
}
