public import Foundation

/// One drawable item in the workspace sidebar.
@MainActor
public enum SidebarWorkspaceRenderItem<Tab: WorkspaceTabRepresenting> {
    /// A workspace group header row and the workspace ids contained by that group.
    case groupHeader(WorkspaceGroup, memberWorkspaceIds: [UUID])
    /// A visible workspace row.
    case workspace(Tab)

    /// Stable identity for SwiftUI row diffing.
    public var id: SidebarWorkspaceRenderItemID {
        switch self {
        case .groupHeader(let group, _):
            return .group(group.id)
        case .workspace(let workspace):
            return .workspace(workspace.id)
        }
    }

    /// The workspace id represented by this visible row.
    public var rowWorkspaceId: UUID {
        switch self {
        case .groupHeader(let group, _):
            return group.anchorWorkspaceId
        case .workspace(let workspace):
            return workspace.id
        }
    }

    /// Builds the visible sidebar rows for the supplied workspaces and groups.
    /// - Parameters:
    ///   - tabs: The workspaces in storage order.
    ///   - groupsById: Workspace groups keyed by their stable identifiers.
    /// - Returns: Visible row items, including group headers and non-collapsed children.
    public static func renderItems(
        tabs: [Tab],
        groupsById: [UUID: WorkspaceGroup]
    ) -> [SidebarWorkspaceRenderItem<Tab>] {
        guard !tabs.isEmpty else { return [] }
        var memberWorkspaceIdsByGroupId: [UUID: [UUID]] = [:]
        for tab in tabs {
            if let gid = tab.groupId {
                memberWorkspaceIdsByGroupId[gid, default: []].append(tab.id)
            }
        }
        var items: [SidebarWorkspaceRenderItem<Tab>] = []
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
