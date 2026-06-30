import CmuxWorkspaces
import Foundation

/// Stable, allocation-free identity for a `SidebarWorkspaceRenderItem`.
///
/// ForEach gathers row identifiers on every list diff, so the id must be cheap
/// to create and hash. The previous `String` form
/// (`"workspace.\(uuid.uuidString)"`) allocated and formatted a fresh string on
/// every getter call; with the sidebar re-diffing all rows per update it was a
/// hot app-owned frame in sidebar livelock samples. Keep the discriminator as a
/// byte instead of an enum payload so SwiftUI's per-scroll list diff does not
/// spend time in enum-derived equality/hash witnesses.
struct SidebarWorkspaceRenderItemID: Hashable {
    enum Kind: UInt8, Hashable {
        case group = 1
        case workspace = 2
    }

    let kind: Kind
    let uuid: UUID

    static func group(_ uuid: UUID) -> Self {
        Self(kind: .group, uuid: uuid)
    }

    static func workspace(_ uuid: UUID) -> Self {
        Self(kind: .workspace, uuid: uuid)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind.rawValue)
        hasher.combine(uuid)
    }
}

/// One drawable item in the workspace sidebar.
@MainActor
enum SidebarWorkspaceRenderItem {
    case groupHeader(WorkspaceGroup, memberWorkspaceIds: [UUID])
    case workspace(Workspace)

    var id: SidebarWorkspaceRenderItemID {
        switch self {
        case .groupHeader(let group, _):
            return .group(group.id)
        case .workspace(let workspace):
            return .workspace(workspace.id)
        }
    }

    var rowWorkspaceId: UUID {
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
