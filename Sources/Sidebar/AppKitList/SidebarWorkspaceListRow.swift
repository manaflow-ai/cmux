import Foundation

/// Immutable content for one AppKit-owned sidebar list row.
///
/// The whole workspace list renders from these values plus closure bundles.
/// No observable model reference reaches the table, its cells, or their
/// menus — the same snapshot boundary rule the SwiftUI list enforced, made
/// structural: AppKit cells have no way to subscribe to anything.
enum SidebarWorkspaceListRowContent: Equatable {
    case workspace(SidebarWorkspaceRowSnapshot)
    case groupHeader(SidebarWorkspaceGroupRowSnapshot)
}

/// One drawable row of the workspace sidebar table.
struct SidebarWorkspaceListRow: Equatable {
    let id: SidebarWorkspaceRenderItemID
    let content: SidebarWorkspaceListRowContent

    init(workspace snapshot: SidebarWorkspaceRowSnapshot) {
        id = .workspace(snapshot.workspaceId)
        content = .workspace(snapshot)
    }

    init(groupHeader snapshot: SidebarWorkspaceGroupRowSnapshot) {
        id = .group(snapshot.groupId)
        content = .groupHeader(snapshot)
    }

    /// The workspace this row acts on (the anchor workspace for group headers).
    var workspaceId: UUID {
        switch content {
        case .workspace(let snapshot): return snapshot.workspaceId
        case .groupHeader(let snapshot): return snapshot.anchorWorkspaceId
        }
    }

    var groupId: UUID? {
        switch content {
        case .workspace(let snapshot): return snapshot.groupId
        case .groupHeader(let snapshot): return snapshot.groupId
        }
    }

    var isGroupHeader: Bool {
        if case .groupHeader = content { return true }
        return false
    }

    var isPinned: Bool {
        switch content {
        case .workspace(let snapshot): return snapshot.workspace.isPinned
        case .groupHeader(let snapshot): return snapshot.isPinned
        }
    }
}
