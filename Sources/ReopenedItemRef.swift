import Foundation

/// Identifies a live item that was just reopened from history so a "redo"
/// (re-close) can target it.
enum ReopenedItemRef: Equatable, Sendable {
    case panel(workspaceId: UUID, panelId: UUID)
    case workspace(workspaceId: UUID)
    case window(windowId: UUID)
}
