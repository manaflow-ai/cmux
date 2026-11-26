import Foundation

/// The content surfaced in the dismissible warning banner.
struct PaneMemoryWarning: Equatable, Identifiable, Sendable {
    let workspaceId: UUID
    let panelId: UUID
    let workspaceTitle: String
    let paneTitle: String
    let memoryBytes: Int64
    let foregroundCommand: String?

    var id: UUID { panelId }
    var key: PaneMemoryPaneKey { PaneMemoryPaneKey(workspaceId: workspaceId, panelId: panelId) }
}
