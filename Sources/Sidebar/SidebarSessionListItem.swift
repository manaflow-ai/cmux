import Foundation

/// Immutable session-group projection shared by both default sidebar renderers.
@MainActor
enum SidebarSessionListItem: Equatable {
    enum ID: Equatable, Hashable {
        case group(String)
        case workspace(UUID)
    }

    case groupHeader(group: SessionCardGroup, anchorWorkspaceID: UUID, isCollapsed: Bool)
    case workspace(SidebarSessionRowSnapshot)

    var id: ID {
        switch self {
        case .groupHeader(let group, _, _):
            return .group(group.id)
        case .workspace(let row):
            return .workspace(row.id)
        }
    }

    static func renderItems(
        groups: [SessionCardGroup],
        rows: [SidebarSessionRowSnapshot],
        collapsedGroupIDs: Set<String>
    ) -> [SidebarSessionListItem] {
        groups.flatMap { group -> [SidebarSessionListItem] in
            let groupRows = rows.filter { $0.groupID == group.id }
            guard let firstRow = groupRows.first else { return [] }
            let isCollapsed = collapsedGroupIDs.contains(group.id)
            var items: [SidebarSessionListItem] = [
                .groupHeader(
                    group: group,
                    anchorWorkspaceID: firstRow.id,
                    isCollapsed: isCollapsed
                ),
            ]
            if !isCollapsed {
                items.append(contentsOf: groupRows.map(SidebarSessionListItem.workspace))
            }
            return items
        }
    }
}

extension [SidebarSessionListItem] {
    var visibleWorkspaceIDs: [UUID] {
        compactMap { item in
            guard case .workspace(let row) = item else { return nil }
            return row.id
        }
    }
}
